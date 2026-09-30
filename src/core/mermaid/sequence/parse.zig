const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const model = @import("model.zig");
const scan = @import("../scan.zig");
const Scanner = scan.Scanner;
const SequenceDiagram = model.SequenceDiagram;
const SequenceArrowType = model.SequenceArrowType;
const Direction = types.Direction;

pub fn parse(allocator: Allocator, source: []const u8) !SequenceDiagram {
    var s = Scanner.init(allocator, source);
    return parseSequenceDiagram(&s);
}

fn parseSequenceDiagram(s: *Scanner) !SequenceDiagram {
    var diagram = SequenceDiagram.init(s.allocator);
    errdefer diagram.deinit();

    s.skipWhitespaceAndComments();

    _ = s.consumeKeyword("sequenceDiagram");
    s.skipWhitespace();
    if (s.consumeKeyword("direction")) {
        s.skipWhitespace();
        diagram.direction = s.parseDirection();
        diagram.direction_explicit = true;
    }
    s.skipToNextLine();

    while (!s.isAtEnd()) {
        s.skipWhitespaceAndComments();
        if (s.isAtEnd()) break;

        if (s.consumeKeyword("participant") or s.consumeKeyword("actor")) {
            try parseParticipantDecl(s, &diagram);
            continue;
        }
        if (s.consumeKeyword("direction")) {
            s.skipWhitespace();
            diagram.direction = s.parseDirection();
            diagram.direction_explicit = true;
            s.skipToNextLine();
            continue;
        }
        if (s.consumeKeyword("autonumber")) {
            s.skipToNextLine();
            continue;
        }
        if (s.consumeKeyword("Note") or s.consumeKeyword("note")) {
            try parseSequenceNote(s, &diagram);
            continue;
        }
        if (s.consumeKeyword("activate")) {
            try parseActivation(s, &diagram, true);
            continue;
        }
        if (s.consumeKeyword("deactivate")) {
            try parseActivation(s, &diagram, false);
            continue;
        }
        if (skipBlockKeyword(s)) {
            s.skipToNextLine();
            continue;
        }

        if (!try parseSequenceMessage(s, &diagram)) {
            s.skipToNextLine();
        }
    }

    return diagram;
}

fn skipBlockKeyword(s: *Scanner) bool {
    const keywords = [_][]const u8{ "loop", "alt", "else", "opt", "par", "critical", "break", "rect", "end" };
    for (keywords) |keyword| {
        if (s.consumeKeyword(keyword)) return true;
    }
    return false;
}

fn parseParticipantDecl(s: *Scanner, diagram: *SequenceDiagram) !void {
    s.skipWhitespace();

    const id = s.identifier();
    if (id.len == 0) {
        s.skipToNextLine();
        return;
    }

    s.skipWhitespace();
    var alias: ?[]const u8 = null;
    if (s.consumeKeyword("as")) {
        s.skipWhitespace();
        alias = parseAlias(s);
    }

    try diagram.addParticipant(.{
        .id = id,
        .alias = alias,
    });

    s.skipToNextLine();
}

fn parseAlias(s: *Scanner) []const u8 {
    if (s.current() == '"' or s.current() == '\'') {
        const quote = s.current();
        s.advance();
        const start = s.pos;
        while (!s.isAtEnd() and s.current() != quote) {
            s.advance();
        }
        const alias = s.source[start..s.pos];
        if (!s.isAtEnd()) s.advance();
        return alias;
    }
    const start = s.pos;
    while (!s.isLineEnd() and !scan.isWhitespace(s.current())) {
        s.advance();
    }
    return s.source[start..s.pos];
}

fn parseSequenceMessage(s: *Scanner, diagram: *SequenceDiagram) !bool {
    const start_pos = s.pos;

    const from = s.identifier();
    if (from.len == 0) {
        s.pos = start_pos;
        return false;
    }

    s.skipWhitespace();

    const arrow = parseSequenceArrow(s) orelse {
        s.pos = start_pos;
        return false;
    };

    s.skipWhitespace();

    const to = s.identifier();
    if (to.len == 0) {
        s.pos = start_pos;
        return false;
    }

    s.skipWhitespace();
    const text = s.labelAfterColon() orelse "";

    try diagram.addParticipant(.{ .id = from });
    try diagram.addParticipant(.{ .id = to });

    try diagram.addMessage(.{
        .from = from,
        .to = to,
        .text = text,
        .arrow_type = arrow,
        .is_self_message = std.mem.eql(u8, from, to),
    });

    s.skipToNextLine();
    return true;
}

fn parseSequenceArrow(s: *Scanner) ?SequenceArrowType {
    if (s.matchString("-->>")) return .dashed_arrow;
    if (s.matchString("->>")) return .solid_arrow;
    if (s.matchString("--x")) return .dashed_cross;
    if (s.matchString("-x")) return .solid_cross;
    if (s.matchString("--)")) return .dashed_open;
    if (s.matchString("-)")) return .solid_open;
    if (s.matchString("-->")) return .dashed_line;
    if (s.matchString("->")) return .solid_line;

    return null;
}

fn parseSequenceNote(s: *Scanner, diagram: *SequenceDiagram) !void {
    s.skipWhitespace();

    var position: types.NotePosition = .over;

    if (s.consumeKeyword("right")) {
        s.skipWhitespace();
        _ = s.consumeKeyword("of");
        position = .right_of;
    } else if (s.consumeKeyword("left")) {
        s.skipWhitespace();
        _ = s.consumeKeyword("of");
        position = .left_of;
    } else if (s.consumeKeyword("over")) {
        position = .over;
    }

    s.skipWhitespace();

    const participant1 = s.identifier();

    var participant2: ?[]const u8 = null;
    s.skipWhitespace();
    if (s.matchChar(',')) {
        s.skipWhitespace();
        participant2 = s.identifier();
    }

    s.skipWhitespace();
    const text = s.labelAfterColon() orelse "";

    if (participant1.len > 0) {
        try diagram.addParticipant(.{ .id = participant1 });
        if (participant2) |p2| {
            if (p2.len > 0) {
                try diagram.addParticipant(.{ .id = p2 });
            }
        }

        try diagram.addNote(.{
            .position = position,
            .participant1 = participant1,
            .participant2 = participant2,
            .text = text,
        });
    }

    s.skipToNextLine();
}

fn parseActivation(s: *Scanner, diagram: *SequenceDiagram, is_activate: bool) !void {
    s.skipWhitespace();

    const participant_id = s.identifier();
    if (participant_id.len > 0) {
        try diagram.addParticipant(.{ .id = participant_id });

        try diagram.addActivation(.{
            .participant = participant_id,
            .is_activate = is_activate,
        });
    }

    s.skipToNextLine();
}

test "parse simple sequence diagram" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    Alice->>Bob: Hello Bob
        \\    Bob-->>Alice: Hi Alice
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.participants.items.len);
    try testing.expectEqual(@as(usize, 2), diagram.messages.items.len);

    try testing.expectEqualStrings("Alice", diagram.participants.items[0].id);
    try testing.expectEqualStrings("Bob", diagram.participants.items[1].id);

    try testing.expectEqualStrings("Alice", diagram.messages.items[0].from);
    try testing.expectEqualStrings("Bob", diagram.messages.items[0].to);
    try testing.expectEqualStrings("Hello Bob", diagram.messages.items[0].text);
    try testing.expectEqual(SequenceArrowType.solid_arrow, diagram.messages.items[0].arrow_type);

    try testing.expectEqual(SequenceArrowType.dashed_arrow, diagram.messages.items[1].arrow_type);
}

test "parse sequence with explicit participants" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    participant A as Alice
        \\    participant B as Bob
        \\    A->>B: Hello
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.participants.items.len);
    try testing.expectEqualStrings("A", diagram.participants.items[0].id);
    try testing.expectEqualStrings("Alice", diagram.participants.items[0].alias.?);
    try testing.expectEqualStrings("B", diagram.participants.items[1].id);
    try testing.expectEqualStrings("Bob", diagram.participants.items[1].alias.?);
}

test "parse sequence arrow types" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    A->>B: solid arrow
        \\    A-->>B: dashed arrow
        \\    A->B: solid line
        \\    A-->B: dashed line
        \\    A-xB: solid cross
        \\    A--xB: dashed cross
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 6), diagram.messages.items.len);
    try testing.expectEqual(SequenceArrowType.solid_arrow, diagram.messages.items[0].arrow_type);
    try testing.expectEqual(SequenceArrowType.dashed_arrow, diagram.messages.items[1].arrow_type);
    try testing.expectEqual(SequenceArrowType.solid_line, diagram.messages.items[2].arrow_type);
    try testing.expectEqual(SequenceArrowType.dashed_line, diagram.messages.items[3].arrow_type);
    try testing.expectEqual(SequenceArrowType.solid_cross, diagram.messages.items[4].arrow_type);
    try testing.expectEqual(SequenceArrowType.dashed_cross, diagram.messages.items[5].arrow_type);
}

test "parse self message" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    Alice->>Alice: Talk to self
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 1), diagram.messages.items.len);
    try testing.expect(diagram.messages.items[0].is_self_message);
}

test "parse sequence diagram with notes" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    Alice->>Bob: Hello
        \\    Note right of Bob: Bob thinks
        \\    Bob-->>Alice: Hi
        \\    Note over Alice,Bob: They greet
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.participants.items.len);
    try testing.expectEqual(@as(usize, 2), diagram.messages.items.len);
    try testing.expectEqual(@as(usize, 2), diagram.notes.items.len);

    try testing.expectEqual(types.NotePosition.right_of, diagram.notes.items[0].position);
    try testing.expectEqualStrings("Bob", diagram.notes.items[0].participant1);
    try testing.expectEqualStrings("Bob thinks", diagram.notes.items[0].text);

    try testing.expectEqual(types.NotePosition.over, diagram.notes.items[1].position);
    try testing.expectEqualStrings("Alice", diagram.notes.items[1].participant1);
    try testing.expectEqualStrings("Bob", diagram.notes.items[1].participant2.?);
    try testing.expectEqualStrings("They greet", diagram.notes.items[1].text);
}

test "parse sequence diagram direction" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    direction LR
        \\    Alice->>Bob: Hello
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(Direction.LR, diagram.direction);
}
