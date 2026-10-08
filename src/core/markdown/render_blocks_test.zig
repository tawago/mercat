//! Rendering of block content nested in list items, HTML blocks, block
//! quote layout, and the per-block raw-source fallback.
const std = @import("std");
const markdown = @import("parser.zig");
const render_model = @import("render.zig");
const decor_mod = @import("render/decor.zig");
const resolve = @import("../theme/resolve.zig");
const presets = @import("../theme/presets.zig");
const input_test = @import("render_input_test.zig");

const testing = std.testing;
const Options = render_model.Options;
const SpanStyle = render_model.SpanStyle;

const kitchen_sink = @embedFile("kitchen_sink_md");

/// Rendered text, one entry per line, right-trimmed. Fails the test if any
/// block fell back to raw source.
const Text = struct {
    lines: [][]u8,
    rendered: render_model.Rendered,

    fn deinit(self: Text) void {
        for (self.lines) |line| testing.allocator.free(line);
        testing.allocator.free(self.lines);
        self.rendered.deinit(testing.allocator);
    }

    fn find(self: Text, needle: []const u8) ?usize {
        for (self.lines, 0..) |line, index| {
            if (std.mem.indexOf(u8, line, needle) != null) return index;
        }
        return null;
    }
};

fn renderText(source: []const u8, options: Options) !Text {
    const allocator = testing.allocator;
    var document = try markdown.parse(allocator, source);
    defer document.deinit(allocator);
    var fallbacks: usize = 0;
    var opts = options;
    opts.fallback_count = &fallbacks;
    const rendered = try render_model.renderDocument(allocator, document, opts);
    errdefer rendered.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), fallbacks);

    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    for (rendered.lines) |line| {
        const joined = try line.joinedText(allocator);
        defer allocator.free(joined);
        try lines.append(allocator, try allocator.dupe(u8, std.mem.trimRight(u8, joined, " ")));
    }
    return .{ .lines = try lines.toOwnedSlice(allocator), .rendered = rendered };
}

fn expectLines(source: []const u8, width: usize, expected: []const []const u8) !void {
    const text = try renderText(source, .{ .width = width });
    defer text.deinit();
    testing.expectEqual(expected.len, text.lines.len) catch |err| {
        for (text.lines) |line| std.debug.print("|{s}|\n", .{line});
        return err;
    };
    for (expected, text.lines) |want, got| try testing.expectEqualStrings(want, got);
}

test "fenced code in a list item renders as code under the item text" {
    const text = try renderText("1. Install:\n\n   ```sh\n   make\n   ```\n", .{ .width = 40 });
    defer text.deinit();
    try testing.expectEqualStrings("  1. Install:", text.lines[0]);
    try testing.expectEqualStrings("     ```sh", text.lines[1]);
    try testing.expectEqualStrings("      make", text.lines[2]);
    try testing.expectEqualStrings("     ```", text.lines[text.lines.len - 1]);
    const code_line = text.rendered.lines[2];
    try testing.expectEqual(SpanStyle.code_block, code_line.spans[code_line.spans.len - 1].style);
}

test "list item children keep source order: quote, paragraph, code" {
    const text = try renderText("- item\n\n  > quote\n\n  second para\n\n  ```\n  x\n  ```\n- next\n", .{ .width = 40 });
    defer text.deinit();
    const quote = text.find("quote").?;
    const para = text.find("second para").?;
    const code = text.find(" x").?;
    const next = text.find("next").?;
    try testing.expect(quote < para and para < code and code < next);
    try testing.expectEqualStrings("    second para", text.lines[para]);
    try testing.expect(std.mem.startsWith(u8, text.lines[quote], "    \u{258E} quote"));
    // A quote ends like any block: no stray blank line before the paragraph.
    try testing.expectEqual(quote + 1, para);
}

test "tables, HTML and tasks nested in list items render instead of crashing" {
    const source =
        \\1. Configure:
        \\
        \\   | key | value |
        \\   | --- | ----- |
        \\   | w   | 80    |
        \\
        \\   <details>
        \\   <summary>More</summary>
        \\   </details>
        \\
        \\- [ ] task
        \\
        \\  ```
        \\  code
        \\  ```
        \\- parent
        \\  - [x] nested task
    ;
    const text = try renderText(source, .{ .width = 40 });
    defer text.deinit();
    try testing.expect(text.find("key") != null);
    try testing.expect(std.mem.startsWith(u8, text.lines[text.find("More").?], "     \u{25B8} More"));
    try testing.expectEqualStrings("       code", text.lines[text.find("code").?]);
    // A nested task item steps in like a nested bullet would.
    try testing.expect(std.mem.startsWith(u8, text.lines[text.find("nested task").?], "    "));
}

test "HTML blocks render as readable text" {
    try expectLines("<details>\n<summary>More</summary>\n\nBody text\n</details>\n", 40, &.{
        "  \u{25B8} More",
        "",
        "  Body text",
    });
    try expectLines("<!-- only a comment -->\n\n# Title\n", 40, &.{"  # Title"});
}

test "block quotes: one space after the bar and one blank line after" {
    try expectLines("> quote\n> more\n\nafter\n", 40, &.{
        "  \u{258E} quote",
        "  \u{258E} more",
        "",
        "  after",
    });
}

test "a block that cannot be rendered falls back to its raw source" {
    const allocator = testing.allocator;
    // The parser never produces such text (it sanitizes), so plant a control
    // byte in the parsed paragraph and in its recorded source. The fallback
    // drops invisible format characters and shows controls like any text.
    var document = try markdown.parse(allocator, "# Title\n\nbad X so\u{AD}ft\u{200B} \u{200E}bidi\u{202E} \u{FEFF}*text*\x1b[2J\n\nafter\n");
    defer document.deinit(allocator);
    const buffer: []u8 = @constCast(document.source_buffer.?);
    buffer[std.mem.indexOfScalar(u8, buffer, 'X').?] = 0x01;
    const first: []u8 = @constCast(document.blocks[1].paragraph.content[0].text);
    first[std.mem.indexOfScalar(u8, first, 'X').?] = 0x01;
    var fallbacks: usize = 0;
    const rendered = try render_model.renderDocument(allocator, document, .{ .width = 40, .fallback_count = &fallbacks });
    defer rendered.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), fallbacks);
    try testing.expectEqual(@as(usize, 5), rendered.lines.len);
    const raw = try rendered.lines[2].joinedText(allocator);
    defer allocator.free(raw);
    try testing.expectEqualStrings("  bad \u{FFFD} soft bidi *text*\u{FFFD}[2J", raw);
    try testing.expectEqual(SpanStyle.muted, rendered.lines[2].spans[rendered.lines[2].spans.len - 1].style);
    const after = try rendered.lines[4].joinedText(allocator);
    defer allocator.free(after);
    try testing.expectEqualStrings("  after", after);
}

test "kitchen-sink fixture and hostile input render in every built-in style without fallback" {
    const hostile =
        "---\ntitle: T\xFF\x1b\n---\n\n# H\u{00ad}\xFF\n\n- a\x07 [l](u\x1b) `c\x1b`\n\n" ++
        "| \x1b | \xFF |\n|---|---|\n| \u{202e} | &#27; |\n\n```\n\x1b[2J\xFF\n```\n\n> q\u{200b}\x9b\n";
    for (presets.ALL) |preset| {
        const theme = resolve.builtinResolved(testing.allocator, preset.name);
        for ([_]usize{ 80, 40, 24 }) |width| {
            const text = try renderText(kitchen_sink, .{ .width = width, .decor = &theme.decor });
            defer text.deinit();
            try testing.expect(text.find("make install") != null);
            try testing.expect(text.find("Body text inside") != null);
            try testing.expect(text.find("**") == null);
            try testing.expect(text.find("<details>") == null);

            const bad = try renderText(hostile, .{ .width = width, .decor = &theme.decor });
            defer bad.deinit();
            for (bad.rendered.lines) |line| for (line.spans) |span| {
                try input_test.expectDisplaySafe(span.text);
                if (span.url) |url| try input_test.expectDisplaySafe(url);
            };
        }
    }
}
