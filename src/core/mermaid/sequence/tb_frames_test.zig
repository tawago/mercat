const std = @import("std");
const fixture = @import("tb_fixture_test.zig");
const frames = @import("tb_frames.zig");

const testing = std.testing;

const inner_span =
    \\sequenceDiagram
    \\    participant A
    \\    participant B
    \\    participant C
    \\    participant D
    \\    A->>B: start
    \\    critical only B and C
    \\        B->>C: lock
    \\    end
    \\    C->>D: done
;

/// Places the boundaries over lifelines `x`, the inner ink taken from those lifelines.
fn placeAt(st: *fixture.Stages, x: []const i32, widen: *std.ArrayList(frames.Widen)) ![]frames.FrameCols {
    const a = st.arena.allocator();
    const step_lo = try a.alloc(i32, st.s.steps.len);
    const step_hi = try a.alloc(i32, st.s.steps.len);
    for (st.s.steps, step_lo, step_hi) |step, *lo, *hi| {
        lo.* = x[@min(step.message.from, step.message.to)];
        hi.* = x[@max(step.message.from, step.message.to)];
    }
    const guard_end = try a.alloc([]i32, st.s.frags.len);
    for (st.s.frags, guard_end, 0..) |f, *ends, fi| {
        ends.* = try a.alloc(i32, f.operands.len);
        for (f.operands, ends.*, 0..) |op, *end, oi| {
            const g = op.guard orelse {
                end.* = std.math.minInt(i32);
                continue;
            };
            const shift = x[f.lo] - st.layout.x[f.lo];
            end.* = st.layout.guard_col[fi][oi] + shift + @as(i32, @intCast(st.texts.widest(g))) - 1;
        }
    }
    const out = try a.alloc(frames.FrameCols, st.s.frags.len);
    const inner: frames.Inner = .{ .step_lo = step_lo, .step_hi = step_hi, .guard_end = guard_end };
    try frames.place(&st.s, &st.rows, x, inner, try frames.stepFrames(a, &st.s), out, widen, a);
    return out;
}

test "a boundary keeps one empty column from each participant it does not enclose, widening the gap between them" {
    var st = try fixture.stages(inner_span, 3);
    defer st.deinit();
    const a = st.arena.allocator();
    var widen: std.ArrayList(frames.Widen) = .empty;

    const placed = try placeAt(&st, st.layout.x, &widen);
    try testing.expectEqual(@as(usize, 0), widen.items.len);
    try testing.expectEqual(st.layout.frames[0], placed[0]);
    try testing.expect(placed[0].left - 1 > st.layout.x[0]);
    try testing.expect(placed[0].right + 1 < st.layout.x[3]);

    const right = try a.dupe(i32, st.layout.x);
    right[3] = placed[0].right + 1;
    _ = try placeAt(&st, right, &widen);
    try testing.expectEqualSlices(frames.Widen, &.{.{ .gap = 3, .by = 1 }}, widen.items);

    widen.clearRetainingCapacity();
    const left = try a.dupe(i32, st.layout.x);
    left[0] = placed[0].left - 1;
    _ = try placeAt(&st, left, &widen);
    try testing.expectEqualSlices(frames.Widen, &.{.{ .gap = 1, .by = 1 }}, widen.items);
}

test "a boundary is wide enough on the left for its kind and three columns past its last enclosed lifeline" {
    var st = try fixture.stages(inner_span, 3);
    defer st.deinit();
    const fc = st.layout.frames[0];
    try testing.expectEqual(st.layout.x[2] + 4, fc.right);
    try testing.expect(fc.left <= st.layout.x[1] - (frames.kindWidth(.critical) + 4));
}
