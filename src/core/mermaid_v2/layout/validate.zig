//! Sketch validators — six invariant checks on layout output, run by
//! `entry.renderFlowchart` after the budget-ladder produces its winning
//! Sketch. Runs in every build mode (cheap — O(n²) over ≤ ~31 nodes) so
//! `Counts` (via `counts`) exist in release builds too; per-violation LOG
//! lines stay Debug-only in entry.zig; validation never affects output or
//! triggers fallback. Imports: `std` and `../sketch.zig` only — the
//! import-boundary lint keeps `layout/` independent of `lattice/`,
//! `raster/`, and `paint/`.

const std = @import("std");
const sketch = @import("../sketch.zig");

pub const Violation = struct {
    kind: Kind,
    /// Human-readable description; arena-owned (freed by arena reset).
    message: []const u8,

    pub const Kind = enum {
        node_overlap,
        path_off_perimeter,
        path_through_interior,
        cluster_does_not_contain,
        path_crosses_cluster_unauthorized,
        bbox_overflow,
    };
};

pub const ValidationResult = union(enum) {
    ok,
    failed: []const Violation,
};

/// Per-kind violation counts — the machine-readable integrity report.
/// Pure data; consumed by `score.eval` without crossing any lint zone
/// (score may import layout/validate).
///
/// `bbox_overflow` is counted from the Sketch directly (bbox wider than
/// budget), NOT from a `Violation` — `checkBboxBudget` deliberately emits
/// none because the painter clips gracefully. It is still reported here
/// so diagnostics can track clipped renders.
pub const Counts = struct {
    node_overlap: u32 = 0,
    path_off_perimeter: u32 = 0,
    path_through_interior: u32 = 0,
    cluster_containment: u32 = 0,
    cluster_port: u32 = 0,
    bbox_overflow: u32 = 0,
};

/// Tally a `ValidationResult` (plus the Sketch-derived bbox check) into
/// per-kind counts. Pure — no allocation, no logging; safe in all build
/// modes.
pub fn counts(vr: ValidationResult, s: sketch.Sketch) Counts {
    var c: Counts = .{};
    switch (vr) {
        .ok => {},
        .failed => |violations| for (violations) |v| switch (v.kind) {
            .node_overlap => c.node_overlap += 1,
            .path_off_perimeter => c.path_off_perimeter += 1,
            .path_through_interior => c.path_through_interior += 1,
            .cluster_does_not_contain => c.cluster_containment += 1,
            .path_crosses_cluster_unauthorized => c.cluster_port += 1,
            .bbox_overflow => c.bbox_overflow += 1,
        },
    }
    if (s.bbox.w > s.budget.max_width) c.bbox_overflow += 1;
    return c;
}

/// Run every validator. Returns `.ok` when no violations are found, or
/// `.failed` carrying an arena-owned slice of every detected issue.
pub fn validate(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
) !ValidationResult {
    var violations: std.ArrayList(Violation) = .empty;
    errdefer violations.deinit(allocator);

    try checkNodeOverlap(allocator, s, &violations);
    try checkPathEndpoints(allocator, s, &violations);
    try checkPathInteriors(allocator, s, &violations);
    try checkBusBars(allocator, s, &violations);
    try checkClusterContainment(allocator, s, &violations);
    try checkClusterPorts(allocator, s, &violations);
    try checkBboxBudget(allocator, s, &violations);

    if (violations.items.len == 0) {
        violations.deinit(allocator);
        return .ok;
    }
    const owned = try violations.toOwnedSlice(allocator);
    return .{ .failed = owned };
}

/// O(n²) pairwise rect-overlap check across all NodePlacements.
pub fn checkNodeOverlap(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    violations: *std.ArrayList(Violation),
) !void {
    const nodes = s.nodes;
    var i: usize = 0;
    while (i < nodes.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < nodes.len) : (j += 1) {
            if (nodes[i].rect.overlaps(nodes[j].rect)) {
                try emit(allocator, violations, .node_overlap, "node {d} rect overlaps node {d} rect", .{ nodes[i].id, nodes[j].id });
            }
        }
    }
}

fn emit(
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    kind: Violation.Kind,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    try violations.append(allocator, .{ .kind = kind, .message = msg });
}

/// Each EdgePath's first/last polyline point must lie on the perimeter
/// of its source/target NodePlacement.
pub fn checkPathEndpoints(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    violations: *std.ArrayList(Violation),
) !void {
    for (s.edges) |edge| {
        if (edge.polyline.len < 2) {
            try emit(allocator, violations, .path_off_perimeter, "edge {d} has degenerate polyline (len={d}); missing endpoints", .{ edge.id, edge.polyline.len });
            continue;
        }
        const from_node = findNode(s, edge.from) orelse continue;
        const to_node = findNode(s, edge.to) orelse continue;
        const first = edge.polyline[0];
        const last = edge.polyline[edge.polyline.len - 1];
        if (!onPerimeter(from_node.rect, first)) {
            try emit(allocator, violations, .path_off_perimeter, "edge {d} start ({d},{d}) not on perimeter of node {d}", .{ edge.id, first.x, first.y, from_node.id });
        }
        if (!onPerimeter(to_node.rect, last)) {
            try emit(allocator, violations, .path_off_perimeter, "edge {d} end ({d},{d}) not on perimeter of node {d}", .{ edge.id, last.x, last.y, to_node.id });
        }
    }
}

/// No polyline segment may pass through a node's open interior, except
/// the segments adjacent to that edge's own from/to nodes (which
/// legitimately touch the perimeter at their endpoints).
pub fn checkPathInteriors(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    violations: *std.ArrayList(Violation),
) !void {
    for (s.edges) |edge| {
        if (edge.polyline.len < 2) continue;

        var seg_idx: usize = 0;
        while (seg_idx + 1 < edge.polyline.len) : (seg_idx += 1) {
            const a = edge.polyline[seg_idx];
            const b = edge.polyline[seg_idx + 1];

            for (s.nodes) |node| {
                // Skip a node adjacent to this segment as the edge's own endpoint. // guarded-by: validate_test.zig "checkPathInteriors exempts a segment adjacent to its own edge's endpoint but flags a genuine cross by an unrelated edge"
                const is_first_seg = seg_idx == 0;
                const is_last_seg = seg_idx + 2 == edge.polyline.len;
                if (is_first_seg and node.id == edge.from) continue;
                if (is_last_seg and node.id == edge.to) continue;

                if (segmentCrossesInterior(a, b, node.rect)) {
                    try emit(allocator, violations, .path_through_interior, "edge {d} segment ({d},{d})->({d},{d}) crosses interior of node {d}", .{ edge.id, a.x, a.y, b.x, b.y, node.id });
                }
            }
        }
    }
}

/// Bus-bar invariants. The trunk is deliberately EXEMPT from the
/// node-perimeter endpoint rule (its rail ends float in the inter-layer
/// gap); instead:
///   - the stem must be non-degenerate (>= 2 points) and START on the
///     pivot node's perimeter (counted as path_off_perimeter);
///   - every TAP's landing must lie on its node's perimeter (ditto);
///   - no stem/rail/drop segment may cross a node's open interior
///     (counted as path_through_interior; the pivot is exempt on the
///     stem's first segment, each tap's own node on its drop — mirroring
///     checkPathInteriors' endpoint adjacency rule).
/// All violations map onto existing Counts fields, so score.eval's T1
/// tier stays stable regardless of stem/rail/tap mix.
pub fn checkBusBars(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    violations: *std.ArrayList(Violation),
) !void {
    for (s.busbars) |bb| {
        if (bb.stem.len < 2) {
            try emit(allocator, violations, .path_off_perimeter, "busbar of node {d} has degenerate stem (len={d})", .{ bb.pivot, bb.stem.len });
            continue;
        }
        if (findNode(s, bb.pivot)) |pivot| {
            if (!onPerimeter(pivot.rect, bb.stem[0])) {
                try emit(allocator, violations, .path_off_perimeter, "busbar stem start ({d},{d}) not on perimeter of pivot {d}", .{ bb.stem[0].x, bb.stem[0].y, bb.pivot });
            }
        }
        for (bb.taps) |tap| {
            const node = findNode(s, tap.node) orelse continue;
            if (!onPerimeter(node.rect, tap.landing)) {
                try emit(allocator, violations, .path_off_perimeter, "busbar tap for edge {d} lands at ({d},{d}) off perimeter of node {d}", .{ tap.edge, tap.landing.x, tap.landing.y, tap.node });
            }
        }
        for (s.nodes) |node| {
            var si: usize = 0;
            while (si + 1 < bb.stem.len) : (si += 1) {
                if (si == 0 and node.id == bb.pivot) continue;
                if (segmentCrossesInterior(bb.stem[si], bb.stem[si + 1], node.rect)) {
                    try emit(allocator, violations, .path_through_interior, "busbar stem segment ({d},{d})->({d},{d}) crosses interior of node {d}", .{ bb.stem[si].x, bb.stem[si].y, bb.stem[si + 1].x, bb.stem[si + 1].y, node.id });
                }
            }
            if (segmentCrossesInterior(bb.rail[0], bb.rail[1], node.rect)) {
                try emit(allocator, violations, .path_through_interior, "busbar rail ({d},{d})->({d},{d}) crosses interior of node {d}", .{ bb.rail[0].x, bb.rail[0].y, bb.rail[1].x, bb.rail[1].y, node.id });
            }
            for (bb.taps) |tap| {
                if (node.id == tap.node) continue;
                if (segmentCrossesInterior(tap.at, tap.landing, node.rect)) {
                    try emit(allocator, violations, .path_through_interior, "busbar tap for edge {d} ({d},{d})->({d},{d}) crosses interior of node {d}", .{ tap.edge, tap.at.x, tap.at.y, tap.landing.x, tap.landing.y, node.id });
                }
            }
        }
    }
}

/// Each NodePlacement.cluster_id must point to a ClusterFrame whose
/// rect contains the node's rect. Likewise nested ClusterFrames must
/// fit inside their parent.
pub fn checkClusterContainment(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    violations: *std.ArrayList(Violation),
) !void {
    for (s.nodes) |node| {
        const cid = node.cluster_id orelse continue;
        const cluster = findCluster(s, cid) orelse {
            try emit(allocator, violations, .cluster_does_not_contain, "node {d} declares cluster {d} which is not in the Sketch", .{ node.id, cid });
            continue;
        };
        if (!rectContainsRect(cluster.rect, node.rect)) {
            try emit(allocator, violations, .cluster_does_not_contain, "node {d} rect not contained within cluster {d} frame", .{ node.id, cluster.id });
        }
    }
    for (s.clusters) |cluster| {
        const pid = cluster.parent_id orelse continue;
        const parent = findCluster(s, pid) orelse {
            try emit(allocator, violations, .cluster_does_not_contain, "cluster {d} declares parent {d} which is not in the Sketch", .{ cluster.id, pid });
            continue;
        };
        if (!rectContainsRect(parent.rect, cluster.rect)) {
            try emit(allocator, violations, .cluster_does_not_contain, "cluster {d} frame not contained within parent cluster {d}", .{ cluster.id, parent.id });
        }
    }
}

/// Polylines may only cross a cluster border at a declared cluster port.
///
/// No-op for now: `ClusterFrame` (`sketch.zig`) does not yet expose a
/// cluster-port set, so border-crossing authorisation can't be checked.
pub fn checkClusterPorts(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    violations: *std.ArrayList(Violation),
) !void {
    _ = allocator;
    _ = s;
    _ = violations;
}

/// Bbox width vs. budget — informational only: the painter clips
/// gracefully with an overflow marker, so this logs (Debug-only) but
/// never emits a `.bbox_overflow` `Violation`.
/// guarded-by: validate_test.zig "bbox overflow is informational, not a validation failure"
pub fn checkBboxBudget(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    violations: *std.ArrayList(Violation),
) !void {
    _ = allocator;
    _ = violations;
    if (s.bbox.w > s.budget.max_width) {
        // .debug level: std.log filters .debug out of release builds
        // (Debug builds still print it); validate itself runs in every
        // build mode for `counts`, but this diagnostic shouldn't reach
        // release stderr.
        const excess = s.bbox.w - s.budget.max_width;
        std.log.debug("mermaid_v2/validate: bbox width {d} exceeds budget {d} by {d} (clipped at paint)", .{ s.bbox.w, s.budget.max_width, excess });
    }
}

// -- Helpers -----------------------------------------------------------------

fn findNode(s: sketch.Sketch, id: sketch.NodeId) ?sketch.NodePlacement {
    for (s.nodes) |n| {
        if (n.id == id) return n;
    }
    return null;
}

fn findCluster(s: sketch.Sketch, id: sketch.ClusterId) ?sketch.ClusterFrame {
    for (s.clusters) |c| {
        if (c.id == id) return c;
    }
    return null;
}

/// True iff `p` lies on one of the four perimeter edges of `r`
/// (inclusive of corners), or sits exactly 1 cell outside one of those
/// borders along the side normal (port-margin tolerance for cluster-
/// internal edges that pad themselves off the node border).
fn onPerimeter(r: sketch.Rect, p: sketch.Point) bool {
    if (r.w == 0 or r.h == 0) return false;
    const l = r.x;
    const ri = r.right() - 1;
    const t = r.y;
    const bi = r.bottom() - 1;
    const ix = p.x >= l and p.x <= ri;
    const iy = p.y >= t and p.y <= bi;
    if (ix and iy and (p.x == l or p.x == ri or p.y == t or p.y == bi)) return true;
    if (iy and (p.x == l - 1 or p.x == ri + 1)) return true;
    if (ix and (p.y == t - 1 or p.y == bi + 1)) return true;
    return false;
}

/// True iff `outer` covers every cell of `inner`. Uses half-open
/// semantics on the right/bottom edges so that touching rects count as
/// contained (matching `Rect.overlaps`'s edge-touch convention).
fn rectContainsRect(outer: sketch.Rect, inner: sketch.Rect) bool {
    if (inner.w == 0 or inner.h == 0) return true;
    if (outer.w == 0 or outer.h == 0) return false;
    return inner.x >= outer.x and
        inner.y >= outer.y and
        inner.right() <= outer.right() and
        inner.bottom() <= outer.bottom();
}

/// True iff the segment from `a` to `b` passes through the open
/// interior of `r`. Handles axis-aligned segments exactly; for
/// diagonal segments uses a conservative bounding-box test followed by
/// endpoint-in-interior checks.
fn segmentCrossesInterior(a: sketch.Point, b: sketch.Point, r: sketch.Rect) bool {
    if (r.w < 3 or r.h < 3) return false;
    const left = r.x;
    const right_inc = r.right() - 1; // inclusive border; interior is (left, right_inc)
    const top = r.y;
    const bottom_inc = r.bottom() - 1;

    if (pointInInterior(a, r) or pointInInterior(b, r)) return true;

    if (a.x == b.x) {
        const x = a.x;
        if (x <= left or x >= right_inc) return false;
        const y0 = @min(a.y, b.y);
        const y1 = @max(a.y, b.y);
        return y0 < bottom_inc and y1 > top;
    }
    if (a.y == b.y) {
        const y = a.y;
        if (y <= top or y >= bottom_inc) return false;
        const x0 = @min(a.x, b.x);
        const x1 = @max(a.x, b.x);
        return x0 < right_inc and x1 > left;
    }

    // Diagonal: conservative bbox-overlap safety net (IR polylines are expected orthogonal). // guarded-by: validate_test.zig "checkPathInteriors' diagonal fallback is a conservative bbox-overlap test, not a precise line-rect intersection"
    const sx0 = @min(a.x, b.x);
    const sx1 = @max(a.x, b.x);
    const sy0 = @min(a.y, b.y);
    const sy1 = @max(a.y, b.y);
    return sx0 < right_inc and sx1 > left and sy0 < bottom_inc and sy1 > top;
}

/// True iff `p` lies in the strict open interior of `r`, excluding the
/// 1-cell-thick border (which is considered part of the perimeter, not
/// the interior, in our cell model).
fn pointInInterior(p: sketch.Point, r: sketch.Rect) bool {
    if (r.w < 3 or r.h < 3) return false;
    return p.x > r.x and p.x < r.right() - 1 and
        p.y > r.y and p.y < r.bottom() - 1;
}

// -- Tests -------------------------------------------------------------------

test {
    _ = @import("validate_test.zig");
}
