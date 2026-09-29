const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const model = @import("model.zig");
const Scanner = @import("../scan.zig").Scanner;
const StateDiagram = model.StateDiagram;
const StateType = model.StateType;
const Direction = types.Direction;

pub fn parse(allocator: Allocator, source: []const u8) !StateDiagram {
    var s = Scanner.init(allocator, source);
    return parseStateDiagramImpl(&s);
}

fn parseStateDiagramImpl(s: *Scanner) !StateDiagram {
    var diagram = StateDiagram.init(s.allocator);
    errdefer diagram.deinit();

    s.skipWhitespaceAndComments();

    if (s.consumeKeyword("stateDiagram-v2") or s.consumeKeyword("stateDiagram")) {
        s.skipWhitespace();
        if (s.consumeKeyword("direction")) {
            s.skipWhitespace();
            diagram.direction = s.parseDirection();
        }
    }
    s.skipToNextLine();

    var start_count: u32 = 0;
    var end_count: u32 = 0;

    try parseStateDiagramBody(s, &diagram, null, &start_count, &end_count);

    return diagram;
}

fn parseStateDiagramBody(
    s: *Scanner,
    diagram: *StateDiagram,
    parent_id: ?[]const u8,
    start_count: *u32,
    end_count: *u32,
) Allocator.Error!void {
    while (!s.isAtEnd()) {
        s.skipWhitespaceAndComments();
        if (s.isAtEnd()) break;

        if (s.peekKeyword("end") or s.current() == '}') {
            break;
        }

        if (s.consumeKeyword("direction")) {
            s.skipWhitespace();
            diagram.direction = s.parseDirection();
            s.skipToNextLine();
            continue;
        }

        if (s.consumeKeyword("state")) {
            try parseStateDeclaration(s, diagram, parent_id, start_count, end_count);
            continue;
        }

        if (s.consumeKeyword("note") or s.consumeKeyword("Note")) {
            try parseStateNote(s, diagram);
            continue;
        }

        try parseStateStatement(s, diagram, parent_id, start_count, end_count);
    }
}

fn parseStateDeclaration(
    s: *Scanner,
    diagram: *StateDiagram,
    parent_id: ?[]const u8,
    start_count: *u32,
    end_count: *u32,
) Allocator.Error!void {
    s.skipWhitespace();

    const id = parseStateId(s);
    if (id.len == 0) {
        s.skipToNextLine();
        return;
    }

    s.skipWhitespace();

    var state_type: StateType = .regular;
    if (s.matchString("<<choice>>")) {
        state_type = .choice;
    } else if (s.matchString("<<fork>>")) {
        state_type = .fork;
    } else if (s.matchString("<<join>>")) {
        state_type = .join;
    }

    s.skipWhitespace();

    var label: ?[]const u8 = null;
    if (s.matchChar(':')) {
        s.skipWhitespace();
        const label_start = s.pos;
        while (!s.isAtEnd() and s.current() != '\n' and s.current() != '{') {
            s.advance();
        }
        label = std.mem.trimRight(u8, s.source[label_start..s.pos], " \t\r");
        if (label.?.len == 0) label = null;
    }

    s.skipWhitespace();

    const is_composite = s.matchChar('{');

    try diagram.addState(.{
        .id = id,
        .label = label,
        .state_type = state_type,
        .is_composite = is_composite,
        .parent_id = parent_id,
    });

    if (is_composite) {
        s.skipToNextLine();
        try parseStateDiagramBody(s, diagram, id, start_count, end_count);
        s.skipWhitespaceAndComments();
        _ = s.matchChar('}') or s.consumeKeyword("end");
    }

    s.skipToNextLine();
}

fn parseStateStatement(
    s: *Scanner,
    diagram: *StateDiagram,
    parent_id: ?[]const u8,
    start_count: *u32,
    end_count: *u32,
) Allocator.Error!void {
    s.skipWhitespace();
    if (s.isAtEnd() or s.current() == '\n') {
        s.skipToNextLine();
        return;
    }

    const first_state = try parseStateReference(s, diagram, parent_id, start_count, end_count, true);
    if (first_state.len == 0) {
        s.skipToNextLine();
        return;
    }

    s.skipWhitespace();

    if (s.matchString("-->")) {
        s.skipWhitespace();

        var label: ?[]const u8 = null;

        const second_state = try parseStateReference(s, diagram, parent_id, start_count, end_count, false);

        s.skipWhitespace();
        if (s.matchChar(':')) {
            s.skipWhitespace();
            const label_start = s.pos;
            while (!s.isAtEnd() and s.current() != '\n') {
                s.advance();
            }
            label = std.mem.trimRight(u8, s.source[label_start..s.pos], " \t\r");
            if (label.?.len == 0) label = null;
        }

        try diagram.addTransition(.{
            .from = first_state,
            .to = second_state,
            .label = label,
        });
    } else if (s.matchChar(':')) {
        s.skipWhitespace();
        const label_start = s.pos;
        while (!s.isAtEnd() and s.current() != '\n') {
            s.advance();
        }
        const label = std.mem.trimRight(u8, s.source[label_start..s.pos], " \t\r");

        if (diagram.getStateMut(first_state)) |state| {
            if (state.label == null and label.len > 0) {
                state.label = label;
            }
        }
    }

    s.skipToNextLine();
}

fn parseStateReference(
    s: *Scanner,
    diagram: *StateDiagram,
    parent_id: ?[]const u8,
    start_count: *u32,
    end_count: *u32,
    is_source: bool,
) Allocator.Error![]const u8 {
    s.skipWhitespace();

    if (s.matchString("[*]")) {
        if (is_source) {
            const id = try makeStartId(s, start_count);
            try diagram.trackAllocatedId(id);
            try diagram.addState(.{
                .id = id,
                .state_type = .start,
                .parent_id = parent_id,
            });
            return id;
        } else {
            for (diagram.state_order.items) |existing_id| {
                if (diagram.getState(existing_id)) |existing_state| {
                    if (existing_state.state_type == .end) {
                        const existing_parent = existing_state.parent_id;
                        const parents_match = if (parent_id) |p|
                            (existing_parent != null and std.mem.eql(u8, existing_parent.?, p))
                        else
                            (existing_parent == null);
                        if (parents_match) {
                            return existing_id;
                        }
                    }
                }
            }
            const id = try makeEndId(s, end_count);
            try diagram.trackAllocatedId(id);
            try diagram.addState(.{
                .id = id,
                .state_type = .end,
                .parent_id = parent_id,
            });
            return id;
        }
    }

    const id = parseStateId(s);
    if (id.len > 0) {
        const result = try diagram.states.getOrPut(id);
        if (!result.found_existing) {
            result.value_ptr.* = .{
                .id = id,
                .parent_id = parent_id,
            };
            try diagram.state_order.append(s.allocator, id);
        }
    }
    return id;
}

fn parseStateId(s: *Scanner) []const u8 {
    const start = s.pos;
    while (!s.isAtEnd()) {
        const c = s.current();
        if (s.isIdChar(c)) {
            s.advance();
        } else {
            break;
        }
    }
    return s.source[start..s.pos];
}

fn makeStartId(s: *Scanner, count: *u32) Allocator.Error![]const u8 {
    const id = try std.fmt.allocPrint(s.allocator, "[*]_start_{d}", .{count.*});
    count.* += 1;
    return id;
}

fn makeEndId(s: *Scanner, count: *u32) Allocator.Error![]const u8 {
    const id = try std.fmt.allocPrint(s.allocator, "[*]_end_{d}", .{count.*});
    count.* += 1;
    return id;
}

fn parseStateNote(s: *Scanner, diagram: *StateDiagram) !void {
    s.skipWhitespace();

    var position: types.NotePosition = .right_of;
    if (s.consumeKeyword("left")) {
        s.skipWhitespace();
        _ = s.consumeKeyword("of");
        position = .left_of;
    } else if (s.consumeKeyword("right")) {
        s.skipWhitespace();
        _ = s.consumeKeyword("of");
        position = .right_of;
    }

    s.skipWhitespace();

    const state_id = parseStateId(s);
    if (state_id.len == 0) {
        s.skipToNextLine();
        return;
    }

    s.skipWhitespace();

    if (!s.matchChar(':')) {
        s.skipToNextLine();
        return;
    }

    s.skipWhitespace();
    const text_start = s.pos;
    while (!s.isAtEnd() and s.current() != '\n') {
        s.advance();
    }
    const text = std.mem.trimRight(u8, s.source[text_start..s.pos], " \t\r");

    try diagram.addNote(.{
        .text = text,
        .position = position,
    });

    s.skipToNextLine();
}

test "parse simple state diagram" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    [*] --> Still
        \\    Still --> [*]
        \\    Still --> Moving
        \\    Moving --> Still
        \\    Moving --> Crash
        \\    Crash --> [*]
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 5), diagram.state_order.items.len);
    try testing.expectEqual(@as(usize, 6), diagram.transitions.items.len);

    try testing.expect(diagram.getState("Still") != null);
    try testing.expect(diagram.getState("Moving") != null);
    try testing.expect(diagram.getState("Crash") != null);

    try testing.expect(diagram.getState("[*]_start_0") != null);
    try testing.expectEqual(StateType.start, diagram.getState("[*]_start_0").?.state_type);

    try testing.expect(diagram.getState("[*]_end_0") != null);
    try testing.expectEqual(StateType.end, diagram.getState("[*]_end_0").?.state_type);
}

test "parse state diagram with descriptions" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    s1 : This is state 1
        \\    s2 : This is state 2
        \\    s1 --> s2
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.state_order.items.len);

    const s1 = diagram.getState("s1").?;
    try testing.expectEqualStrings("This is state 1", s1.label.?);

    const s2 = diagram.getState("s2").?;
    try testing.expectEqualStrings("This is state 2", s2.label.?);
}

test "parse state diagram with transition labels" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    s1 --> s2 : go forward
        \\    s2 --> s1 : go back
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.transitions.items.len);
    try testing.expectEqualStrings("go forward", diagram.transitions.items[0].label.?);
    try testing.expectEqualStrings("go back", diagram.transitions.items[1].label.?);
}

test "parse state diagram with composite state" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    [*] --> First
        \\    state First {
        \\        [*] --> second
        \\        second --> [*]
        \\    }
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    const first = diagram.getState("First").?;
    try testing.expect(first.is_composite);

    const second = diagram.getState("second").?;
    try testing.expect(second.parent_id != null);
    try testing.expectEqualStrings("First", second.parent_id.?);
}

test "parse state diagram with choice" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    state if_state <<choice>>
        \\    [*] --> IsPositive
        \\    IsPositive --> if_state
        \\    if_state --> False : if n < 0
        \\    if_state --> True : if n >= 0
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    const choice = diagram.getState("if_state").?;
    try testing.expectEqual(StateType.choice, choice.state_type);
}

test "parse state diagram direction" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    direction LR
        \\    [*] --> A
        \\    A --> [*]
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(Direction.LR, diagram.direction);
}
