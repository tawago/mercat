const std = @import("std");
const fixture = @import("tb_fixture_test.zig");
const Kind = @import("tb_rows.zig").Kind;

const testing = std.testing;

test "steps are label rows then the message line, contiguous, with one bare row after the boxes and after the last step" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    A->>B: one
        \\    B-->>A: two<br>lines
        \\    A->>B
    , 3);
    defer st.deinit();
    const want = [_]Kind{ .box, .box, .box, .bare, .label, .stroke, .label, .label, .stroke, .stroke, .bare };
    try testing.expectEqualSlices(Kind, &want, st.rows.kinds);
    try testing.expectEqual(st.rows.steps[0].stroke + 1, st.rows.steps[1].first);
}

test "an activation runs from the first label row of its first step to the row added where its deactivate stands" {
    var st = try fixture.stages(fixture.piercing_alternative(), 3);
    defer st.deinit();
    const browser = st.rows.bars[1];
    try testing.expectEqual(Kind.tail, st.rows.kinds[browser.last]);
    try testing.expectEqual(st.rows.steps[5].stroke + 1, browser.last);
    const server = st.rows.bars[0];
    try testing.expectEqual(st.rows.steps[0].first, server.first);
    try testing.expectEqual(Kind.tail, st.rows.kinds[server.last]);
}

test "a deactivate declared after end closes its bar below the bottom side; one declared inside closes it inside" {
    var st = try fixture.stages(fixture.piercing_alternative(), 3);
    defer st.deinit();
    const frame = st.rows.frames[0];
    try testing.expectEqual(frame.bottom + 1, st.rows.bars[0].last);
    try testing.expect(st.rows.bars[1].last < frame.sides[1]);
}

test "an unlabeled step that opens an activation gets one row for the cap" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    A->>+B
        \\    B-->>-A
    , 3);
    defer st.deinit();
    try testing.expectEqual(@as(u32, 1), st.rows.steps[0].labels);
    try testing.expectEqual(@as(u32, 0), st.rows.steps[1].labels);
    try testing.expectEqual(st.rows.steps[0].first, st.rows.bars[0].first);
}

test "a broken guard continues on the rows just below its side, and nested sides never share a row" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    loop every single minute
        \\        opt maybe
        \\            A->>B: ping
        \\        end
        \\    end
    , 3);
    defer st.deinit();
    try st.breakText(st.s.frags[0].operands[0].guard.?, 3);
    const outer = st.rows.frames[0];
    try testing.expectEqual(Kind.guard_more, st.rows.kinds[outer.top + 1]);
    try testing.expectEqual(outer.top + 2, st.rows.frames[1].top);
    try testing.expectEqual(st.rows.frames[1].bottom + 1, outer.bottom);
}
