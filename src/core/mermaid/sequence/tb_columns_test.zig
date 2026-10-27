const std = @import("std");
const fixture = @import("tb_fixture_test.zig");
const tb_columns = @import("tb_columns.zig");

const testing = std.testing;

const two =
    \\sequenceDiagram
    \\    participant A
    \\    participant B
    \\    A->>B: a label wider than the boxes
;

test "a gap is its widest label plus the comfort margin on each side, and no wider" {
    for ([_]u32{ 3, 2, 1 }) |m| {
        var st = try fixture.stages(two, m);
        defer st.deinit();
        const w: i32 = @intCast(st.texts.widest(st.s.steps[0].message.label));
        try testing.expectEqual(1 + w + 2 * @as(i32, @intCast(m)), st.layout.x[1] - st.layout.x[0]);
    }
}

test "a label starts one comfort margin right of its gap's left participant ink" {
    var st = try fixture.stages(fixture.piercing_alternative(), 3);
    defer st.deinit();
    try testing.expectEqual(st.layout.x[0] + 4, st.layout.label_col[0]);
    try testing.expectEqual(st.layout.x[1] + 1 + 1 + 3, st.layout.label_col[1]);
    try testing.expectEqual(st.layout.x[0] + 1 + 1 + 3, st.layout.label_col[4]);
}

test "a label crossing several gaps takes the one with the most room, a tie going to the gap nearest the sender" {
    var tie = try fixture.stages(
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    A->>C: x
        \\    C->>A: y
    , 3);
    defer tie.deinit();
    try testing.expectEqual(@as(usize, 1), tie.layout.label_gap[0]);
    try testing.expectEqual(@as(usize, 2), tie.layout.label_gap[1]);

    var room = try fixture.stages(
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    B->>C: a much wider label here
        \\    A->>C: z
    , 3);
    defer room.deinit();
    try testing.expectEqual(@as(usize, 2), room.layout.label_gap[1]);
}

test "a label's room is read with every other label in place" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    participant D
        \\    D->>B: a wider label
        \\    A->>D: y
    , 3);
    defer st.deinit();
    try testing.expectEqual(@as(usize, 3), st.layout.label_gap[0]);
    try testing.expectEqual(@as(usize, 3), st.layout.label_gap[1]);
}

test "a gap fits half of each neighbouring box plus the columns between the boxes" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    participant L as A rather long name
        \\    participant R as Another long one
        \\    L->>R: x
    , 3);
    defer st.deinit();
    const gap = st.layout.x[1] - st.layout.x[0];
    try testing.expectEqual(st.layout.half_r[0] + 1 + tb_columns.box_gap + st.layout.half_l[1], gap);
}

test "a guard widens its gap first" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    alt a guard far wider than any label
        \\        A->>B: x
        \\    end
    , 3);
    defer st.deinit();
    const w: i32 = @intCast(st.texts.widest(st.s.frags[0].operands[0].guard.?));
    try testing.expectEqual(1 + w + 6, st.layout.x[1] - st.layout.x[0]);
    try testing.expectEqual(st.layout.x[0] + 4, st.layout.guard_col[0][0]);
}

test "a note left of the first participant widens the left pad instead of leaving the canvas" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    Note left of A: starts here
        \\    A->>B: hello
    , 3);
    defer st.deinit();
    try testing.expectEqual(@as(i32, 0), st.layout.notes[0].left);
    try testing.expect(st.layout.notes[0].right < st.layout.x[0] - 1);
}

test "a label's gap is chosen again after a note over several participants widens a gap" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    B->>C: a wider label
        \\    Note over A,B: a note much wider than every label here
        \\    A->>C: z
    , 3);
    defer st.deinit();
    try testing.expect(st.layout.x[1] - st.layout.x[0] > st.layout.x[2] - st.layout.x[1]);
    try testing.expectEqual(@as(usize, 1), st.layout.label_gap[2]);
}
