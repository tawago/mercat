//! Hostile input: invalid UTF-8 (the files in tests/repro/invalid-utf8),
//! invisible and control characters, and terminal escape injection. Every
//! case must render as normal markdown with no block falling back to raw
//! source, lose no visible text, and never emit a control character.
const std = @import("std");
const markdown = @import("parser.zig");
const render_model = @import("render.zig");
const encoding = @import("../encoding.zig");
const resolve = @import("../theme/resolve.zig");
const presets = @import("../theme/presets.zig");

const testing = std.testing;
const Options = render_model.Options;

const Rendered = struct {
    text: []u8,
    rendered: render_model.Rendered,
    fallbacks: usize,

    fn deinit(self: Rendered) void {
        testing.allocator.free(self.text);
        self.rendered.deinit(testing.allocator);
    }

    fn has(self: Rendered, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.text, needle) != null;
    }
};

/// Decodes `input` the way the CLI does, renders it, and joins the lines.
fn render(input: []const u8, options: Options) !Rendered {
    const allocator = testing.allocator;
    const decoded = try encoding.decode(allocator, input);
    defer decoded.deinit(allocator);
    var document = try markdown.parse(allocator, decoded.text);
    defer document.deinit(allocator);
    var fallbacks: usize = 0;
    var opts = options;
    opts.fallback_count = &fallbacks;
    const rendered = try render_model.renderDocument(allocator, document, opts);
    errdefer rendered.deinit(allocator);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (rendered.lines) |line| {
        const joined = try line.joinedText(allocator);
        defer allocator.free(joined);
        try text.appendSlice(allocator, std.mem.trimRight(u8, joined, " "));
        try text.append(allocator, '\n');
    }
    return .{ .text = try text.toOwnedSlice(allocator), .rendered = rendered, .fallbacks = fallbacks };
}

/// Renders and checks the invariants every case shares.
fn renderClean(input: []const u8) !Rendered {
    const out = try render(input, .{ .width = 60 });
    errdefer out.deinit();
    try testing.expectEqual(@as(usize, 0), out.fallbacks);
    try expectNoControls(out);
    return out;
}

fn expectNoControls(out: Rendered) !void {
    for (out.rendered.lines) |line| for (line.spans) |span| {
        try expectDisplaySafe(span.text);
        if (span.url) |url| try expectDisplaySafe(url);
    };
}

fn expectDisplaySafe(text: []const u8) !void {
    try testing.expect(std.unicode.utf8ValidateSlice(text));
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (view.nextCodepoint()) |cp| {
        const control = (cp < 0x20 and cp != '\t') or (cp >= 0x7f and cp < 0xa0);
        if (control) {
            std.debug.print("control U+{X:0>4} in {s}\n", .{ cp, text });
            return error.TestUnexpectedResult;
        }
        try testing.expect(cp != 0xad and cp != 0x200b and cp != 0x202e);
    }
}

test "invalid UTF-8 repro files render as markdown" {
    const cases = [_]struct { input: []const u8, want: []const []const u8 }{
        .{ .input = "ok \xFF bye\n", .want = &.{"ok \u{FFFD} bye"} },
        .{ .input = "# R\xE9sum\xE9\n\nA na\xEFve caf\xE9 in Latin-1.\n", .want = &.{ "# R\u{FFFD}sum\u{FFFD}", "A na\u{FFFD}ve caf\u{FFFD} in Latin-1." } },
        .{ .input = "He said \x93hello\x94 \x96 then left.\n", .want = &.{"He said \u{FFFD}hello\u{FFFD} \u{FFFD} then left."} },
        .{ .input = "Price: 5 \xE2\x82\nnext line\n", .want = &.{ "Price: 5 \u{FFFD}", "next line" } },
        .{ .input = "slash: \xC0\xAF end\n", .want = &.{"slash: \u{FFFD}\u{FFFD} end"} },
        .{ .input = "surrogate \xED\xA0\x80 here\n", .want = &.{"surrogate \u{FFFD}\u{FFFD}\u{FFFD} here"} },
        .{ .input = "# Ti\xFFtle\n\nbody\n", .want = &.{ "# Ti\u{FFFD}tle", "body" } },
        .{ .input = "```\nbad \xFF byte in code\n```\n", .want = &.{"bad \u{FFFD} byte in code"} },
        .{ .input = "[link](http://example.com/\xFF) and text\n", .want = &.{"link <http://example.com/\u{FFFD}> and text"} },
        .{ .input = "---\ntitle: T\xFFt\n---\n\n# Heading\n", .want = &.{ "T\u{FFFD}t", "# Heading" } },
        .{ .input = "- one\n- tw\xFF\n- three\n", .want = &.{ "one", "tw\u{FFFD}", "three" } },
        .{ .input = "line 1 \xFF\n\nline 2 \xFF\n\nline 3 \xFF\n\nline 4 \xFF\n\nline 5 \xFF\n", .want = &.{ "line 1 \u{FFFD}", "line 5 \u{FFFD}" } },
        .{ .input = "\xFF\xFE#\x00 \x00H\x00i\x00\n\x00\n\x00U\x00T\x00F\x00-\x001\x006\x00 \x00t\x00e\x00x\x00t\x00\n\x00", .want = &.{ "# Hi", "UTF-16 text" } },
    };
    for (cases) |case| {
        const out = try renderClean(case.input);
        defer out.deinit();
        for (case.want) |needle| {
            if (!out.has(needle)) {
                std.debug.print("missing '{s}' in:\n{s}\n", .{ needle, out.text });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "invalid byte in a table cell keeps the row in its table" {
    const out = try renderClean("| a | b |\n|---|---|\n| \xFF | ok |\n");
    defer out.deinit();
    try testing.expect(!out.has("|"));
    var lines = std.mem.splitScalar(u8, out.text, '\n');
    var rows: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\u{2502}") != null) rows += 1;
    }
    try testing.expectEqual(@as(usize, 2), rows);
    try testing.expect(out.has("\u{FFFD} \u{2502} ok"));
}

test "soft hyphen and invisible format characters are dropped, text kept" {
    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "a\xc2\xadb\n", .want = "ab" },
        .{ .input = "zero\u{200b}width space\n", .want = "zerowidth space" },
        .{ .input = "bidi \u{202e}abc\u{202c} \u{2066}iso\u{2069} \u{200f}mark\n", .want = "bidi abc iso mark" },
        .{ .input = "\u{feff}bom \u{2060}joiner\n", .want = "bom joiner" },
        .{ .input = "entity a&shy;b and &#x200B;c\n", .want = "entity ab and c" },
        .{ .input = "# head\u{00ad}ing\n", .want = "# heading" },
    };
    for (cases) |case| {
        const out = try renderClean(case.input);
        defer out.deinit();
        if (!out.has(case.want)) {
            std.debug.print("missing '{s}' in:\n{s}\n", .{ case.want, out.text });
            return error.TestUnexpectedResult;
        }
    }
}

test "controls render as visible U+FFFD and never reach the output raw" {
    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "bel\x07 here\n", .want = "bel\u{FFFD} here" },
        .{ .input = "text \x1b[2J cleared\n", .want = "text \u{FFFD}[2J cleared" },
        .{ .input = "c1 \xc2\x9b2J and \xc2\x85 nel\n", .want = "c1 \u{FFFD}2J and \u{FFFD} nel" },
        .{ .input = "```\ncode \x1b[2J\x1b]0;title\x07\n```\n", .want = "code \u{FFFD}[2J\u{FFFD}]0;title\u{FFFD}" },
        .{ .input = "`inline \x1b[31m`\n", .want = "inline \u{FFFD}[31m" },
        .{ .input = "[x](http://e.com/\x1b[2J)\n", .want = "x <http://e.com/\u{FFFD}[2J>" },
        .{ .input = "[x](<http://e.com/\x1b]8;;evil\x07>)\n", .want = "x <http://e.com/\u{FFFD}]8;;evil\u{FFFD}>" },
        .{ .input = "| a | b |\n|---|---|\n| \x1b[2J | ok |\n", .want = "\u{FFFD}[2J \u{2502} ok" },
        .{ .input = "entity &#27;[2J and &#7;\n", .want = "entity \u{FFFD}[2J and \u{FFFD}" },
        .{ .input = "---\ntitle: a\x1b[2Jb\n---\n\nbody\n", .want = "a\u{FFFD}[2Jb" },
        .{ .input = "<div>\nhtml \x1b[2J block\n</div>\n", .want = "html \u{FFFD}[2J block" },
        .{ .input = "line\u{2028}separator\n", .want = "line separator" },
    };
    for (cases) |case| {
        const out = try renderClean(case.input);
        defer out.deinit();
        if (!out.has(case.want)) {
            std.debug.print("missing '{s}' in:\n{s}\n", .{ case.want, out.text });
            return error.TestUnexpectedResult;
        }
        try testing.expect(std.mem.indexOfScalar(u8, out.text, 0x1b) == null);
    }
}

test "hostile input renders in every built-in theme at narrow widths" {
    const input =
        "---\ntitle: T\xFF\x1b\n---\n\n# H\u{00ad}\xFF\n\n- a\x07 [l](u\x1b) `c\x1b`\n\n" ++
        "| \x1b | \xFF |\n|---|---|\n| \u{202e} | &#27; |\n\n```\n\x1b[2J\xFF\n```\n\n> q\u{200b}\x9b\n";
    for (presets.ALL) |preset| {
        const theme = resolve.builtinResolved(testing.allocator, preset.name);
        for ([_]usize{ 80, 40, 24 }) |width| {
            const out = try render(input, .{ .width = width, .decor = &theme.decor });
            defer out.deinit();
            try testing.expectEqual(@as(usize, 0), out.fallbacks);
            try expectNoControls(out);
        }
    }
}

test "links with an empty URL show no angle brackets" {
    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "a [x]() b\n", .want = "a x b\n" },
        .{ .input = "a []() b\n", .want = "a  b\n" },
        .{ .input = "a [](u) b\n", .want = "a <u> b\n" },
        .{ .input = "<div>\n<a href=\"\">x</a> and <a href=\"\"></a> and <a href=\"u\">y</a> end\n</div>\n", .want = "x and and y <u> end\n" },
        .{ .input = "<div>\na <a href=\"u\"></a> b\n</div>\n", .want = "a <u> b\n" },
        .{ .input = "<div>\n<a href=\"\"></a>\n</div>\n\nafter\n", .want = "after\n" },
    };
    for (cases) |case| {
        const out = try renderClean(case.input);
        defer out.deinit();
        const trimmed = std.mem.trimLeft(u8, out.text, " \n");
        testing.expectEqualStrings(case.want, trimmed) catch |err| {
            std.debug.print("input: {s}\n", .{case.input});
            return err;
        };
        try testing.expect(!out.has("<>"));
    }
}
