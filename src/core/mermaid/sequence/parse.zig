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

/// An open block: a fragment, or a block the diagram does not draw whose `end` must not close
/// the fragment around it.
const Block = union(enum) { fragment: model.FragmentKind, ignored };

const max_depth = 64;

const Blocks = struct {
    stack: [max_depth]Block = undefined,
    len: usize = 0,
    overflow: usize = 0,

    fn push(self: *Blocks, block: Block) void {
        if (self.len == max_depth) {
            self.overflow += 1;
            return;
        }
        self.stack[self.len] = block;
        self.len += 1;
    }

    fn pop(self: *Blocks) ?Block {
        if (self.overflow > 0) {
            self.overflow -= 1;
            return .ignored;
        }
        if (self.len == 0) return null;
        self.len -= 1;
        return self.stack[self.len];
    }

    fn top(self: *const Blocks) ?Block {
        if (self.overflow > 0) return .ignored;
        if (self.len == 0) return null;
        return self.stack[self.len - 1];
    }
};

const fragment_words = [_]struct { []const u8, model.FragmentKind }{
    .{ "loop", .loop },
    .{ "alt", .alt },
    .{ "opt", .opt },
    .{ "par", .par },
    .{ "critical", .critical },
    .{ "break", .break_ },
};

/// Fragment openers, dividers, `end`, and the ignored `rect` and `box` blocks; false when the
/// line starts with none of them.
fn parseBlockLine(s: *Scanner, diagram: *SequenceDiagram, blocks: *Blocks) !bool {
    for (fragment_words) |entry| {
        if (!s.consumeKeyword(entry[0])) continue;
        if (blocks.overflow > 0 or blocks.len == max_depth) {
            blocks.push(.ignored);
        } else {
            blocks.push(.{ .fragment = entry[1] });
            try diagram.addElement(.{ .fragment_open = .{ .kind = entry[1], .guard = guardText(s) } });
        }
        s.skipToNextLine();
        return true;
    }
    if (s.consumeKeyword("rect") or s.consumeKeyword("box")) {
        blocks.push(.ignored);
        s.skipToNextLine();
        return true;
    }
    for ([_][]const u8{ "else", "and", "option" }) |word| {
        if (!s.consumeKeyword(word)) continue;
        const guard = guardText(s);
        if (blocks.top()) |block| switch (block) {
            .fragment => |kind| if (kind.dividerWord()) |divider| {
                if (std.mem.eql(u8, divider, word)) try diagram.addElement(.{ .fragment_divider = .{ .guard = guard } });
            },
            .ignored => {},
        };
        s.skipToNextLine();
        return true;
    }
    if (s.consumeKeyword("end")) {
        if (blocks.pop()) |block| if (block == .fragment) try diagram.addElement(.fragment_close);
        s.skipToNextLine();
        return true;
    }
    return false;
}

fn guardText(s: *Scanner) []const u8 {
    s.skipWhitespace();
    return std.mem.trim(u8, s.restOfLine(), " \t\r");
}

fn parseSequenceDiagram(s: *Scanner) !SequenceDiagram {
    var diagram = SequenceDiagram.init(s.allocator);
    errdefer diagram.deinit();
    var blocks: Blocks = .{};

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
        if (try parseBlockLine(s, &diagram, &blocks)) continue;

        if (!try parseSequenceMessage(s, &diagram)) {
            s.skipToNextLine();
        }
    }
    while (blocks.pop()) |block| {
        if (block == .fragment) try diagram.addElement(.fragment_close);
    }

    return diagram;
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
    return std.mem.trim(u8, s.restOfLine(), " \t\r");
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
    const activates = s.matchChar('+');
    const deactivates = !activates and s.matchChar('-');
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
    if (activates) try diagram.addActivation(.{ .participant = to, .is_activate = true });
    if (deactivates) try diagram.addActivation(.{ .participant = from, .is_activate = false });

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

const Element = std.meta.Tag(model.SequenceElement);

fn count(diagram: *const SequenceDiagram, comptime kind: Element) usize {
    var n: usize = 0;
    for (diagram.elements.items) |element| {
        if (element == kind) n += 1;
    }
    return n;
}

fn nth(diagram: *const SequenceDiagram, comptime kind: Element, index: usize) @FieldType(model.SequenceElement, @tagName(kind)) {
    var seen: usize = 0;
    for (diagram.elements.items) |element| {
        if (element != kind) continue;
        if (seen == index) return @field(element, @tagName(kind));
        seen += 1;
    }
    unreachable;
}

test "parse simple sequence diagram with a self message and a direction" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    direction LR
        \\    Alice->>Bob: Hello Bob
        \\    Bob-->>Alice: Hi Alice
        \\    Alice->>Alice: Talk to self
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(Direction.LR, diagram.direction);
    try testing.expectEqual(@as(usize, 2), diagram.participants.items.len);
    try testing.expectEqual(@as(usize, 3), count(&diagram, .message));

    try testing.expectEqualStrings("Alice", diagram.participants.items[0].id);
    try testing.expectEqualStrings("Bob", diagram.participants.items[1].id);

    const first = nth(&diagram, .message, 0);
    try testing.expectEqualStrings("Alice", first.from);
    try testing.expectEqualStrings("Bob", first.to);
    try testing.expectEqualStrings("Hello Bob", first.text);
    try testing.expectEqual(SequenceArrowType.solid_arrow, first.arrow_type);
    try testing.expect(!first.is_self_message);

    try testing.expectEqual(SequenceArrowType.dashed_arrow, nth(&diagram, .message, 1).arrow_type);
    try testing.expect(nth(&diagram, .message, 2).is_self_message);
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

    try testing.expectEqual(@as(usize, 6), count(&diagram, .message));
    try testing.expectEqual(SequenceArrowType.solid_arrow, nth(&diagram, .message, 0).arrow_type);
    try testing.expectEqual(SequenceArrowType.dashed_arrow, nth(&diagram, .message, 1).arrow_type);
    try testing.expectEqual(SequenceArrowType.solid_line, nth(&diagram, .message, 2).arrow_type);
    try testing.expectEqual(SequenceArrowType.dashed_line, nth(&diagram, .message, 3).arrow_type);
    try testing.expectEqual(SequenceArrowType.solid_cross, nth(&diagram, .message, 4).arrow_type);
    try testing.expectEqual(SequenceArrowType.dashed_cross, nth(&diagram, .message, 5).arrow_type);
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
    try testing.expectEqual(@as(usize, 2), count(&diagram, .message));
    try testing.expectEqual(@as(usize, 2), count(&diagram, .note));

    const first = nth(&diagram, .note, 0);
    try testing.expectEqual(types.NotePosition.right_of, first.position);
    try testing.expectEqualStrings("Bob", first.participant1);
    try testing.expectEqualStrings("Bob thinks", first.text);

    const second = nth(&diagram, .note, 1);
    try testing.expectEqual(types.NotePosition.over, second.position);
    try testing.expectEqualStrings("Alice", second.participant1);
    try testing.expectEqualStrings("Bob", second.participant2.?);
    try testing.expectEqualStrings("They greet", second.text);
}

fn tags(diagram: *const SequenceDiagram, buf: []Element) []Element {
    for (diagram.elements.items, 0..) |element, i| buf[i] = element;
    return buf[0..diagram.elements.items.len];
}

test "fragments nest as the source nests them, and operands keep declared order" {
    const testing = std.testing;
    const source =
        \\sequenceDiagram
        \\    loop every batch
        \\        A->>B: send
        \\        alt room
        \\            B->>C: enqueue
        \\        else full
        \\            B-->>A: retry
        \\        end
        \\    end
    ;
    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();
    var buf: [16]Element = undefined;
    const want = [_]Element{ .fragment_open, .message, .fragment_open, .message, .fragment_divider, .message, .fragment_close, .fragment_close };
    try testing.expectEqualSlices(Element, &want, tags(&diagram, &buf));
    try testing.expectEqual(model.FragmentKind.loop, diagram.elements.items[0].fragment_open.kind);
    try testing.expectEqualStrings("every batch", diagram.elements.items[0].fragment_open.guard);
    try testing.expectEqualStrings("full", diagram.elements.items[4].fragment_divider.guard);
}

test "a rect's end never closes its parent, a stray end is ignored, and end of input closes every fragment" {
    const testing = std.testing;
    const source =
        \\sequenceDiagram
        \\    end
        \\    opt maybe
        \\        rect rgb(0, 0, 0)
        \\            A->>B: inside
        \\        end
        \\        A->>B: still inside
        \\    par one
        \\        A->>B: x
        \\    and two
        \\        else not a divider here
        \\        A->>C: y
    ;
    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();
    var buf: [16]Element = undefined;
    const want = [_]Element{ .fragment_open, .message, .message, .fragment_open, .message, .fragment_divider, .message, .fragment_close, .fragment_close };
    try testing.expectEqualSlices(Element, &want, tags(&diagram, &buf));
    try testing.expectEqual(model.FragmentKind.par, diagram.elements.items[3].fragment_open.kind);
}

test "the plus shorthand activates the receiver and the minus shorthand deactivates the sender, after the message" {
    const testing = std.testing;
    const source =
        \\sequenceDiagram
        \\    A->>+B: call
        \\    B-->>-A: back
        \\    A-)B: async
        \\    A--)B: async dashed
    ;
    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();
    var buf: [16]Element = undefined;
    const want = [_]Element{ .message, .activation, .message, .activation, .message, .message };
    try testing.expectEqualSlices(Element, &want, tags(&diagram, &buf));
    try testing.expectEqualStrings("B", diagram.elements.items[0].message.to);
    try testing.expectEqualStrings("B", diagram.elements.items[1].activation.participant);
    try testing.expect(diagram.elements.items[1].activation.is_activate);
    try testing.expectEqualStrings("B", diagram.elements.items[3].activation.participant);
    try testing.expect(!diagram.elements.items[3].activation.is_activate);
    try testing.expectEqual(SequenceArrowType.solid_open, diagram.elements.items[4].message.arrow_type);
    try testing.expectEqual(SequenceArrowType.dashed_open, diagram.elements.items[5].message.arrow_type);
    try testing.expectEqual(@as(usize, 2), diagram.participants.items.len);
}
