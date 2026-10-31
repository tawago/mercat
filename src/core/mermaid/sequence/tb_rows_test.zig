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

test "an activation runs from the line row of the message before its activate to the row added where its deactivate stands" {
    var st = try fixture.stages(fixture.piercing_alternative(), 3);
    defer st.deinit();
    const browser = st.rows.bars[1];
    try testing.expectEqual(st.rows.steps[4].stroke, browser.first);
    try testing.expectEqual(Kind.tail, st.rows.kinds[browser.last]);
    try testing.expectEqual(st.rows.steps[5].stroke + 1, browser.last);
    const server = st.rows.bars[0];
    try testing.expectEqual(st.rows.steps[0].stroke, server.first);
    try testing.expectEqual(Kind.tail, st.rows.kinds[server.last]);
}

test "a deactivate declared after end closes its bar below the bottom side; one declared inside closes it inside" {
    var st = try fixture.stages(fixture.piercing_alternative(), 3);
    defer st.deinit();
    const frame = st.rows.frames[0];
    try testing.expectEqual(frame.bottom + 1, st.rows.bars[0].last);
    try testing.expect(st.rows.bars[1].last < frame.sides[1]);
}

test "an unlabeled message before an activate gets no extra row: the top sits on its line row" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    A->>+B
        \\    B-->>-A
    , 3);
    defer st.deinit();
    try testing.expectEqual(@as(u32, 0), st.rows.steps[0].labels);
    try testing.expectEqual(st.rows.steps[0].stroke, st.rows.bars[0].first);
}

test "an activate followed by a note starts on a row of its own under the message line" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    A->>B: go
        \\    activate A
        \\    activate B
        \\    Note over A,B: both
        \\    deactivate A
        \\    deactivate B
    , 3);
    defer st.deinit();
    const row = st.rows.steps[0].stroke + 1;
    try testing.expectEqual(Kind.bare, st.rows.kinds[row]);
    try testing.expectEqual(row, st.rows.bars[0].first);
    try testing.expectEqual(row, st.rows.bars[1].first);
    try testing.expectEqual(row + 1, st.rows.steps[1].first);
}

test "an activate after another bar's deactivate starts on that bar's bottom row; before it, on the message line" {
    const after =
        \\sequenceDiagram
        \\    A->>B: go
        \\    activate B
        \\    A->>B: more
        \\    deactivate B
        \\    activate C
        \\    B->>C: on
        \\    deactivate C
    ;
    var st = try fixture.stages(after, 3);
    defer st.deinit();
    try testing.expectEqual(st.rows.bars[0].last, st.rows.bars[1].first);
    var before = try fixture.stages(
        \\sequenceDiagram
        \\    A->>B: go
        \\    activate B
        \\    A->>B: more
        \\    activate C
        \\    deactivate B
        \\    B->>C: on
        \\    deactivate C
    , 3);
    defer before.deinit();
    try testing.expectEqual(before.rows.steps[1].stroke, before.rows.bars[1].first);
}

test "an activation with no step still takes two rows, after a message and after a fragment's top side" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    A->>B: hi
        \\    activate B
        \\    deactivate B
        \\    loop
        \\    activate A
        \\    deactivate A
        \\    A->>B: again
        \\    end
    , 3);
    defer st.deinit();
    for (st.rows.bars) |bar| try testing.expectEqual(bar.first + 1, bar.last);
    for (st.rows.bars) |bar| {
        const want = if (bar.part == 1) st.rows.steps[0].stroke else st.rows.frames[0].top + 1;
        try testing.expectEqual(want, bar.first);
    }
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

test "an activate before any message starts on the first row under the boxes" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    activate A
        \\    A->>B: hi
        \\    deactivate A
    , 3);
    defer st.deinit();
    try testing.expectEqual(st.rows.box_rows, st.rows.bars[0].first);
}

test "an activate after a self-message starts on a row of its own under the return row" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    A->>A: think
        \\    activate A
        \\    A->>B: then
        \\    deactivate A
    , 3);
    defer st.deinit();
    const row = st.rows.steps[0].stroke + 2;
    try testing.expectEqual(Kind.self_return, st.rows.kinds[row - 1]);
    try testing.expectEqual(Kind.bare, st.rows.kinds[row]);
    try testing.expectEqual(row, st.rows.bars[0].first);
    try testing.expectEqual(row + 1, st.rows.steps[1].first);
}
