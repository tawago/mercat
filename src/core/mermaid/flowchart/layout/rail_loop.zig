const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const rail_closure = @import("../base/rail_closure.zig");
const fan_mod = @import("fan.zig");
const fan_rail = @import("fan_rail.zig");
const gap_rows = @import("gap_rows.zig");
const member_stroke = @import("member_stroke.zig");
const node_geom = @import("node_geom.zig");
const port_plan = @import("port_plan.zig");
const route_clearance = @import("route_clearance.zig");
const rp = @import("routing_polyline.zig");
const rt = @import("routing_terminal.zig");
const sugiyama = @import("sugiyama.zig");

const max_cuts = 8;

const Edges = std.ArrayListUnmanaged(sketch.EdgePath);
const Polylines = std.ArrayListUnmanaged([]sketch.Point);

pub const Drawn = struct {
    rails: []fan_rail.Built,
    views: []const sketch.Rail,
    claimed: []const sg.EdgeId,
    edges: Edges,
    polylines: Polylines,
};

const Pending = struct {
    lane: u32,
    resolved: fan_rail.Resolved,
};

const Round = struct {
    rails: []fan_rail.Built,
    owners: []const usize,
    views: []const sketch.Rail,
};

const Refusal = struct { fan: usize, edge: sg.EdgeId };

const Ends = struct {
    start: sketch.Point,
    end: sketch.Point,
    jog: i32,
    lo: i32,
    hi: i32,
    on_rail: bool,
};

const Loop = struct {
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const node_geom.NodeGeom,
    placements: []const sketch.NodePlacement,
    bundles: ledger.RealizedBundles,
    ports: port_plan.Plan,
    rows: gap_rows.Ledger,
    reserved_columns: []const i32,
    pending: []Pending = &.{},

    fn resolve(self: Loop, fans: []const fan_mod.Fan) error{OutOfMemory}![]Pending {
        var pending: std.ArrayListUnmanaged(Pending) = .empty;
        for (fans) |f| {
            const resolved = (try fan_rail.resolve(self.a, self.graph.direction, f, self.graph, self.placements, self.geom, self.bundles, self.ports)) orelse continue;
            const row = self.rows.rowOfFan(f.pivot_idx, f.direction) orelse 0;
            try pending.append(self.a, .{ .lane = @intCast(@max(row, 0)), .resolved = resolved });
        }
        return pending.toOwnedSlice(self.a);
    }

    fn build(self: Loop) error{OutOfMemory}!Round {
        var rails: std.ArrayListUnmanaged(fan_rail.Built) = .empty;
        var owners: std.ArrayListUnmanaged(usize) = .empty;
        for (self.pending, 0..) |p, pi| {
            if (p.resolved.peers.len < 2) continue;
            const built = try fan_rail.build(self.a, p.resolved, p.lane);
            if (fan_rail.blocked(built, p.resolved.pivot.id, self.placements)) continue;
            if (try route_clearance.railConflictsReservedTerminals(self.a, built.rail, self.placements, self.ports.edges, self.bundles)) continue;
            try rails.append(self.a, built);
            try owners.append(self.a, pi);
        }
        const views = try self.a.alloc(sketch.Rail, rails.items.len);
        for (rails.items, views) |rail, *view| view.* = rail.rail;
        return .{ .rails = try rails.toOwnedSlice(self.a), .owners = try owners.toOwnedSlice(self.a), .views = views };
    }

    fn strokes(self: Loop, round: Round, edges: *Edges, polylines: *Polylines) error{OutOfMemory}![]const Refusal {
        var refused: std.ArrayListUnmanaged(Refusal) = .empty;
        for (round.rails, round.owners) |built, owner| {
            const fan_in = isIn(built.rail.role);
            for (built.rail.taps) |tap| {
                if (!tap.continues) continue;
                if (rail_closure.contains(self.bundles.discharged, tap.edge)) continue;
                if (fan_in and farTap(round.rails, tap.edge, false) != null) continue;
                const orig = rt.findGraphEdge(self.graph, tap.edge) orelse continue;
                const ep = self.ports.forEdge(orig.id) orelse continue;
                const dst_p = rt.findPlacement(self.placements, orig.to);
                const ends = try self.strokeEnds(round.rails, tap, fan_in, orig, ep);
                const poly = (try member_stroke.route(self.a, orig, ends.start, ends.end, ends.jog, ends.lo, ends.hi, edges.items, round.views, self.placements, self.ports, self.bundles, self.reserved_columns)) orelse {
                    try refused.append(self.a, .{ .fan = owner, .edge = tap.edge });
                    if (ends.on_rail) for (round.rails, round.owners) |other, other_owner| if (isIn(other.rail.role)) {
                        for (other.rail.taps) |t| if (t.edge == tap.edge and t.continues) try refused.append(self.a, .{ .fan = other_owner, .edge = tap.edge });
                    };
                    continue;
                };
                try edges.append(self.a, .{
                    .id = orig.id,
                    .from = orig.from,
                    .to = orig.to,
                    .polyline = poly,
                    .port_from = ep.source,
                    .port_to = if (ends.on_rail) ep.target else rp.reconcileTerminalSide(poly, dst_p, ep.target),
                    .arrow_from = rt.mapArrow(orig.arrow_from),
                    .arrow_to = rt.mapArrow(orig.arrow_to),
                    .label = orig.label,
                    .kind = orig.kind,
                    .role = .member_stroke,
                });
                try polylines.append(self.a, poly);
            }
        }
        return refused.toOwnedSlice(self.a);
    }

    fn strokeEnds(self: Loop, rails: []const fan_rail.Built, tap: sketch.Tap, fan_in: bool, orig: sg.Edge, ep: port_plan.EdgePorts) error{OutOfMemory}!Ends {
        var start: sketch.Point = undefined;
        var end: sketch.Point = undefined;
        var on_rail = false;
        var jog: i32 = undefined;
        if (!fan_in) {
            start = tap.at;
            if (farTap(rails, tap.edge, true)) |far| {
                end = far.at;
                on_rail = true;
                jog = end.y - 2;
            } else {
                end = rp.portPoint(rt.findPlacement(self.placements, orig.to), ep.target);
                jog = end.y - 3 - (self.rows.rowOfEdge(orig.id, .exit) orelse 0);
            }
        } else {
            end = tap.at;
            start = rp.portPoint(rt.findPlacement(self.placements, orig.from), ep.source);
            const virtuals = try rt.collectVirtuals(self.a, self.lg, orig.id);
            defer self.a.free(virtuals);
            jog = if (virtuals.len == 0)
                start.y + 2
            else if (self.rows.rowOfEdge(orig.id, .entry)) |row|
                self.geom[virtuals[0]].y - 3 - row
            else
                self.geom[virtuals[0]].y - 1;
        }
        return .{
            .start = start,
            .end = end,
            .jog = jog,
            .lo = if (fan_in and orig.arrow_from == .none) start.y + 1 else start.y + 2,
            .hi = end.y - 2,
            .on_rail = on_rail,
        };
    }

    fn cut(self: Loop, refused: []const Refusal) void {
        for (refused) |r| {
            const resolved = &self.pending[r.fan].resolved;
            var kept: usize = 0;
            for (resolved.peers) |peer| if (peer.edge.id != r.edge) {
                resolved.peers[kept] = peer;
                kept += 1;
            };
            resolved.peers = resolved.peers[0..kept];
        }
    }
};

pub fn run(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const node_geom.NodeGeom,
    placements: []const sketch.NodePlacement,
    fans: []const fan_mod.Fan,
    bundles: ledger.RealizedBundles,
    ports: port_plan.Plan,
    rows: gap_rows.Ledger,
    reserved_columns: []const i32,
) error{OutOfMemory}!Drawn {
    var loop: Loop = .{
        .a = a,
        .graph = graph,
        .lg = lg,
        .geom = geom,
        .placements = placements,
        .bundles = bundles,
        .ports = ports,
        .rows = rows,
        .reserved_columns = reserved_columns,
    };
    loop.pending = try loop.resolve(fans);
    alignLongColumns(loop.pending);
    var cuts: usize = 0;
    while (true) : (cuts += 1) {
        const round = try loop.build();
        var edges: Edges = .empty;
        var polylines: Polylines = .empty;
        const refused = try loop.strokes(round, &edges, &polylines);
        if (refused.len == 0 or cuts >= max_cuts) return finish(a, round, edges, polylines);
        loop.cut(refused);
    }
}

fn finish(a: std.mem.Allocator, round: Round, edges: Edges, polylines: Polylines) error{OutOfMemory}!Drawn {
    var polys = polylines;
    var claimed: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
    for (round.rails) |built| {
        try polys.append(a, built.stem);
        for (built.rail.taps) |tap| try claimed.append(a, tap.edge);
    }
    return .{
        .rails = round.rails,
        .views = round.views,
        .claimed = try claimed.toOwnedSlice(a),
        .edges = edges,
        .polylines = polys,
    };
}

fn alignLongColumns(pending: []Pending) void {
    for (pending) |p| {
        if (p.resolved.direction != .out) continue;
        for (p.resolved.peers) |peer| {
            if (!peer.long) continue;
            for (pending) |q| {
                if (q.resolved.direction != .in) continue;
                for (q.resolved.peers) |*other| if (other.long and other.edge.id == peer.edge.id) {
                    other.column = peer.column;
                };
            }
        }
    }
}

fn isIn(role: sketch.EdgeRole) bool {
    return role == .fan_in_dropper or role == .fan_in_rail;
}

fn farTap(rails: []const fan_rail.Built, edge: sg.EdgeId, want_in: bool) ?sketch.Tap {
    for (rails) |built| {
        if (isIn(built.rail.role) != want_in) continue;
        for (built.rail.taps) |tap| if (tap.edge == edge and tap.continues) return tap;
    }
    return null;
}
