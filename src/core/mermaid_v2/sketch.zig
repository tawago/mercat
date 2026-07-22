//! Sketch — geometric IR for the mermaid_v2 flowchart pipeline: sole output
//! of layout, sole input to rasterization. Pure integer geometry (rects,
//! polylines, discrete perimeter ports) — no characters, glyphs, cells, or
//! terminal concepts; those live downstream in `lattice.zig`/`paint.zig`.
//!
//! Coordinates are signed `i32` (off-canvas construction during routing);
//! sizes/counts are `u32`. Slice fields are caller-allocated and borrowed;
//! `label` strings are owned by the producer (typically the layout arena)
//! and must outlive any consumer.
//!
//! Imports `std` and `prim` only; must not depend on `paint`, `lattice`,
//! `parse`, or any other mermaid_v2 module (enforced by `tools/lint_imports.zig`).

const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");

// -- Identifiers -------------------------------------------------------------

/// Stable identifier for a node within a single Sketch.
pub const NodeId = prim.NodeId;

/// Stable identifier for an edge within a single Sketch.
pub const EdgeId = prim.EdgeId;

/// Stable identifier for a cluster (subgraph) within a single Sketch.
pub const ClusterId = prim.ClusterId;

// -- Geometry primitives -----------------------------------------------------

/// A 2D integer point. Coordinates may be negative during intermediate
/// layout computation; the final Sketch's `bbox` defines the inhabited
/// region.
pub const Point = struct {
    x: i32,
    y: i32,
};

/// Axis-aligned rectangle with integer origin and unsigned size.
/// `(x, y)` is the top-left corner; `w` and `h` are exclusive extents,
/// so a rect with `w = 0` or `h = 0` is empty.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    /// Exclusive right edge: x + w.
    pub fn right(self: Rect) i32 {
        return self.x + @as(i32, @intCast(self.w));
    }

    /// Exclusive bottom edge: y + h.
    pub fn bottom(self: Rect) i32 {
        return self.y + @as(i32, @intCast(self.h));
    }

    /// True iff `p` lies inside the half-open rectangle
    /// `[x, x+w) × [y, y+h)`. Empty rects contain no points.
    pub fn contains(self: Rect, p: Point) bool {
        if (self.w == 0 or self.h == 0) return false;
        return p.x >= self.x and p.x < self.right() and
            p.y >= self.y and p.y < self.bottom();
    }

    /// True iff `self` and `o` share at least one interior cell.
    /// Touching edges only (zero-area intersection) does NOT count as
    /// overlap. Empty rects never overlap.
    pub fn overlaps(self: Rect, o: Rect) bool {
        if (self.w == 0 or self.h == 0) return false;
        if (o.w == 0 or o.h == 0) return false;
        return self.x < o.right() and o.x < self.right() and
            self.y < o.bottom() and o.y < self.bottom();
    }
};

// -- Direction enums ---------------------------------------------------------

/// Cardinal direction of a port on a node perimeter.
pub const Dir4 = prim.Dir4;

/// Overall flowchart layout direction, mirroring Mermaid's TD/BT/LR/RL.
pub const Direction = prim.Direction;

// -- Node geometry -----------------------------------------------------------

/// Visual shape of a node. Layout uses this to choose perimeter
/// geometry; paint uses it (downstream) to choose glyphs.
pub const Shape = prim.Shape;

/// A discrete attachment point on a node's perimeter. `offset` is the
/// 0-based cell index along the chosen `side`, measured from the
/// north-or-west corner. The producing layout pass guarantees
/// `offset < (side is north|south ? node.rect.w : node.rect.h)`.
pub const Port = struct {
    node: NodeId,
    side: Dir4,
    offset: u32,
};

/// One placed node in the Sketch. `rect` is the bounding box of the
/// shape's drawn perimeter; `lines` are the node's display rows — already
/// hard-break-split and (under budget pressure) soft-wrapped — borrowed from
/// the layout arena. The rows are the exact text painted, computed once at
/// sizing time so box dimensions and rasterization never disagree (P1a/P1d).
pub const NodePlacement = struct {
    id: NodeId,
    rect: Rect,
    shape: Shape,
    lines: []const []const u8,
    cluster_id: ?ClusterId,
};

// -- Cluster geometry --------------------------------------------------------

/// Frame of a cluster (subgraph). `parent_id` is null for top-level
/// clusters; `depth` is 0 at the top level and increments with nesting.
pub const ClusterFrame = struct {
    id: ClusterId,
    rect: Rect,
    parent_id: ?ClusterId,
    label: []const u8,
    depth: u8,
    /// Layout direction this cluster declared via an in-body `direction`
    /// line, or null if it inherits from its parent / the top-level graph.
    direction: ?Direction = null,
    /// Mirrors `sem_graph.Cluster.synthetic`: an invisible packing frame
    /// (motif/pack.zig) — sized with zero pad at stitch and skipped by the
    /// cluster rasterizer, so it never paints.
    synthetic: bool = false,
};

// -- Edge geometry -----------------------------------------------------------

/// Arrowhead style at one end of an edge.
pub const ArrowKind = enum {
    none,
    open,
    filled,
    circle,
    cross,
};

/// Stroke style of an edge. Shared with `sem_graph.zig` via `prim`.
pub const EdgeKind = prim.EdgeKind;

/// Routing intent of an edge. Carries downstream the "why" of the
/// polyline so raster/paint don't have to re-derive it from cell geometry.
pub const EdgeRole = prim.EdgeRole;

/// One routed edge in the Sketch. `polyline` is the orthogonal (or
/// near-orthogonal) sequence of points the edge passes through, from
/// `from`'s port to `to`'s port inclusive. The slice has length ≥ 2.
pub const EdgePath = struct {
    id: EdgeId,
    from: NodeId,
    to: NodeId,
    polyline: []const Point,
    port_from: Port,
    port_to: Port,
    arrow_from: ArrowKind,
    arrow_to: ArrowKind,
    label: ?[]const u8,
    kind: EdgeKind,
    role: EdgeRole = .forward,
    /// Set by `layout/clusters.computeBbox` when the width lever relocates a back-edge rail label LEFT of the rail (`prim.edgeLabelAnchor`); `raster/labels` honors it. // guarded-by: raster/labels_test.zig "vertical edge label paints at the exact prim anchor for both rail sides"
    label_left_of_rail: bool = false,
};

// -- Bus-bars (first-class fan trunks) ----------------------------------------

/// One tap off a bus-bar trunk: the branch serving exactly one edge of a
/// fan. `at` lies ON the trunk rail row; `landing` lies on the tap node's
/// perimeter. The drop between them is one straight orthogonal segment.
pub const Tap = struct {
    edge: EdgeId,
    node: NodeId,
    at: Point,
    landing: Point,
    label: ?[]const u8 = null,
    arrow: ArrowKind = .filled,
};

/// A first-class fan bus-bar: ONE owned trunk plus per-edge taps, instead of
/// N overlapping sibling polylines. Every `Tap.edge` here has NO `EdgePath`
/// in `Sketch.edges` — the bus-bar is that edge's sole geometry, so score
/// accounting counts the trunk once and raster owns the junction bits.
///
/// `stem` runs from the pivot node's perimeter to the rail junction
/// (>= 2 points, first point on the pivot perimeter). `rail` is the
/// horizontal rail span, x-ordered (`rail[0].x <= rail[1].x`, equal y);
/// it always covers the stem end and every `Tap.at`.
pub const BusBar = struct {
    pivot: NodeId,
    stem: []const Point,
    rail: [2]Point,
    taps: []const Tap,
    kind: EdgeKind,
    role: EdgeRole = .fan_out_rail,
    pivot_arrow: ArrowKind = .none,

    /// Segment a tap's label anchors to (off-column: junction→tap rail stretch; on-column: tap→landing drop); shared by bbox reservation and rasterization. // guarded-by: raster/labels_test.zig "bus-bar tap labels paint at the tapLabelSeg-predicted segment for off-column and on-column taps"
    pub fn tapLabelSeg(self: BusBar, tap: Tap) [2]Point {
        const junction = self.stem[self.stem.len - 1];
        if (tap.at.x != junction.x) {
            return .{ .{ .x = junction.x, .y = tap.at.y }, tap.at };
        }
        return .{ tap.at, tap.landing };
    }
};

// -- Width budget ------------------------------------------------------------

/// State of the WidthBudget ladder at the time this Sketch was
/// produced. `rung` ranges 0..4:
///   0 = natural,
///   1 = tight,
///   2 = wrap_labels,
///   3 = switch_direction,
///   4 = truncate (terminating).
pub const WidthBudget = struct {
    max_width: u32,
    rung: u8,
};

// -- Diagnostics -------------------------------------------------------------

/// Structured diagnostic emitted by layout and consumed by the budget
/// ladder and downstream rasterization. Tagged-union shape lets each
/// variant carry exactly the data its consumer needs.
pub const Diagnostic = union(enum) {
    /// Layout could not fit within `WidthBudget.max_width`. `excess` is
    /// the number of columns over budget; `in_cluster` localizes the
    /// overflow when possible.
    width_overflow: struct {
        excess: u32,
        in_cluster: ?ClusterId,
    },
    /// A node label was shortened (e.g. with an ellipsis) to fit.
    label_truncated: struct {
        node: NodeId,
        original_len: u32,
    },
    /// A node label was wrapped onto extra lines to fit.
    forced_label_wrap: struct {
        node: NodeId,
    },
    /// Total number of edge crossings in the routed Sketch.
    crossing_count: u32,
};

// -- Sketch ------------------------------------------------------------------

/// Top-level geometric IR. All slices are borrowed from the layout
/// arena; `bbox` encloses every `NodePlacement.rect`,
/// `ClusterFrame.rect`, and every point of every `EdgePath.polyline`.
pub const Sketch = struct {
    bbox: Rect,
    direction: Direction,
    nodes: []const NodePlacement,
    clusters: []const ClusterFrame,
    edges: []const EdgePath,
    /// First-class fan trunks. Edges represented by a bus-bar tap do NOT
    /// appear in `edges`. Defaulted empty so hand-built Sketches (tests)
    /// and pre-busbar-aware code stay source-compatible.
    busbars: []const BusBar = &.{},
    /// Candidate-local branch realization envelope. // guarded-by: entry.zig "V-D-IR-07: clustered production path keeps the realized plan envelope empty"
    joins: ledger.RealizedJoins = .{},
    diagnostics: []const Diagnostic,
    budget: WidthBudget,
};

// -- Straight-run clearance (touch semantics) ---------------------------------
//
// Shared by the layout AND cluster zones (both may import sketch.zig; the
// linter forbids cluster/ → layout/, which is why these live here and not in
// layout/routing_polyline.zig). "Touch" means border cells count as occupied:
// raster cell ownership includes borders, so an edge run along a foreign
// border row/column loses its cells at raster time even though the
// strict-interior validator stays silent
// (guarded-by: layout/validate_test.zig "edge through node interior flagged").
// Everything is axis-parameterized via `horizontal` (true → the run is a row
// at cross position `c` spanning columns [lo, hi]; false → a column
// spanning rows [lo, hi]).

/// True iff a straight run at cross position `c` over `[lo, hi]` touches
/// ANY cell of `r` (borders included).
pub fn lineTouchesRect(horizontal: bool, c: i32, lo: i32, hi: i32, r: Rect) bool {
    if (horizontal) {
        if (c < r.y or c >= r.bottom()) return false;
        return lo < r.right() and hi >= r.x;
    } else {
        if (c < r.x or c >= r.right()) return false;
        return lo < r.bottom() and hi >= r.y;
    }
}

/// True iff the run touches any placement other than the two excluded
/// endpoint nodes.
pub fn lineTouchesAny(
    horizontal: bool,
    c: i32,
    lo: i32,
    hi: i32,
    placements: []const NodePlacement,
    skip_a: NodeId,
    skip_b: NodeId,
) bool {
    for (placements) |p| {
        if (p.id == skip_a or p.id == skip_b) continue;
        if (lineTouchesRect(horizontal, c, lo, hi, p.rect)) return true;
    }
    return false;
}

/// Column/row conveniences for call-site readability.
pub fn columnTouchesAny(x: i32, y_top: i32, y_bot: i32, placements: []const NodePlacement, skip_a: NodeId, skip_b: NodeId) bool {
    return lineTouchesAny(false, x, y_top, y_bot, placements, skip_a, skip_b);
}
pub fn rowTouchesAny(y: i32, x_left: i32, x_right: i32, placements: []const NodePlacement, skip_a: NodeId, skip_b: NodeId) bool {
    return lineTouchesAny(true, y, x_left, x_right, placements, skip_a, skip_b);
}

/// How far `clearLine` searches for a margined line before settling for merely touch-free (a lane flush against a box border reads as crowding). // guarded-by: raster/labels_test.zig "clearLine settles for touch-free line at the MARGIN_BOUND boundary rather than searching further for a margined one"
const MARGIN_BOUND: i32 = 24;

pub const ClearLineOpts = struct {
    /// Prefer a line whose both cross-axis neighbours are ALSO clear
    /// (1-cell visual gap), falling back to plain touch-free.
    margin: bool = false,
    /// When set, try the side toward this cross position first at each
    /// distance, and do NOT test `want` itself (the caller knows it is
    /// blocked). Used by back-edge stub jogs so a jogged stub shortens the
    /// rail rather than lengthening it.
    toward: ?i32 = null,
};

/// Outward search from `want` for the nearest clear straight run. Single
/// sweep: while hunting for a margined line it remembers the nearest plain
/// touch-free line, so a margin miss costs no second window walk. Returns
/// `want` itself when nothing within the search bound is clear (caller
/// falls back to its pre-clearance geometry).
pub fn clearLine(
    horizontal: bool,
    want: i32,
    lo: i32,
    hi: i32,
    placements: []const NodePlacement,
    skip_a: NodeId,
    skip_b: NodeId,
    opts: ClearLineOpts,
) i32 {
    const clear = struct {
        fn f(h: bool, c: i32, l: i32, r: i32, ps: []const NodePlacement, sa: NodeId, sb: NodeId) bool {
            return !lineTouchesAny(h, c, l, r, ps, sa, sb);
        }
    }.f;

    const dirn: i32 = if (opts.toward) |t| (if (t < want) -1 else 1) else -1;
    const start_delta: i32 = if (opts.toward != null) 1 else 0;
    var plain: ?i32 = null; // nearest merely-touch-free line seen

    var delta: i32 = start_delta;
    while (delta < 4096) : (delta += 1) {
        for ([2]i32{ want + dirn * delta, want - dirn * delta }) |c| {
            const center_clear = clear(horizontal, c, lo, hi, placements, skip_a, skip_b);
            if (opts.margin and delta < MARGIN_BOUND) {
                if (center_clear and
                    clear(horizontal, c - 1, lo, hi, placements, skip_a, skip_b) and
                    clear(horizontal, c + 1, lo, hi, placements, skip_a, skip_b))
                    return c;
                if (center_clear and plain == null) plain = c;
            } else if (center_clear) {
                return plain orelse c;
            }
            if (delta == 0) break;
        }
    }
    return plain orelse want;
}

/// First cross position at/after `start` (moving away from the endpoints,
/// toward a rail) whose perpendicular hop over `[hop_lo, hop_hi]` is clear,
/// with the stub-line cells walked so far also clear. The walk tests only
/// the newly entered stub cell each step (the blocked predicate is monotone
/// in the span). Null when the stub line is blocked before any usable hop
/// position (caller falls back to its straight geometry).
pub fn hopPos(
    horizontal: bool,
    stub: i32,
    start: i32,
    hop_lo: i32,
    hop_hi: i32,
    placements: []const NodePlacement,
    skip_a: NodeId,
    skip_b: NodeId,
) ?i32 {
    var c = start;
    while (c < start + 4096) : (c += 1) {
        if (lineTouchesAny(horizontal, stub, c, c, placements, skip_a, skip_b)) return null;
        if (!lineTouchesAny(!horizontal, c, @min(stub, hop_lo), @max(stub, hop_hi), placements, skip_a, skip_b)) return c;
    }
    return null;
}

// -- Tests -------------------------------------------------------------------

test "Rect overlaps and contains" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 5 };
    const b: Rect = .{ .x = 5, .y = 2, .w = 10, .h = 5 };
    const c: Rect = .{ .x = 10, .y = 0, .w = 4, .h = 5 }; // touches a's right edge
    const d: Rect = .{ .x = 100, .y = 100, .w = 1, .h = 1 };
    const empty: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    // right() / bottom()
    try std.testing.expectEqual(@as(i32, 10), a.right());
    try std.testing.expectEqual(@as(i32, 5), a.bottom());

    // contains: interior point
    try std.testing.expect(a.contains(.{ .x = 0, .y = 0 }));
    try std.testing.expect(a.contains(.{ .x = 9, .y = 4 }));
    // contains: on exclusive edge => false
    try std.testing.expect(!a.contains(.{ .x = 10, .y = 0 }));
    try std.testing.expect(!a.contains(.{ .x = 0, .y = 5 }));
    // contains: outside
    try std.testing.expect(!a.contains(.{ .x = -1, .y = 0 }));
    // empty rect contains nothing
    try std.testing.expect(!empty.contains(.{ .x = 0, .y = 0 }));

    // overlaps: genuine intersection
    try std.testing.expect(a.overlaps(b));
    try std.testing.expect(b.overlaps(a));
    // overlaps: edge-touch only => false
    try std.testing.expect(!a.overlaps(c));
    try std.testing.expect(!c.overlaps(a));
    // overlaps: disjoint
    try std.testing.expect(!a.overlaps(d));
    // empty rect overlaps nothing
    try std.testing.expect(!empty.overlaps(a));
    try std.testing.expect(!a.overlaps(empty));
}

// clearLine: margined-over-touch-free preference. Moved here (from the
// former misc grab-bag raster/ test file, since dissolved) since `clearLine`
// is defined in THIS file — raster/ may import sketch.zig directly, so this
// is also the shared mechanism the cluster/bridges.zig `verticalCorridor`
// call site (in the cluster/ zone, which raster/ may not import) relies on.
test "clearLine prefers a margined line over a closer touch-free-only line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const want: i32 = 50;
    var list = std.ArrayList(NodePlacement){};
    var next_id: u32 = 0;
    var row: i32 = want - 20;
    while (row <= want + 20) : (row += 1) {
        // Two openings: a lone touch-free row at delta=3 (its neighbours
        // want-2/want-4 stay blocked, so it can never be margined), and a
        // 5-row-clear band at want-11..want-7 whose centre (want-8) is
        // the first position where the cell AND both its neighbours are
        // clear. Both are well inside MARGIN_BOUND (24).
        const open = row == want - 3 or (row >= want - 11 and row <= want - 7);
        if (open) continue;
        try list.append(alloc, .{
            .id = next_id,
            .rect = .{ .x = 0, .y = row, .w = 10, .h = 1 },
            .shape = .rect,
            .lines = &.{},
            .cluster_id = null,
        });
        next_id += 1;
    }
    const placements = try list.toOwnedSlice(alloc);

    const got = clearLine(true, want, 0, 5, placements, 9999, 9998, .{ .margin = true });
    // The closer touch-free-only line (delta=3) is seen first but is not
    // margined; clearLine must keep searching and settle on the first
    // fully-margined line (delta=8) rather than giving up early.
    try std.testing.expect(got != want - 3);
    try std.testing.expectEqual(want - 8, got);
}
