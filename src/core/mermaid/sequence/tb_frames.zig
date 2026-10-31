//! Fragment boundaries in columns: each rectangle wide enough for its kind on the left, three
//! columns past its last enclosed lifeline on the right, clear of all inner ink by one empty
//! column, one cell outside every nested boundary, and clear of the participants it does not
//! enclose by one empty column.

const std = @import("std");
const Allocator = std.mem.Allocator;
const seq = @import("seq.zig");
const Rows = @import("tb_rows.zig").Rows;

pub const FrameCols = struct { left: i32, right: i32 };

/// The ink columns each step and guard reaches, as placed: what a boundary must clear.
pub const Inner = struct {
    step_lo: []const i32,
    step_hi: []const i32,
    /// Per fragment and operand, the last column of its guard; minInt when it has none.
    guard_end: []const []const i32,
};

/// A width a gap must grow by so a boundary keeps its clearance; gap 0 is the left pad.
pub const Widen = struct { gap: usize, by: i32 };

pub fn kindWidth(kind: seq.FragmentKind) i32 {
    return @intCast(kind.word().len);
}

/// The innermost fragment of every step, by walking the items.
pub fn stepFrames(arena: Allocator, s: *const seq.Sequence) ![]?seq.FragIx {
    const out = try arena.alloc(?seq.FragIx, s.steps.len);
    var stack: std.ArrayList(seq.FragIx) = .empty;
    for (s.items) |item| switch (item) {
        .step => |ix| out[ix] = if (stack.items.len > 0) stack.items[stack.items.len - 1] else null,
        .open => |f| try stack.append(arena, f),
        .divider, .engage, .release => {},
        .close => _ = stack.pop(),
    };
    return out;
}

/// Places every boundary, children first, and appends to `widen` each gap too narrow for the
/// clearance between a boundary and the participants outside it.
pub fn place(
    s: *const seq.Sequence,
    rows: *const Rows,
    x: []const i32,
    inner: Inner,
    step_frames: []const ?seq.FragIx,
    out: []FrameCols,
    widen: *std.ArrayList(Widen),
    arena: Allocator,
) !void {
    const n = s.partCount();
    for (s.frags, out) |f, *fc| fc.* = .{
        .left = x[f.lo] - (kindWidth(f.kind) + 4),
        .right = x[f.hi] + 4,
    };
    for (s.frags, 0..) |f, i| {
        const fr = rows.frames[i];
        var p = f.lo;
        while (p <= f.hi) : (p += 1) {
            grow(&out[i], x[p] - @as(i32, @intCast(rows.left(p, fr.top, fr.bottom))), x[p] + @as(i32, @intCast(rows.right(p, fr.top, fr.bottom))));
        }
        for (inner.guard_end[i]) |end| {
            if (end != std.math.minInt(i32)) out[i].right = @max(out[i].right, end + 3);
        }
    }
    for (step_frames, 0..) |frame, ix| {
        var at = frame;
        while (at) |f| : (at = s.frags[f].parent) grow(&out[f], inner.step_lo[ix], inner.step_hi[ix]);
    }
    var i = s.frags.len;
    while (i > 0) {
        i -= 1;
        const parent = s.frags[i].parent orelse continue;
        out[parent].left = @min(out[parent].left, out[i].left - 1);
        out[parent].right = @max(out[parent].right, out[i].right + 1);
    }
    for (s.frags, 0..) |f, fi| {
        const parent = f.parent orelse continue;
        if (f.lo == s.frags[parent].lo) out[fi].left = out[parent].left + 1;
        if (f.hi == s.frags[parent].hi) out[fi].right = out[parent].right - 1;
    }
    for (s.frags, out, 0..) |f, fc, fi| {
        const fr = rows.frames[fi];
        if (f.lo == 0) {
            if (fc.left < 0) try widen.append(arena, .{ .gap = 0, .by = -fc.left });
        } else {
            const ink = x[f.lo - 1] + @as(i32, @intCast(rows.right(f.lo - 1, fr.top, fr.bottom)));
            if (fc.left < ink + 2) try widen.append(arena, .{ .gap = f.lo, .by = ink + 2 - fc.left });
        }
        if (f.hi + 1 < n) {
            const ink = x[f.hi + 1] - @as(i32, @intCast(rows.left(f.hi + 1, fr.top, fr.bottom)));
            if (fc.right > ink - 2) try widen.append(arena, .{ .gap = f.hi + 1, .by = fc.right - ink + 2 });
        }
    }
}

/// One empty column between a boundary and the inner ink `lo..hi`.
fn grow(fc: *FrameCols, lo: i32, hi: i32) void {
    fc.left = @min(fc.left, lo - 2);
    fc.right = @max(fc.right, hi + 2);
}
test {
    _ = @import("tb_frames_test.zig");
}
