//! Unified decision-fan layout: fan-OUT (source with 2+ forward edges to
//! real next-layer children) and fan-IN (symmetric, incoming). Both share
//! one rail row with descent/ascent polylines instead of the generic
//! orthogonal router. Runs after `crossing.reduceCrossings`; `layout.zig`
//! reserves the rail's extra inter-layer row. TD: leftmost/rightmost/middle
//! peers detour via the rail bend; center peers (Sx == Tx) descend straight.
//!
//! Allowed imports for layout/*: std + sketch + sem_graph + sibling layout.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
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
};

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
    _ = graph;

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
            });
        }
    }

    return try fans.toOwnedSlice(a);
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
            const need = max_lane + 1;
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
