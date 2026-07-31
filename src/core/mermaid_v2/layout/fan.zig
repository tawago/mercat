//! Unified decision-fan layout: fan-OUT (source with 2+ forward edges to
//! real next-layer children) and fan-IN (symmetric, incoming). Both share
//! one rail row with descent/ascent polylines instead of the generic
//! orthogonal router. Runs after `crossing.reduceCrossings`; `layout.zig`
//! reserves the rail's extra inter-layer row. TD: leftmost/rightmost/middle
//! peers detour via the rail bend; center peers (Sx == Tx) descend straight.
//!
//! Allowed imports for layout/*: std + sketch + sem_graph + sibling layout.

const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const sugiyama = @import("sugiyama.zig");
const rp = @import("routing_polyline.zig");

pub const Direction = enum { out, in };

/// Positional role of a peer within its fan.
pub const ChildRole = enum {
    /// Left-most peer. Owns the outer rail corner.
    leftmost,
    /// Right-most peer. Owns the outer rail corner.
    rightmost,
    /// Middle peer whose column ≠ pivot column.
    middle,
    /// Middle peer whose column == pivot column.
    center,
};

/// One peer edge in a fan.
pub const FanEdge = struct {
    edge_id: sg.EdgeId,
    /// Index into lg.nodes of the peer node (child for fan-OUT, source
    /// for fan-IN).
    peer_idx: u32,
    role: ChildRole,
    /// Per-member rail lane for unrealized groups; zero preserves merged ink.
    lane: u32 = 0,
};

/// One detected fan.
pub const Fan = struct {
    direction: Direction,
    /// Index into lg.nodes of the pivot (source for fan-OUT, target for
    /// fan-IN). Always a real node.
    pivot_idx: u32,
    /// Layer index where the SOURCES sit. The rail row lives in the gap
    /// between `source_layer` and `source_layer + 1`.
    source_layer: u32,
    /// Peer edges, in left-to-right order after `assignRoles`.
    peers: []FanEdge,
    /// Number of stacked child rows. 1 = the classic single-row fan
    /// (rail row + one child layer). >1 means a wide fan-OUT was wrapped
    /// into a grid by `wrapWideFanOut` because a single row would exceed
    /// the width budget; each child then carries its own short rail at
    /// its grid row (see buildPolyline's grid branch). Only fan-OUT
    /// wraps; fan-IN keeps rows == 1.
    rows: u32 = 1,
    /// Rail row within its inter-layer gap, 0 = the classic single shared row.
    /// Assigned by `fan_lanes.assignLanes`: a fan whose rail would fuse with a
    /// neighbouring fan's into an INCOMPLETE all-to-all bus is lifted to its
    /// own lane so every declared edge stays traceable. 0 for complete meshes,
    /// single-trunk gaps, and pure fan-in/out (byte-identical to pre-lane).
    lane: u32 = 0,
    /// True iff any member edge carries a label. A labeled fan reserves
    /// `LABEL_RUN_EXTRA_ROWS` extra gap rows (extraRowsPerGap) so each
    /// labeled member's PRIVATE vertical dropper is >= 4 cells long —
    /// flank, on-run label row, flank, arrowhead — the DECORATED sandwich
    /// raster/labels_onrun.zig places over (RULE B: an arrowhead is not a
    /// flank, so the head needs its own cell below the lower flank).
    /// Unlabeled fans stay byte-identical.
    /// guarded-by: fan_test.zig "a labeled fan reserves three extra gap rows; an unlabeled fan reserves one"
    labeled: bool = false,
};

/// Extra gap rows a LABELED fan reserves beyond its lane rows: the
/// decorated on-run sandwich needs a 4-cell private dropper (flank, label,
/// flank, head) where the classic gap yields 1.
pub const LABEL_RUN_EXTRA_ROWS: u32 = 3;

// ===================================================================
// Detection
// ===================================================================

/// Detect every fan in the layered graph (both fan-OUT and fan-IN).
/// A node qualifies as a fan-OUT pivot iff it has ≥2 outgoing forward
/// edges to REAL nodes on the immediately-next layer, none through
/// virtuals. Symmetric criterion for fan-IN. Returned slice and inner
/// `peers` slices are arena-allocated via `a`.
pub fn detect(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
) error{OutOfMemory}![]Fan {
    var node_layer = try a.alloc(u32, lg.nodes.len);
    @memset(node_layer, 0);
    for (lg.layers, 0..) |row, li| {
        const lu: u32 = @intCast(li);
        for (row) |idx| node_layer[idx] = lu;
    }

    var fans: std.ArrayListUnmanaged(Fan) = .empty;

    // Two-pass to preserve fan-OUT-then-fan-IN ordering. guarded-by: fan_test.zig "detect distinguishes fan-OUT and fan-IN in the same graph"
    var pivot: u32 = 0;
    while (pivot < lg.nodes.len) : (pivot += 1) {
        switch (lg.nodes[pivot]) {
            .real => {},
            .virtual => continue,
        }
        const p_layer = node_layer[pivot];
        if (try collectFanOut(a, lg, node_layer, pivot, p_layer)) |peers| {
            try fans.append(a, .{
                .direction = .out,
                .pivot_idx = pivot,
                .source_layer = p_layer,
                .peers = peers,
                .labeled = anyPeerLabeled(graph, peers),
            });
        }
    }
    pivot = 0;
    while (pivot < lg.nodes.len) : (pivot += 1) {
        switch (lg.nodes[pivot]) {
            .real => {},
            .virtual => continue,
        }
        const p_layer = node_layer[pivot];
        if (p_layer == 0) continue;
        if (try collectFanIn(a, lg, node_layer, pivot, p_layer - 1)) |peers| {
            try fans.append(a, .{
                .direction = .in,
                .pivot_idx = pivot,
                .source_layer = p_layer - 1,
                .peers = peers,
                .labeled = anyPeerLabeled(graph, peers),
            });
        }
    }

    return try fans.toOwnedSlice(a);
}

/// True iff any peer's semantic edge carries a non-empty label.
fn anyPeerLabeled(graph: sg.SemGraph, peers: []const FanEdge) bool {
    for (peers) |p| {
        if (peerLabel(graph, p.edge_id) != null) return true;
    }
    return false;
}

/// The non-empty semantic label of edge `edge_id`, or null.
fn peerLabel(graph: sg.SemGraph, edge_id: u32) ?[]const u8 {
    for (graph.edges) |e| {
        if (e.id != edge_id) continue;
        if (e.label) |lbl| {
            if (lbl.len > 0) return lbl;
        }
        return null;
    }
    return null;
}

/// Feasibility gate for the labeled-fan row reservation: clears `labeled`
/// on any fan whose on-run label candidate is DOOMED at layout time, so
/// the fan reserves no LABEL_RUN_EXTRA_ROWS it can never consume (and the
/// polyline/rail lifts, which read the same flag, stay off with it —
/// byte-identical to the pre-label geometry). Two generic dooms:
///
///   1. The fan will grid-wrap: its single-row peer span (the EXACT
///      measure fan_grid.wrapGrid gates on) exceeds the width budget. The
///      grid comb re-routes members without the 4-cell private droppers
///      the decorated sandwich needs, so the reserved rows would go dead.
///   2. No labeled member's label can ever fit laterally: every label is
///      wider than the whole estimated canvas (labels_onrun refuses any
///      span wider than the lattice), so on-run placement is impossible.
///
/// Runs AFTER x-assignment (widths + columns final) and BEFORE
/// extraRowsPerGap. Fans with any feasible labeled member are untouched.
/// guarded-by: fan_test.zig "label reservation gate clears doomed fans and keeps feasible ones"
pub fn gateLabelReservations(
    comptime G: type,
    graph: sg.SemGraph,
    fans: []Fan,
    geom: []const G,
    budget: u32,
    h_spacing: u32,
) void {
    var est_w: i64 = 0;
    for (geom) |g| {
        const right: i64 = @as(i64, g.x) + g.w;
        if (right > est_w) est_w = right;
    }
    for (fans) |*f| {
        if (!f.labeled) continue;
        // Doom 1: mirror of fan_grid.wrapGrid's single-row span gate.
        const fit_gap: u32 = if (f.direction == .in) 1 else h_spacing;
        var srw: u32 = 0;
        for (f.peers, 0..) |p, i| {
            srw += geom[p.peer_idx].w;
            if (i + 1 < f.peers.len) srw += fit_gap;
        }
        if (srw > budget) {
            f.labeled = false;
            continue;
        }
        // Doom 2: every labeled member's label is wider than the canvas.
        var any_fits = false;
        for (f.peers) |p| {
            const lbl = peerLabel(graph, p.edge_id) orelse continue;
            if (prim.displayWidth(lbl) <= est_w) {
                any_fits = true;
                break;
            }
        }
        if (!any_fits) f.labeled = false;
    }
}

fn collectFanOut(
    a: std.mem.Allocator,
    lg: sugiyama.LayeredGraph,
    node_layer: []const u32,
    src_idx: u32,
    src_layer: u32,
) error{OutOfMemory}!?[]FanEdge {
    var candidates: std.ArrayListUnmanaged(FanEdge) = .empty;
    defer candidates.deinit(a);

    for (lg.edges) |le| {
        if (le.from != src_idx) continue;
        if (le.reversed) continue;
        if (node_layer[le.to] != src_layer + 1) continue;
        switch (lg.nodes[le.to]) {
            .real => {},
            // guarded-by: fan_test.zig "detect excludes a pivot whose next-layer candidates mix real and virtual peers"
            .virtual => return null,
        }
        try candidates.append(a, .{
            .edge_id = le.edge,
            .peer_idx = le.to,
            .role = .middle,
        });
    }
    if (candidates.items.len < 2) return null;

    const out = try a.alloc(FanEdge, candidates.items.len);
    @memcpy(out, candidates.items);
    return out;
}

fn collectFanIn(
    a: std.mem.Allocator,
    lg: sugiyama.LayeredGraph,
    node_layer: []const u32,
    tgt_idx: u32,
    want_src_layer: u32,
) error{OutOfMemory}!?[]FanEdge {
    var candidates: std.ArrayListUnmanaged(FanEdge) = .empty;
    defer candidates.deinit(a);

    for (lg.edges) |le| {
        if (le.to != tgt_idx) continue;
        if (le.reversed) continue;
        if (node_layer[le.from] != want_src_layer) continue;
        switch (lg.nodes[le.from]) {
            .real => {},
            .virtual => return null,
        }
        try candidates.append(a, .{
            .edge_id = le.edge,
            .peer_idx = le.from,
            .role = .middle,
        });
    }
    if (candidates.items.len < 2) return null;

    const out = try a.alloc(FanEdge, candidates.items.len);
    @memcpy(out, candidates.items);
    return out;
}

// ===================================================================
// Gap reservation
// ===================================================================

/// Per-gap extra rows. Entry i is extra rows in the gap between layer i
/// and layer i+1. Each fan reserves `fan.lane + 1` rows at its `source_layer`
/// gap; the gap takes the max across its fans. With every `lane == 0` (the
/// pre-lane-separation default) this is exactly one row per fan gap.
/// guarded-by: layout/fan_lanes_test.zig "lane assignment reserves one extra gap row per lane"
pub fn extraRowsPerGap(
    a: std.mem.Allocator,
    lg: sugiyama.LayeredGraph,
    fans: []const Fan,
) error{OutOfMemory}![]u32 {
    if (lg.layers.len < 2) return try a.alloc(u32, 0);
    const out = try a.alloc(u32, lg.layers.len - 1);
    @memset(out, 0);
    for (fans) |f| {
        if (f.source_layer < out.len) {
            var max_lane = f.lane;
            for (f.peers) |peer| max_lane = @max(max_lane, peer.lane);
            // Labeled fan: reserve the decorated on-run sandwich's extra
            // rows so a member's private dropper is flank + label row +
            // flank + head long.
            const label_rows: u32 = if (f.labeled) LABEL_RUN_EXTRA_ROWS else 0;
            const need = max_lane + 1 + label_rows;
            if (need > out[f.source_layer]) out[f.source_layer] = need;
        }
    }
    return out;
}

// ===================================================================
// Wide fan-OUT wrapping (grid layout) — see fan_grid.zig
// ===================================================================

/// Re-export from fan_grid.zig. Wrap any fan-OUT whose single-row child
/// span exceeds the `budget` width into a multi-row grid. See fan_grid.zig
/// for the full implementation and documentation.
pub const wrapWideFanOut = @import("fan_grid.zig").wrapWideFanOut;

/// Re-export from fan_grid.zig. Wrap any flat fan-IN whose single-row
/// source span exceeds the `budget` width into a multi-row grid above the
/// shared target — keeping the diagram TD so the ladder never rotates it.
pub const wrapWideFanIn = @import("fan_grid.zig").wrapWideFanIn;

// ===================================================================
// Role assignment
// ===================================================================

/// Fill in peer roles based on each peer's center x. Must be called
/// AFTER coords.assignInitialX / centerByBarycenter / normalizeX but
/// BEFORE applyDirection.
pub fn assignRoles(fans: []Fan, center_x: []const i32) void {
    for (fans) |*f| {
        const Ctx = struct {
            cx: []const i32,
            fn lt(c: @This(), a_e: FanEdge, b_e: FanEdge) bool {
                const ax = c.cx[a_e.peer_idx];
                const bx = c.cx[b_e.peer_idx];
                if (ax != bx) return ax < bx;
                return a_e.edge_id < b_e.edge_id;
            }
        };
        std.mem.sort(FanEdge, f.peers, Ctx{ .cx = center_x }, Ctx.lt);

        const pivot_cx = center_x[f.pivot_idx];
        const n = f.peers.len;
        for (f.peers, 0..) |*p, i| {
            const px = center_x[p.peer_idx];
            if (i == 0) {
                p.role = .leftmost;
            } else if (i == n - 1) {
                p.role = .rightmost;
            } else if (px == pivot_cx) {
                p.role = .center;
            } else {
                p.role = .middle;
            }
        }
    }
}

// ===================================================================
// Lookup
// ===================================================================

pub const LookupHit = struct {
    fan: *const Fan,
    peer: *const FanEdge,
};

/// Find the fan/peer matching `edge_id`. Returns null if not part of
/// any detected fan.
pub fn lookup(fans: []const Fan, edge_id: sg.EdgeId) ?LookupHit {
    for (fans) |*f| {
        for (f.peers) |*p| {
            if (p.edge_id == edge_id) return .{ .fan = f, .peer = p };
        }
    }
    return null;
}

// ===================================================================
// Co-channel membership
// ===================================================================

/// The co-channel sets the detected fans authorize: one per group of peers
/// sharing a rail lane, in fan order then peer order.
///
/// Peers on one lane paint one shared rail run, so their ink sharing is a
/// structural consequence of the fan, not an accident of routing — exactly
/// the sharing a crossing law must not read as a fabricated junction. A lane
/// holding a single peer is no set: that peer shares with nobody.
///
/// `peer.lane` is the per-member lane `fan_lanes.assignLanes` hands out when
/// a carve-out leaves a group unrealized, and stays 0 everywhere else — so
/// the ordinary result is one set per fan holding all of its peers, which is
/// what a clustered render (empty realized plan, no per-member lanes) always
/// gets. Members are edge ids in the caller's own id space.
/// guarded-by: fan_test.zig "co-sets group a fan's peers by rail lane"
pub fn coSets(
    a: std.mem.Allocator,
    fans: []const Fan,
) error{OutOfMemory}![]const ledger.CoSet {
    var out: std.ArrayListUnmanaged(ledger.CoSet) = .empty;
    var members: std.ArrayListUnmanaged(ledger.EdgeId) = .empty;
    defer members.deinit(a);
    for (fans) |f| {
        for (f.peers, 0..) |seed, i| {
            // First peer on this lane owns the group; later ones are already
            // inside it.
            var already = false;
            for (f.peers[0..i]) |earlier| {
                if (earlier.lane == seed.lane) already = true;
            }
            if (already) continue;

            members.clearRetainingCapacity();
            for (f.peers) |p| {
                if (p.lane == seed.lane) try members.append(a, p.edge_id);
            }
            if (members.items.len < 2) continue;
            try out.append(a, .{
                .origin = .fan_rail,
                .members = try a.dupe(ledger.EdgeId, members.items),
            });
        }
    }
    return out.toOwnedSlice(a);
}

// ===================================================================
// Fan-IN centroid (no fan-OUT analogue: barycenter handles that case)
// ===================================================================

/// Returns the source-centroid x for a node iff it satisfies the fan-IN
/// criterion. Caller (layout.zig::centerByBarycenter) uses this as the
/// desired-x override during initial centering.
pub fn fanInCentroid(
    comptime G: type,
    geom: []const G,
    lg: sugiyama.LayeredGraph,
    idx: u32,
) ?i32 {
    switch (lg.nodes[idx]) {
        .real => {},
        .virtual => return null,
    }
    const tgt_layer = geom[idx].layer;
    if (tgt_layer == 0) return null;
    const want_src_layer = tgt_layer - 1;

    var sum: i64 = 0;
    var n: u32 = 0;
    for (lg.edges) |e| {
        if (e.to != idx) continue;
        if (e.reversed) continue;
        if (geom[e.from].layer != want_src_layer) continue;
        switch (lg.nodes[e.from]) {
            .real => {},
            .virtual => return null,
        }
        const g = geom[e.from];
        sum += g.x + @divTrunc(@as(i32, @intCast(g.w)), 2);
        n += 1;
    }
    if (n < 2) return null;
    return @intCast(@divTrunc(sum, @as(i64, @intCast(n))));
}

// ===================================================================
// Polyline construction + port helpers live in `fan_polyline.zig`
// ===================================================================

test {
    _ = @import("fan_test.zig");
}
