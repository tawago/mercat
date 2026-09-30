const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const model = @import("model.zig");
const Scanner = @import("../scan.zig").Scanner;
const StateDiagram = model.StateDiagram;
const StateType = model.StateType;
const Direction = types.Direction;

/// How many `[*]` pseudo states of each kind were named so far; their ids are numbered.
const PseudoCounts = struct {
    start: u32 = 0,
    end: u32 = 0,
};

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

    var counts: PseudoCounts = .{};
    try parseStateDiagramBody(s, &diagram, null, &counts);

    return diagram;
}

fn parseStateDiagramBody(
    s: *Scanner,
    diagram: *StateDiagram,
    parent_id: ?[]const u8,
    counts: *PseudoCounts,
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
            try parseStateDeclaration(s, diagram, parent_id, counts);
            continue;
        }

        if (s.consumeKeyword("note") or s.consumeKeyword("Note")) {
            s.skipToNextLine();
            continue;
        }

        try parseStateStatement(s, diagram, parent_id, counts);
    }
}

fn parseStateDeclaration(
    s: *Scanner,
    diagram: *StateDiagram,
    parent_id: ?[]const u8,
    counts: *PseudoCounts,
) Allocator.Error!void {
    s.skipWhitespace();

    const id = s.identifier();
    if (id.len == 0) {
        s.skipToNextLine();
        return;
    }

    s.skipWhitespace();

    const state_type = parseStereotype(s);

    s.skipWhitespace();

    var label: ?[]const u8 = null;
    if (s.matchChar(':')) {
        s.skipWhitespace();
        label = nonEmpty(s.textUntil("\n{"));
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
        try parseStateDiagramBody(s, diagram, id, counts);
        s.skipWhitespaceAndComments();
        _ = s.matchChar('}') or s.consumeKeyword("end");
    }

    s.skipToNextLine();
}

fn parseStereotype(s: *Scanner) StateType {
    if (s.matchString("<<choice>>")) return .choice;
    if (s.matchString("<<fork>>")) return .fork;
    if (s.matchString("<<join>>")) return .join;
    return .regular;
}

fn parseStateStatement(
    s: *Scanner,
    diagram: *StateDiagram,
    parent_id: ?[]const u8,
    counts: *PseudoCounts,
) Allocator.Error!void {
    s.skipWhitespace();
    if (s.isLineEnd()) {
        s.skipToNextLine();
        return;
    }

    const first_state = try parseStateReference(s, diagram, parent_id, counts, true);
    if (first_state.len == 0) {
        s.skipToNextLine();
        return;
    }

    s.skipWhitespace();

    if (s.matchString("-->")) {
        s.skipWhitespace();

        const second_state = try parseStateReference(s, diagram, parent_id, counts, false);

        s.skipWhitespace();
        const label = if (s.labelAfterColon()) |text| nonEmpty(text) else null;

        try diagram.addTransition(.{
            .from = first_state,
            .to = second_state,
            .label = label,
        });
    } else if (s.labelAfterColon()) |text| {
        if (diagram.getStateMut(first_state)) |state| {
            if (state.label == null and text.len > 0) {
                state.label = text;
            }
        }
    }

    s.skipToNextLine();
}

fn parseStateReference(
    s: *Scanner,
    diagram: *StateDiagram,
    parent_id: ?[]const u8,
    counts: *PseudoCounts,
    is_source: bool,
) Allocator.Error![]const u8 {
    s.skipWhitespace();

    if (s.matchString("[*]")) {
        if (is_source) {
            return pseudoState(s, diagram, parent_id, .start, &counts.start);
        }
        return findEnd(diagram, parent_id) orelse
            try pseudoState(s, diagram, parent_id, .end, &counts.end);
    }

    const id = s.identifier();
    if (id.len > 0) {
        try diagram.ensureState(id, parent_id);
    }
    return id;
}

/// The end pseudo state already named in this scope, which every `--> [*]` there shares.
fn findEnd(diagram: *const StateDiagram, parent_id: ?[]const u8) ?[]const u8 {
    for (diagram.state_order.items) |id| {
        const state = diagram.getState(id) orelse continue;
        if (state.state_type == .end and sameParent(state.parent_id, parent_id)) return id;
    }
    return null;
}

fn sameParent(a: ?[]const u8, b: ?[]const u8) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return std.mem.eql(u8, left, right);
}

fn pseudoState(
    s: *Scanner,
    diagram: *StateDiagram,
    parent_id: ?[]const u8,
    comptime state_type: StateType,
    count: *u32,
) Allocator.Error![]const u8 {
    const id = try std.fmt.allocPrint(s.allocator, "[*]_" ++ @tagName(state_type) ++ "_{d}", .{count.*});
    count.* += 1;
    try diagram.trackAllocatedId(id);
    try diagram.addState(.{
        .id = id,
        .state_type = state_type,
        .parent_id = parent_id,
    });
    return id;
}

fn nonEmpty(text: []const u8) ?[]const u8 {
    return if (text.len == 0) null else text;
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
