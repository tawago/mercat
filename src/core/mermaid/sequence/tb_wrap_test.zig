const std = @import("std");
const unicode = @import("unicode");
const parse = @import("parse.zig");
const fit = @import("fit.zig");
const render = @import("render.zig");
const tb_wrap = @import("tb_wrap.zig");
const ladder = @import("../shared/ladder.zig");

const testing = std.testing;
const wide_self_message = render.wide_self_message;

fn drawn(source: []const u8, max_width: u32) ![]const u8 {
    return switch (try render.render(testing.allocator, source, max_width)) {
        .drawn => |text| text,
        .too_wide => error.TestUnexpectedResult,
    };
}

fn expectWithin(text: []const u8, max_width: u32) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try testing.expect(try unicode.rawDisplayWidth(line) <= max_width);
}

fn count(text: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, text, needle);
}

test "the narrowest unwrapped width draws unwrapped; below it the diagram wraps within budget, whole" {
    const allocator = testing.allocator;
    var diagram = try parse.parse(allocator, wide_self_message);
    defer diagram.deinit();
    var unwrapped: std.ArrayList(fit.Spacing) = .empty;
    defer unwrapped.deinit(allocator);
    for (fit.ladder(diagram.direction, diagram.direction_explicit)) |rung| {
        if (!rung.wrap) try unwrapped.append(allocator, rung);
    }
    const painter = render.Painter{ .allocator = allocator, .diagram = &diagram };
    const need = (try ladder.firstFit(unwrapped.items, painter, 0)).too_wide;

    const label = "Commit normalized value + Domain event";
    const whole = try drawn(wide_self_message, need);
    defer allocator.free(whole);
    try expectWithin(whole, need);
    try testing.expect(std.mem.indexOf(u8, whole, label) != null);

    const wrapped = try drawn(wide_self_message, need - 1);
    defer allocator.free(wrapped);
    const narrow = try drawn(wide_self_message, 78);
    defer allocator.free(narrow);
    try testing.expectEqualStrings(narrow, wrapped);
    try expectWithin(wrapped, 78);
    try testing.expect(std.mem.indexOf(u8, wrapped, label) == null);
    try testing.expectEqual(@as(usize, 7), count(wrapped, "►") + count(wrapped, "◄"));
    for ([_][]const u8{ "╭", "╮", "╰", "╯" }) |corner| try testing.expectEqual(@as(usize, 4), count(wrapped, corner));
    for ([_][]const u8{ "Sender", "Ingest", "DataStore", "Worker" }) |name| try testing.expect(std.mem.indexOf(u8, wrapped, name) != null);
}

test "self text wider than the room left wraps within the budget" {
    const source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    A->>B: go
        \\    B->>B: a rather long self message on the last participant here
    ;
    const text = try drawn(source, 38);
    defer testing.allocator.free(text);
    try expectWithin(text, 38);
    try testing.expect(std.mem.indexOf(u8, text, "a rather long self message") == null);
    for ([_][]const u8{ "rather", "long", "self", "message", "participant", "here" }) |word| {
        try testing.expect(std.mem.indexOf(u8, text, word) != null);
    }
}

test "activation bars leave a wrapped label whole" {
    const source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    activate A
        \\    activate B
        \\    A->>B: one two three four five six seven eight
        \\    deactivate A
        \\    deactivate B
    ;
    const allocator = testing.allocator;
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();
    const text = (try tb_wrap.render(allocator, &diagram, .{ .participant = 2, .padding = 2, .wrap = true }, 22)).drawn;
    defer allocator.free(text);
    try expectWithin(text, 22);
    for ([_][]const u8{ "one", "two", "three", "four", "five", "six", "seven", "eight" }) |word| {
        try testing.expect(std.mem.indexOf(u8, text, word) != null);
    }
}

test "a diagram that fits unwrapped draws as before" {
    const source =
        \\sequenceDiagram
        \\    Alice->>Bob: Hello
        \\    Bob-->>Alice: Hi
    ;
    const expected =
        \\  ╭───────╮        ╭──────╮
        \\  │ Alice │        │ Bob  │
        \\  ╰───────╯        ╰──────╯
        \\      ┆     Hello      ┆
        \\      ┆────────────────►
        \\      ┆      Hi        ┆
        \\      ◄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┆
        \\      ┆                ┆
        \\      ┆                ┆
        \\
    ;
    const text = try drawn(source, 78);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "participant names are not wrapped: a pair wider than the budget stays undrawn" {
    const fitted = try render.render(testing.allocator, "sequenceDiagram\nAlice->>Bob: a very long message text here", 18);
    try testing.expect(fitted.too_wide > 18);
}

/// Every lifeline cell and arrowhead sits on a lifeline column read off the last row.
fn expectLifelinesAligned(text: []const u8) !void {
    var rows: std.ArrayList([]const u8) = .empty;
    defer rows.deinit(testing.allocator);
    var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, text, "\n"), '\n');
    while (it.next()) |row| try rows.append(testing.allocator, row);
    var columns = std.StaticBitSet(512).initEmpty();
    try markColumns(rows.items[rows.items.len - 1], &columns, true);
    for (rows.items) |row| try markColumns(row, &columns, false);
}

fn markColumns(row: []const u8, columns: *std.StaticBitSet(512), record: bool) !void {
    var graphemes = unicode.Iterator.init(row);
    while (try graphemes.next()) |g| {
        const lifeline = std.mem.eql(u8, g.bytes, "┆") or std.mem.eql(u8, g.bytes, "►") or std.mem.eql(u8, g.bytes, "◄");
        if (!lifeline) continue;
        if (record) columns.set(g.column_end - 1) else try testing.expect(columns.isSet(g.column_end - 1));
    }
}

fn expectWords(text: []const u8, label: []const u8) !void {
    var words = std.mem.tokenizeScalar(u8, label, ' ');
    while (words.next()) |word| try testing.expect(std.mem.indexOf(u8, text, word) != null);
}

test "a label crossing another participant's bar takes a gap beside it, words whole" {
    const source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    A->>A: a self message long enough to force the wrap rung here
        \\    activate B
        \\    B->>C: x
        \\    deactivate B
        \\    A->>C: alpha bravo charlie delta echo foxtrot golf
    ;
    const text = try drawn(source, 38);
    defer testing.allocator.free(text);
    try expectWithin(text, 38);
    try expectWords(text, "alpha bravo charlie delta echo foxtrot golf");
    try expectWords(text, "a self message long enough to force the wrap rung here");
    try expectLifelinesAligned(text);
}

test "a wide-character label crossed by a bar keeps every row aligned" {
    const source =
        \\sequenceDiagram
        \\    participant A as Alpha
        \\    participant B as Bravo
        \\    participant C as Charlie
        \\    A->>B: start
        \\    activate B
        \\    A->>C: 日本語のラベル日本語の
        \\    B->>A: done
        \\    deactivate B
        \\    C->>C: a very long self message that will not fit in the budget at all here
    ;
    const text = try drawn(source, 58);
    defer testing.allocator.free(text);
    try expectWithin(text, 58);
    try testing.expect(std.mem.indexOf(u8, text, "日本語のラベル") != null);
    try expectLifelinesAligned(text);
}

test "self text stops short of a bar to its right" {
    const source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B as Bravo
        \\    A->>B: go
        \\    activate B
        \\    A->>A: some words that run on toward the active bar beside
        \\    B->>A: back
        \\    deactivate B
    ;
    const allocator = testing.allocator;
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();
    const refused = try tb_wrap.render(allocator, &diagram, .{ .participant = 2, .padding = 2, .wrap = true }, 60);
    try testing.expect(refused.too_wide > 60);
    const text = (try tb_wrap.render(allocator, &diagram, .{ .participant = 8, .padding = 2, .wrap = true }, 60)).drawn;
    defer allocator.free(text);
    try expectWords(text, "some words that run on toward the active bar beside");
    try expectLifelinesAligned(text);
    var rows = std.mem.splitScalar(u8, text, '\n');
    while (rows.next()) |row| {
        const bar = std.mem.indexOf(u8, row, "│┆│") orelse continue;
        try testing.expect(std.mem.indexOfAny(u8, row[bar..], "abcdefghijklmnopqrstuvwxyz") == null);
    }
}

test "a note left of the first participant shifts the drawing instead of covering its lifeline" {
    const source =
        \\sequenceDiagram
        \\    participant A as Alpha
        \\    participant B as Beta
        \\    Note left of A: a long note text here
        \\    A->>B: a very long message that needs to wrap somewhere along the way
    ;
    const text = try drawn(source, 58);
    defer testing.allocator.free(text);
    try expectWithin(text, 58);
    try expectLifelinesAligned(text);
    var rows = std.mem.splitScalar(u8, text, '\n');
    while (rows.next()) |row| {
        const open = std.mem.indexOf(u8, row, "│ a long") orelse continue;
        const close = std.mem.lastIndexOf(u8, row, "│").?;
        try testing.expect(std.mem.indexOf(u8, row[open..close], "┆") == null);
        try testing.expect(std.mem.indexOf(u8, row[close..], "┆") != null);
    }
}

test "a wrapped label never breaks inside a word" {
    const allocator = testing.allocator;
    var diagram = try parse.parse(allocator, wide_self_message);
    defer diagram.deinit();
    var max_width: u32 = 40;
    while (max_width < 100) : (max_width += 1) {
        const text = switch (try render.render(allocator, wide_self_message, max_width)) {
            .drawn => |text| text,
            .too_wide => |need| {
                try testing.expect(need > max_width);
                continue;
            },
        };
        defer allocator.free(text);
        for (diagram.elements.items) |element| {
            var words = std.mem.tokenizeScalar(u8, element.message.text, ' ');
            while (words.next()) |word| {
                var rows = std.mem.splitScalar(u8, text, '\n');
                var whole = false;
                while (rows.next()) |row| whole = whole or std.mem.indexOf(u8, row, word) != null;
                try testing.expect(whole);
            }
        }
    }
}

test "a word wider than the gap refuses the wrap rung" {
    const source =
        \\sequenceDiagram
        \\    participant A as Alpha
        \\    participant B as Bravo
        \\    A->>B: an extraordinarily-hyphenated-identifier here
    ;
    const allocator = testing.allocator;
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();
    const refused = try tb_wrap.render(allocator, &diagram, .{ .participant = 2, .padding = 2, .wrap = true }, 200);
    try testing.expect(refused.too_wide > 200);
}

test "a wide-character label wraps between characters where a word of its width would not" {
    const source =
        \\sequenceDiagram
        \\    participant A as Alpha
        \\    participant B as Bravo
        \\    A->>B: 日本語のラベルです
    ;
    const allocator = testing.allocator;
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();
    const text = (try tb_wrap.render(allocator, &diagram, .{ .participant = 2, .padding = 2, .wrap = true }, 200)).drawn;
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "日本語のラベルです") == null);
    try testing.expect(std.mem.indexOf(u8, text, "日本語") != null);
    try expectLifelinesAligned(text);
}

test "tabs, multi-scalar graphemes and a lone mark or modifier after a break draw whole, lifelines aligned" {
    const label = "cafe\u{0301} \u{304B}\u{3099} \u{2764}\u{FE0F} 🇯🇵 👩‍💻 ok";
    const head = "sequenceDiagram\n    participant A\n    participant B\n    participant C\n";
    const cases = [_]struct { source: []const u8, words: []const u8 = "", present: []const []const u8 = &.{}, once: []const []const u8 = &.{} }{
        .{ .source = head ++ "    A->>C: x ab\tcd ef\n    B->>B: z\ty\n", .present = &.{ "x ab    cd ef", "z   y" } },
        .{
            .source = "sequenceDiagram\n    participant A as Cafe\u{0301}\n    participant B\n    participant C\n" ++
                "    A->>A: " ++ label ++ "\n    A->>C: " ++ label ++ "\n    B->>C: hi<br>\u{0301}x\n",
            .words = label,
            .once = &.{ "Cafe\u{0301}", " \u{0301}x" },
        },
        .{ .source = head ++ "    A->>A: 🏽 opens a self message\n    A->>C: 🏿 opens a label\n    B->>C: hi<br>🏽x\n", .once = &.{ " 🏽x", " 🏿 opens" } },
    };
    const allocator = testing.allocator;
    for (cases) |case| {
        var diagram = try parse.parse(allocator, case.source);
        defer diagram.deinit();
        const text = (try tb_wrap.render(allocator, &diagram, .{ .participant = 2, .padding = 2, .wrap = true }, 200)).drawn;
        defer allocator.free(text);
        try testing.expect(std.mem.indexOfScalar(u8, text, '\t') == null);
        for (case.present) |needle| try testing.expect(std.mem.indexOf(u8, text, needle) != null);
        for (case.once) |needle| try testing.expectEqual(@as(usize, 1), count(text, needle));
        try expectWords(text, case.words);
        try expectLifelinesAligned(text);
    }
}
