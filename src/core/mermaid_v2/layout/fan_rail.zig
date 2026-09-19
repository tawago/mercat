const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const fan_mod = @import("fan.zig");
const fan_polyline = @import("fan_polyline.zig");
const routing = @import("routing.zig");
const pb = @import("../base/ledger.zig");
const rail_closure = @import("../base/rail_closure.zig");
const port_plan = @import("port_plan.zig");

pub const Built = struct {
    rail: sketch.Rail,
    stem: []sketch.Point,
    taps: []sketch.Tap,
};

pub const Peer = struct {
    edge: sg.Edge,
    placement: sketch.NodePlacement,
    port: ?sketch.Port = null,
    column: i32 = 0,
    line: i32 = 0,
    long: bool = false,
};

pub fn nearPeer(edge: sg.Edge, placement: sketch.NodePlacement, port: ?sketch.Port, direction: fan_mod.Direction) Peer {
    return .{
        .edge = edge,
        .placement = placement,
        .port = port,
        .column = placement.rect.x + @as(i32, @intCast(if (port) |pt| pt.offset else placement.rect.w / 2)),
        .line = if (direction == .out) placement.rect.y else placement.rect.bottom() - 1,
    };
}

pub const Resolved = struct {
    pivot: sketch.NodePlacement,
    pivot_port: ?sketch.Port = null,
    direction: fan_mod.Direction = .out,
    peers: []Peer,
};

pub fn eligible(fan: fan_mod.Fan, graph: sg.SemGraph, bundles: pb.RealizedBundles) bool {
    if (bundles.memberships.len == 0 and fan.direction != .out) return false;
    // @guarded-by: fan_rail_test.zig "a fan whose peers were lifted onto separate lanes builds no rail"
    for (fan.peers) |p| {
        if (p.lane != fan.peers[0].lane) return false;
    }
    if (fan.rows != 1) return false;
    if (fan.peers.len < 2) return false;
    var shared_len: usize = 0;
    var kind: ?sg.EdgeKind = null;
    var pivot_arrow: ?sg.ArrowEnd = null;
    for (fan.peers) |p| {
        if (!p.shared or rail_closure.contains(bundles.discharged, p.edge_id)) continue;
        shared_len += 1;
        const e = routing.findGraphEdge(graph, p.edge_id) orelse return false;
        if (kind) |k| {
            if (e.kind != k) return false;
        } else kind = e.kind;
        if (e.kind == .invisible) return false;
        const arrow = if (fan.direction == .out) e.arrow_from else e.arrow_to;
        if (bundles.memberships.len == 0 and fan.direction == .out and arrow != .none) return false;
        if (pivot_arrow) |expected| {
            if (arrow != expected) return false;
        } else pivot_arrow = arrow;
    }
    if (shared_len < 2) return false;
    return bundles.memberships.len == 0 or selected(fan.peers, bundles);
}

pub fn resolve(
    a: std.mem.Allocator,
    dir: sg.Direction,
    fan: fan_mod.Fan,
    graph: sg.SemGraph,
    placements: []const sketch.NodePlacement,
    geom: []const routing.NodeGeom,
    bundles: pb.RealizedBundles,
    allocated_ports: port_plan.Plan,
) error{OutOfMemory}!?Resolved {
    if (dir != .TD or !eligible(fan, graph, bundles)) return null;
    var shared_len: usize = 0;
    for (fan.peers) |p| if (p.shared and !rail_closure.contains(bundles.discharged, p.edge_id)) {
        shared_len += 1;
    };
    const peers = try a.alloc(Peer, shared_len);
    var peer_i: usize = 0;
    for (fan.peers) |p| {
        if (!p.shared or rail_closure.contains(bundles.discharged, p.edge_id)) continue;
        const out = &peers[peer_i];
        peer_i += 1;
        const e = routing.findGraphEdge(graph, p.edge_id) orelse return null;
        const ep = allocated_ports.forEdge(e.id) orelse return null;
        const placement = routing.findPlacement(placements, if (fan.direction == .out) e.to else e.from);
        const port: ?sketch.Port = if (fan.direction == .out) ep.target else ep.source;
        out.* = nearPeer(e, placement, port, fan.direction);
        if (p.long) {
            const g = geom[p.peer_idx];
            const pivot = routing.findPlacement(placements, if (fan.direction == .out) e.from else e.to);
            out.long = true;
            out.column = longColumn(g.x + @divTrunc(@as(i32, @intCast(g.w)), 2), fan.direction, pivot, placement, placements);
            out.line = if (fan.direction == .out) g.y else g.y + @as(i32, @intCast(g.h)) - 1;
        }
    }
    const first_ep = allocated_ports.forEdge(peers[0].edge.id) orelse return null;
    return .{
        .pivot = routing.findPlacement(placements, if (fan.direction == .out) peers[0].edge.from else peers[0].edge.to),
        .pivot_port = if (fan.direction == .out) first_ep.source else first_ep.target,
        .direction = fan.direction,
        .peers = peers,
    };
}

/// @guarded-by: fan_rail_test.zig "a long member's tap column slides off an intermediate box"
pub fn longColumn(centre: i32, direction: fan_mod.Direction, pivot: sketch.NodePlacement, leaf: sketch.NodePlacement, placements: []const sketch.NodePlacement) i32 {
    const top = if (direction == .out) pivot.rect.bottom() else leaf.rect.bottom();
    const bottom = (if (direction == .out) leaf.rect.y else pivot.rect.y) - 1;
    if (top > bottom) return centre;
    return sketch.clearLine(false, centre, top, bottom, placements, pivot.id, leaf.id, .{});
}

pub fn build(
    a: std.mem.Allocator,
    resolved: Resolved,
    rail_lift: u32,
    lane: u32,
) error{OutOfMemory}!Built {
    const pivot_p = resolved.pivot;
    const pivot_offset = if (resolved.pivot_port) |port| port.offset else pivot_p.rect.w / 2;
    const sx = pivot_p.rect.x + @as(i32, @intCast(pivot_offset));
    const fan_in = resolved.direction == .in;
    const s_peri: i32 = if (fan_in) pivot_p.rect.y else pivot_p.rect.bottom() - 1;

    var peer_line: i32 = if (fan_in) std.math.minInt(i32) else std.math.maxInt(i32);
    for (resolved.peers) |p| {
        peer_line = if (fan_in) @max(peer_line, p.line) else @min(peer_line, p.line);
    }
    const delta: i32 = @intCast(rail_lift + lane);
    // @guarded-by: fan_rail_test.zig "formal base approach: rail lifts one row when the gap admits it, holds at a gap of 2"
    const anchor: i32 = if (fan_in) pivot_p.rect.y else peer_line;
    const obstacle: i32 = if (fan_in) peer_line else pivot_p.rect.bottom() - 1;
    // @guarded-by: fan_rail_test.zig "labeled fan-OUT rail lifts the crossbar for a 4-cell dropper when the gap admits it"
    var labeled = false;
    for (resolved.peers) |p| {
        if (p.edge.label) |lbl| {
            if (lbl.len > 0) labeled = true;
        }
    }
    const label_lift: i32 = @intCast(fan_mod.LABEL_RUN_EXTRA_ROWS);
    const off: i32 = if (labeled and !fan_in and anchor - 2 - label_lift - delta > obstacle)
        2 + label_lift
    else if (anchor - 3 - delta > obstacle) 3 else 2;
    const rail_y: i32 = anchor - off - delta;

    const stem = try a.alloc(sketch.Point, 2);
    stem[0] = .{ .x = sx, .y = s_peri };
    stem[1] = .{ .x = sx, .y = rail_y };

    const taps = try a.alloc(sketch.Tap, resolved.peers.len);
    var min_x: i32 = sx;
    var max_x: i32 = sx;
    for (resolved.peers, taps) |p, *tap| {
        const tx = p.column;
        // @guarded-by: fan_rail_test.zig "a long member gets a one-cell drop whose tap continues"
        const landing_y: i32 = if (p.long)
            (if (fan_in) rail_y - 1 else rail_y + 1)
        else if (fan_in) p.placement.rect.bottom() - 1 else p.placement.rect.y;
        tap.* = .{
            .edge = p.edge.id,
            .node = p.placement.id,
            .at = .{ .x = tx, .y = rail_y },
            .landing = .{ .x = tx, .y = landing_y },
            .label = if (p.long) null else p.edge.label,
            .arrow = routing.mapArrow(if (fan_in) p.edge.arrow_from else p.edge.arrow_to),
            .continues = p.long,
        };
        min_x = @min(min_x, tx);
        max_x = @max(max_x, tx);
    }

    return .{
        .rail = .{
            .pivot = pivot_p.id,
            .stem = stem,
            .crossbar = .{ .{ .x = min_x, .y = rail_y }, .{ .x = max_x, .y = rail_y } },
            .taps = taps,
            .kind = resolved.peers[0].edge.kind,
            .role = if (fan_in) .fan_in_dropper else .fan_out_dropper,
            .pivot_arrow = routing.mapArrow(if (fan_in) resolved.peers[0].edge.arrow_to else resolved.peers[0].edge.arrow_from),
        },
        .stem = stem,
        .taps = taps,
    };
}

pub fn blocked(
    built: Built,
    pivot_id: sketch.NodeId,
    placements: []const sketch.NodePlacement,
) bool {
    const stem_x = built.rail.stem[0].x;
    const fan_in = built.rail.role == .fan_in_dropper or built.rail.role == .fan_in_rail;
    const stem_lo = if (fan_in) @min(built.rail.stem[0].y, built.rail.stem[1].y) + 1 else built.rail.stem[0].y + 1;
    const stem_hi = if (fan_in) @max(built.rail.stem[0].y, built.rail.stem[1].y) - 1 else built.rail.stem[1].y;
    if (stem_lo <= stem_hi and sketch.columnTouchesAny(stem_x, stem_lo, stem_hi, placements, pivot_id, pivot_id)) return true;
    for (built.taps) |tap| {
        const lo = if (fan_in) @min(tap.at.y, tap.landing.y) + 1 else tap.at.y + 1;
        const hi = if (fan_in) @max(tap.at.y, tap.landing.y) - 1 else tap.landing.y - 1;
        if (lo <= hi and sketch.columnTouchesAny(tap.at.x, lo, hi, placements, tap.node, pivot_id)) return true;
    }
    const crossbar = built.rail.crossbar;
    if (sketch.rowTouchesAny(crossbar[0].y, crossbar[0].x, crossbar[1].x, placements, pivot_id, pivot_id)) return true;
    return false;
}

fn selected(peers: []const fan_mod.FanEdge, bundles: pb.RealizedBundles) bool {
    var shared_len: usize = 0;
    for (peers) |peer| if (peer.shared) {
        shared_len += 1;
    };
    for (bundles.selected_bundles) |sel| {
        if (sel.members.len != shared_len) continue;
        var all = true;
        for (peers) |peer| {
            if (!peer.shared) continue;
            var found = false;
            for (sel.members) |member| {
                if (member == peer.edge_id) found = true;
            }
            if (!found) all = false;
        }
        if (all) return true;
    }
    return false;
}

test {
    _ = @import("fan_rail_test.zig");
}
