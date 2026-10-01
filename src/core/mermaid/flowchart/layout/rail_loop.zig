const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const fan_mod = @import("fan.zig");
const fan_rail = @import("fan_rail.zig");
const gap_rows = @import("gap_rows.zig");
const member_stroke = @import("member_stroke.zig");
const node_geom = @import("node_geom.zig");
const port_plan = @import("port_plan.zig");
const route_clearance = @import("route_clearance.zig");
const sugiyama = @import("sugiyama.zig");

pub const max_cuts = 8;

pub const Drawn = struct {
    rails: []fan_rail.Built,
    views: []const sketch.Rail,
    claimed: []const sg.EdgeId,
    edges: std.ArrayListUnmanaged(sketch.EdgePath),
    polylines: std.ArrayListUnmanaged([]sketch.Point),
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

    fn resolve(self: *Loop, fans: []const fan_mod.Fan) error{OutOfMemory}!void {
        var pending: std.ArrayListUnmanaged(Pending) = .empty;
        for (fans) |f| {
            const resolved = (try fan_rail.resolve(self.a, self.graph.direction, f, self.graph, self.placements, self.geom, self.bundles, self.ports)) orelse continue;
            const row = self.rows.rowOfFan(f.pivot_idx, f.direction) orelse 0;
            try pending.append(self.a, .{ .lane = @intCast(@max(row, 0)), .resolved = resolved });
        }
        self.pending = pending.items;
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

    fn cut(self: Loop, round: Round, refused: []const member_stroke.Refusal) void {
        for (refused) |r| {
            const resolved = &self.pending[round.owners[r.rail]].resolved;
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
    try loop.resolve(fans);
    alignLongColumns(loop.pending);
    var cuts: usize = 0;
    while (true) : (cuts += 1) {
        const round = try loop.build();
        var edges: std.ArrayListUnmanaged(sketch.EdgePath) = .empty;
        var polylines: std.ArrayListUnmanaged([]sketch.Point) = .empty;
        const refused = try member_stroke.buildAll(a, graph, lg, geom, placements, round.rails, round.views, bundles, ports, reserved_columns, rows, &edges, &polylines);
        if (refused.len == 0 or cuts >= max_cuts) return finish(a, round, edges, polylines);
        loop.cut(round, refused);
    }
}

fn finish(
    a: std.mem.Allocator,
    round: Round,
    edges: std.ArrayListUnmanaged(sketch.EdgePath),
    polylines: std.ArrayListUnmanaged([]sketch.Point),
) error{OutOfMemory}!Drawn {
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
