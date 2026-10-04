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

test "a wide diagram draws on a wrap rung, the same at either budget" {
    const narrow = try drawn(wide_self_message, 78);
    defer testing.allocator.free(narrow);
    const wide = try drawn(wide_self_message, 98);
    defer testing.allocator.free(wide);
    try testing.expectEqualStrings(narrow, wide);
    try expectWithin(narrow, 78);
}

test "every word of every message label is drawn" {
    const allocator = testing.allocator;
    var diagram = try parse.parse(allocator, wide_self_message);
    defer diagram.deinit();
    const text = try drawn(wide_self_message, 78);
    defer allocator.free(text);
    for (diagram.elements.items) |element| {
        var words = std.mem.tokenizeScalar(u8, element.message.text, ' ');
        while (words.next()) |word| try testing.expect(std.mem.indexOf(u8, text, word) != null);
    }
}

test "every arrowhead and box corner survives the wrap" {
    const text = try drawn(wide_self_message, 78);
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 7), count(text, "►") + count(text, "◄"));
    for ([_][]const u8{ "╭", "╮", "╰", "╯" }) |corner| try testing.expectEqual(@as(usize, 4), count(text, corner));
    for ([_][]const u8{ "Sender", "Ingest", "DataStore", "Worker" }) |name| try testing.expect(std.mem.indexOf(u8, text, name) != null);
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

const CountingPainter = struct {
    inner: render.Painter,
    wrap_tries: *u32,

    pub fn draw(self: CountingPainter, spacing: fit.Spacing, max_width: u32) !ladder.Fit {
        if (spacing.wrap) self.wrap_tries.* += 1;
        return self.inner.draw(spacing, max_width);
    }
};

test "a diagram that fits unwrapped draws as before and never tries a wrap rung" {
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
    const allocator = testing.allocator;
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();
    for ([_]u32{ 30, 78, 160 }) |max_width| {
        var wrap_tries: u32 = 0;
        const painter = CountingPainter{ .inner = .{ .allocator = allocator, .diagram = &diagram }, .wrap_tries = &wrap_tries };
        const fitted = try ladder.firstFit(fit.ladder(diagram.direction, diagram.direction_explicit), painter, max_width);
        defer allocator.free(fitted.drawn);
        try testing.expectEqualStrings(expected, fitted.drawn);
        try testing.expectEqual(@as(u32, 0), wrap_tries);
    }
}

test "participant names are not wrapped: a pair wider than the budget stays undrawn" {
    const fitted = try render.render(testing.allocator, "sequenceDiagram\nAlice->>Bob: a very long message text here", 18);
    try testing.expectEqual(ladder.Fit{ .too_wide = 23 }, fitted);
}
