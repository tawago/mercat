const sketch = @import("sketch.zig");

const Rect = sketch.Rect;
const NodePlacement = sketch.NodePlacement;
const NodeId = sketch.NodeId;

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
