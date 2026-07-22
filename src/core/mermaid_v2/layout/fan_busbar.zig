//! First-class BUS-BAR construction for fan-OUT layouts: one `sketch.BusBar`
//! per eligible fan (stem + rail + one `Tap` per peer). Tapped edges get no
//! `EdgePath` — `raster/busbars.zig` paints the trunk from the BusBar's
//! explicit junction bits.
//!
//! SCOPE: single-row (`rows == 1`) TD-internal fan-OUT only; multi-row fans,
//! fan-IN, and fans with per-edge stem conflicts (stroke/arrow mismatch)
//! stay on the per-peer polyline path. Allowed imports (layout zone): std +
//! sem_graph + sketch + siblings.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const fan_mod = @import("fan.zig");
const fan_polyline = @import("fan_polyline.zig");
// Mutual import with routing.zig (legal within the layout zone): routing
// drives this module; we reuse its edge/placement/arrow lookup helpers.
const routing = @import("routing.zig");
const pb = @import("../base/ledger.zig");
const port_plan = @import("port_plan.zig");

/// Revert flag for the behavior-parity escape hatch: `false` restores the
/// per-peer fan polylines (the old `fan.buildPolyline` path, which stays
/// compiled for grid fans regardless). Not score-inert either way.
pub const FAN_BUSBARS = true;

/// One built bus-bar plus the MUTABLE views layout retains so
/// `clusters.computeBbox`'s shift pass can translate the geometry in
/// place (same pattern as `routing.EdgesResult.polylines`).
pub const Built = struct {
    busbar: sketch.BusBar,
    stem: []sketch.Point,
    taps: []sketch.Tap,
};

/// One fan member with its edge and peer placement resolved (once — the
/// eligibility pass fills these so `build` never re-scans the graph).
pub const Peer = struct {
    edge: sg.Edge,
    placement: sketch.NodePlacement,
    port: ?sketch.Port = null,
};

/// An eligible fan's pivot placement plus per-peer resolutions.
pub const Resolved = struct {
    pivot: sketch.NodePlacement,
    pivot_port: ?sketch.Port = null,
    direction: fan_mod.Direction = .out,
    peers: []Peer,
};

/// Resolve `fan` for bus-bar routing, or null when it does not qualify
/// (see module docs). `dir` is the layout-internal direction (BT already
/// canonicalized to TD upstream; LR/RL never detect fans today). Each
/// peer's (edge, placement) is resolved exactly once, into `a` (arena).
pub fn resolve(
    a: std.mem.Allocator,
    dir: sg.Direction,
    fan: fan_mod.Fan,
    graph: sg.SemGraph,
    placements: []const sketch.NodePlacement,
    joins: pb.RealizedJoins,
    allocated_ports: port_plan.Plan,
) error{OutOfMemory}!?Resolved {
    if (!FAN_BUSBARS) return null;
    if (joins.memberships.len == 0 and fan.direction != .out) return null;
    if (fan.rows != 1) return null;
    if (dir != .TD) return null;
    if (fan.peers.len < 2) return null;
    const peers = try a.alloc(Peer, fan.peers.len);
    var kind: ?sg.EdgeKind = null;
    var pivot_arrow: ?sg.ArrowEnd = null;
    for (fan.peers, peers) |p, *out| {
        const e = routing.findGraphEdge(graph, p.edge_id) orelse return null;
        if (fan.direction == .in and e.label != null) return null;
        const ep = allocated_ports.forEdge(e.id) orelse return null;
        if (kind) |k| {
            if (e.kind != k) return null;
        } else kind = e.kind;
        if (e.kind == .invisible) return null;
        const arrow = if (fan.direction == .out) e.arrow_from else e.arrow_to;
        if (joins.memberships.len == 0 and fan.direction == .out and arrow != .none) return null;
        if (pivot_arrow) |expected| {
            if (arrow != expected) return null;
        } else pivot_arrow = arrow;
        // Fan peer/pivot indices index the LAYERED graph, which routing
        // does not see; resolve endpoints from the peer edges instead
        // (fan-OUT: every member edge runs pivot → peer).
        out.* = .{
            .edge = e,
            .placement = routing.findPlacement(placements, if (fan.direction == .out) e.to else e.from),
            .port = if (fan.direction == .out) ep.target else ep.source,
        };
    }
    if (joins.memberships.len != 0 and !selected(joinedMembers(fan), joins) and !meshExempt(fan.peers, joins.mesh_unions)) return null;
    const first_ep = allocated_ports.forEdge(peers[0].edge.id) orelse return null;
    return .{
        .pivot = routing.findPlacement(placements, if (fan.direction == .out) peers[0].edge.from else peers[0].edge.to),
        .pivot_port = if (fan.direction == .out) first_ep.source else first_ep.target,
        .direction = fan.direction,
        .peers = peers,
    };
}

/// Build the bus-bar for a resolved fan: stem on the pivot column, rail at
/// `t_peri - 2 - rail_lift - lane`, one straight drop per peer. `lane` is the
/// fan's `fan_lanes`-assigned rail row (0 = the classic shared row); a lifted
/// lane keeps an incomplete-bipartite fan's rail off its neighbour's row so
/// the two never fuse into a fabricating bus.
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

    // All peers share a layer top (assignY top-aligns a layer); take the
    // min defensively so a shorter rail never cuts into a taller peer.
    var peer_line: i32 = if (fan_in) std.math.minInt(i32) else std.math.maxInt(i32);
    for (resolved.peers) |p| {
        const line = if (fan_in) p.placement.rect.bottom() - 1 else p.placement.rect.y;
        peer_line = if (fan_in) @max(peer_line, line) else @min(peer_line, line);
    }
    const delta: i32 = @intCast(rail_lift + lane);
    // Formal base approach (owner ruling): every terminal arrowhead must have
    // >= 1 straight collinear stroke cell on its base side before any junction.
    // Lifting the rail one extra row (off=3) makes the terminal drop write one
    // straight `│` then the `▼` (`┬│▼`, not `┬▼`). off=3 is used ONLY when the
    // raised rail still clears the pivot (fan-OUT) / the sources (fan-IN); a
    // tight rung halves v_spacing so the gap can be 2, where off=3 would land
    // the rail on the pivot/source border — there we keep off=2 (today's
    // geometry) and blocked() still guards. `delta` stays in the guard so each
    // lane/lift keeps its own row.
    // guarded-by: fan_busbar_test.zig "formal base approach: rail lifts one row when the gap admits it, holds at a gap of 2"
    const anchor: i32 = if (fan_in) pivot_p.rect.y else peer_line;
    const obstacle: i32 = if (fan_in) peer_line else pivot_p.rect.bottom() - 1;
    const off: i32 = if (anchor - 3 - delta > obstacle) 3 else 2;
    const rail_y: i32 = anchor - off - delta;

    const stem = try a.alloc(sketch.Point, 2);
    stem[0] = .{ .x = sx, .y = s_peri };
    stem[1] = .{ .x = sx, .y = rail_y };

    const taps = try a.alloc(sketch.Tap, resolved.peers.len);
    var min_x: i32 = sx;
    var max_x: i32 = sx;
    for (resolved.peers, taps) |p, *tap| {
        const tx = p.placement.rect.x + @as(i32, @intCast(if (p.port) |port| port.offset else p.placement.rect.w / 2));
        tap.* = .{
            .edge = p.edge.id,
            .node = p.placement.id,
            .at = .{ .x = tx, .y = rail_y },
            .landing = .{ .x = tx, .y = if (fan_in) p.placement.rect.bottom() - 1 else p.placement.rect.y },
            .label = p.edge.label,
            .arrow = routing.mapArrow(if (fan_in) p.edge.arrow_from else p.edge.arrow_to),
        };
        min_x = @min(min_x, tx);
        max_x = @max(max_x, tx);
    }

    return .{
        .busbar = .{
            .pivot = pivot_p.id,
            .stem = stem,
            .rail = .{ .{ .x = min_x, .y = rail_y }, .{ .x = max_x, .y = rail_y } },
            .taps = taps,
            // resolve() proved every member edge shares one stroke kind.
            .kind = resolved.peers[0].edge.kind,
            .role = if (fan_in) .fan_in_rail else .fan_out_rail,
            .pivot_arrow = routing.mapArrow(if (fan_in) resolved.peers[0].edge.arrow_to else resolved.peers[0].edge.arrow_from),
        },
        .stem = stem,
        .taps = taps,
    };
}

/// Integrity gate on a BUILT bus-bar: true iff any of its straight runs
/// (stem, rail, or a vertical tap) touches a foreign box. Touch semantics:
/// raster cell ownership includes borders, so border contact amputates the
/// trunk even though no interior is pierced. Reads the artifact's own
/// geometry (never a re-derivation), so it cannot drift from `build`.
/// A blocked fan falls back to the per-peer polyline path, which can dodge.
pub fn blocked(
    built: Built,
    pivot_id: sketch.NodeId,
    placements: []const sketch.NodePlacement,
) bool {
    const stem_x = built.busbar.stem[0].x;
    const fan_in = built.busbar.role == .fan_in_rail or built.busbar.role == .fan_in_trunk;
    const stem_lo = if (fan_in) @min(built.busbar.stem[0].y, built.busbar.stem[1].y) + 1 else built.busbar.stem[0].y + 1;
    const stem_hi = if (fan_in) @max(built.busbar.stem[0].y, built.busbar.stem[1].y) - 1 else built.busbar.stem[1].y;
    if (stem_lo <= stem_hi and sketch.columnTouchesAny(stem_x, stem_lo, stem_hi, placements, pivot_id, pivot_id)) return true;
    for (built.taps) |tap| {
        const lo = if (fan_in) @min(tap.at.y, tap.landing.y) + 1 else tap.at.y + 1;
        const hi = if (fan_in) @max(tap.at.y, tap.landing.y) - 1 else tap.landing.y - 1;
        if (lo <= hi and sketch.columnTouchesAny(tap.at.x, lo, hi, placements, tap.node, pivot_id)) return true;
    }
    // Rail span (peers sit >= 2 rows below the rail, so only the pivot needs
    // excluding).
    const rail = built.busbar.rail;
    if (sketch.rowTouchesAny(rail[0].y, rail[0].x, rail[1].x, placements, pivot_id, pivot_id)) return true;
    return false;
}

fn joinedMembers(fan: fan_mod.Fan) []const fan_mod.FanEdge {
    return fan.peers;
}

fn selected(peers: []const fan_mod.FanEdge, joins: pb.RealizedJoins) bool {
    for (joins.selected_joins) |join| {
        if (join.members.len != peers.len) continue;
        var all = true;
        for (peers) |peer| {
            var found = false;
            for (join.members) |member| {
                if (member == peer.edge_id) found = true;
            }
            if (!found) all = false;
        }
        if (all) return true;
    }
    return false;
}

fn meshExempt(peers: []const fan_mod.FanEdge, unions: []const pb.MeshUnion) bool {
    for (unions) |mesh_union| {
        var all = true;
        for (peers) |peer| {
            var found = false;
            for (mesh_union.members) |member| {
                if (member == peer.edge_id) found = true;
            }
            if (!found) all = false;
        }
        if (all) return true;
    }
    return false;
}

test {
    _ = @import("fan_busbar_test.zig");
}
