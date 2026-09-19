const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");

pub const NodeId = prim.NodeId;

pub const EdgeId = prim.EdgeId;

pub const ClusterId = prim.ClusterId;

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn right(self: Rect) i32 {
        return self.x + @as(i32, @intCast(self.w));
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + @as(i32, @intCast(self.h));
    }

    pub fn contains(self: Rect, p: Point) bool {
        if (self.w == 0 or self.h == 0) return false;
        return p.x >= self.x and p.x < self.right() and
            p.y >= self.y and p.y < self.bottom();
    }

    pub fn overlaps(self: Rect, o: Rect) bool {
        if (self.w == 0 or self.h == 0) return false;
        if (o.w == 0 or o.h == 0) return false;
        return self.x < o.right() and o.x < self.right() and
            self.y < o.bottom() and o.y < self.bottom();
    }
};

pub const Dir4 = prim.Dir4;

pub const Direction = prim.Direction;

pub const Shape = prim.Shape;

pub const Port = struct {
    node: NodeId,
    side: Dir4,
    offset: u32,
};

pub const NodePlacement = struct {
    id: NodeId,
    rect: Rect,
    shape: Shape,
    lines: []const []const u8,
    cluster_id: ?ClusterId,
};

pub const ClusterFrame = struct {
    id: ClusterId,
    rect: Rect,
    parent_id: ?ClusterId,
    label: []const u8,
    depth: u8,
    direction: ?Direction = null,
    synthetic: bool = false,
};

pub const ArrowKind = prim.ArrowKind;

pub const EdgeKind = prim.EdgeKind;

pub const EdgeRole = prim.EdgeRole;

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
    /// @guarded-by: raster/labels_test.zig "vertical edge label paints at the exact prim anchor for both rail sides"
    label_left_of_run: bool = false,
};

pub const Tap = struct {
    edge: EdgeId,
    node: NodeId,
    at: Point,
    landing: Point,
    label: ?[]const u8 = null,
    arrow: ArrowKind = .filled,
    continues: bool = false,
};

pub const Rail = struct {
    pivot: NodeId,
    /// @guarded-by: sketch_bundles_test.zig "a stamped sketch names its rail's bundle and its bundle sets alike"
    bundle: ledger.BundleId = ledger.no_bundle,
    stem: []const Point,
    crossbar: [2]Point,
    taps: []const Tap,
    kind: EdgeKind,
    role: EdgeRole = .fan_out_dropper,
    pivot_arrow: ArrowKind = .none,

    /// @guarded-by: raster/labels_test.zig "rail tap labels paint at the tapLabelSeg-predicted segment for off-column and on-column taps"
    pub fn tapLabelSeg(self: Rail, tap: Tap) [2]Point {
        const junction = self.stem[self.stem.len - 1];
        if (tap.at.x != junction.x) {
            return .{ .{ .x = junction.x, .y = tap.at.y }, tap.at };
        }
        return .{ tap.at, tap.landing };
    }
};

pub const WidthBudget = struct {
    max_width: u32,
    rung: u8,
};

pub const Diagnostic = union(enum) {
    width_overflow: struct {
        excess: u32,
        in_cluster: ?ClusterId,
    },
    label_truncated: struct {
        node: NodeId,
        original_len: u32,
    },
    forced_label_wrap: struct {
        node: NodeId,
    },
    crossing_count: u32,
    track_clearance_expired: u32,
};

pub const BundleStampState = enum { unattempted, complete, out_of_memory, rail_invariant };

pub const Sketch = struct {
    bbox: Rect,
    direction: Direction,
    nodes: []const NodePlacement,
    clusters: []const ClusterFrame,
    edges: []const EdgePath,
    rails: []const Rail = &.{},
    rail_claims: []const ledger.RailClaim = &.{},
    /// @guarded-by: entry.zig "V-D-IR-07: a clustered graph's bundles ride piece plans; the root plan stays skipped"
    bundles: ledger.RealizedBundles = .{},
    closure: ledger.ClosureCounts = .{},
    gap_rows: []const ledger.GapRows = &.{},
    bundle_sets: []const ledger.Bundle = &.{},
    bundle_stamp_state: BundleStampState = .unattempted,
    diagnostics: []const Diagnostic,
    budget: WidthBudget,
};

// @guarded-by: layout/validate_test.zig "edge through node interior flagged").

pub fn lineTouchesRect(horizontal: bool, c: i32, lo: i32, hi: i32, r: Rect) bool {
    if (horizontal) {
        if (c < r.y or c >= r.bottom()) return false;
        return lo < r.right() and hi >= r.x;
    } else {
        if (c < r.x or c >= r.right()) return false;
        return lo < r.bottom() and hi >= r.y;
    }
}

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

pub fn columnTouchesAny(x: i32, y_top: i32, y_bot: i32, placements: []const NodePlacement, skip_a: NodeId, skip_b: NodeId) bool {
    return lineTouchesAny(false, x, y_top, y_bot, placements, skip_a, skip_b);
}
pub fn rowTouchesAny(y: i32, x_left: i32, x_right: i32, placements: []const NodePlacement, skip_a: NodeId, skip_b: NodeId) bool {
    return lineTouchesAny(true, y, x_left, x_right, placements, skip_a, skip_b);
}

/// @guarded-by: raster/labels_test.zig "clearLine settles for touch-free line at the MARGIN_BOUND boundary rather than searching further for a margined one"
const MARGIN_BOUND: i32 = 24;

pub const ClearLineOpts = struct {
    margin: bool = false,
    toward: ?i32 = null,
};

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
    var plain: ?i32 = null;

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

test "Rect overlaps and contains" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 5 };
    const b: Rect = .{ .x = 5, .y = 2, .w = 10, .h = 5 };
    const c: Rect = .{ .x = 10, .y = 0, .w = 4, .h = 5 };
    const d: Rect = .{ .x = 100, .y = 100, .w = 1, .h = 1 };
    const empty: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    try std.testing.expectEqual(@as(i32, 10), a.right());
    try std.testing.expectEqual(@as(i32, 5), a.bottom());

    try std.testing.expect(a.contains(.{ .x = 0, .y = 0 }));
    try std.testing.expect(a.contains(.{ .x = 9, .y = 4 }));
    try std.testing.expect(!a.contains(.{ .x = 10, .y = 0 }));
    try std.testing.expect(!a.contains(.{ .x = 0, .y = 5 }));
    try std.testing.expect(!a.contains(.{ .x = -1, .y = 0 }));
    try std.testing.expect(!empty.contains(.{ .x = 0, .y = 0 }));

    try std.testing.expect(a.overlaps(b));
    try std.testing.expect(b.overlaps(a));
    try std.testing.expect(!a.overlaps(c));
    try std.testing.expect(!c.overlaps(a));
    try std.testing.expect(!a.overlaps(d));
    try std.testing.expect(!empty.overlaps(a));
    try std.testing.expect(!a.overlaps(empty));
}

test "clearLine prefers a margined line over a closer touch-free-only line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const want: i32 = 50;
    var list = std.ArrayList(NodePlacement){};
    var next_id: u32 = 0;
    var row: i32 = want - 20;
    while (row <= want + 20) : (row += 1) {
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
    try std.testing.expect(got != want - 3);
    try std.testing.expectEqual(want - 8, got);
}
