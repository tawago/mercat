//! Inline HTML that spans lines, and the raw-source fallback: a paragraph
//! is never lost to an error or a placeholder, whatever the input.
const std = @import("std");
const markdown = @import("parser.zig");
const render_model = @import("render.zig");
const encoding = @import("../encoding.zig");

const testing = std.testing;

const Out = struct {
    text: []u8,
    fallbacks: usize,

    fn deinit(self: Out) void {
        testing.allocator.free(self.text);
    }

    fn has(self: Out, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.text, needle) != null;
    }
};

fn renderDoc(document: markdown.Document, width: usize) !Out {
    const allocator = testing.allocator;
    var fallbacks: usize = 0;
    const rendered = try render_model.renderDocument(allocator, document, .{ .width = width, .fallback_count = &fallbacks });
    defer rendered.deinit(allocator);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (rendered.lines) |line| {
        for (line.spans) |span| try expectDisplaySafe(span.text);
        const joined = try line.joinedText(allocator);
        defer allocator.free(joined);
        try text.appendSlice(allocator, std.mem.trimRight(u8, joined, " "));
        try text.append(allocator, '\n');
    }
    return .{ .text = try text.toOwnedSlice(allocator), .fallbacks = fallbacks };
}

fn renderSource(source: []const u8, width: usize) !Out {
    var document = try markdown.parse(testing.allocator, source);
    defer document.deinit(testing.allocator);
    return renderDoc(document, width);
}

fn expectDisplaySafe(text: []const u8) !void {
    try testing.expect(std.unicode.utf8ValidateSlice(text));
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (view.nextCodepoint()) |cp| {
        try testing.expect(!((cp < 0x20 and cp != '\t') or (cp >= 0x7f and cp < 0xa0)));
        try testing.expect(cp != 0xad and cp != 0x200b and cp != 0x200e and cp != 0x202e and cp != 0xfeff);
    }
}

test "inline HTML spanning lines renders as a normal paragraph" {
    const cases = [_]struct { input: []const u8, want: []const []const u8, lacks: []const []const u8 = &.{} }{
        .{ .input = "one <span\nclass=x>two</span> three\n", .want = &.{ "one", "<span class=x>", "two", "three" } },
        .{ .input = "one <span\r\nclass=x>two</span>\n", .want = &.{"<span class=x>two</span>"} },
        .{ .input = "c <!-- a\nb --> d\n", .want = &.{ "c", "d" }, .lacks = &.{ "<!--", "-->", "a\n" } },
        .{ .input = "c <!-- one line --> d\n", .want = &.{"c  d"}, .lacks = &.{"one line"} },
        .{ .input = "l <a\nhref=\"u\">x</a> e\n", .want = &.{ "<a href=\"u\">", "x", "e" } },
        .{ .input = "x <img\nsrc=a\nalt=b> y\n", .want = &.{"<img src=a alt=b>"} },
        .{ .input = "> quote <span\n> class=q>in</span>\n", .want = &.{"in</span>"} },
        .{ .input = "- item <b\n  class=z>bold</b>\n", .want = &.{"bold</b>"} },
    };
    for (cases) |case| {
        const out = try renderSource(case.input, 60);
        defer out.deinit();
        errdefer std.debug.print("input: {s}\noutput:\n{s}\n", .{ case.input, out.text });
        try testing.expectEqual(@as(usize, 0), out.fallbacks);
        for (case.want) |needle| try testing.expect(out.has(needle));
        for (case.lacks) |needle| try testing.expect(!out.has(needle));
    }
}

test "HTML blocks with tags spanning lines render without the fallback" {
    const cases = [_]struct { input: []const u8, want: []const []const u8, lacks: []const []const u8 = &.{} }{
        .{ .input = "<div>\n<sup\nclass=x>1</sup>\n</div>\n", .want = &.{"<sup class=x>1</sup>"} },
        .{ .input = "<div>\n<my-widget\r\n\tdata-x=\"1\"></my-widget>\n</div>\n", .want = &.{"<my-widget  data-x=\"1\">"} },
        .{ .input = "<p>\n<a href='\n'>x</a>\n</p>\n", .want = &.{"x"}, .lacks = &.{"<"} },
        .{ .input = "<p>\n<img src='a\nb.png' alt='two\nlines'>\n</p>\n", .want = &.{"two lines"} },
        .{ .input = "<d>\n<f\n>\n", .want = &.{"<f >"} },
        .{ .input = "<![CDATA[x>\n<a\nhref='\n'>\n", .want = &.{"CDATA"} },
    };
    for (cases) |case| {
        const out = try renderSource(case.input, 60);
        defer out.deinit();
        errdefer std.debug.print("input: {s}\noutput:\n{s}\n", .{ case.input, out.text });
        try testing.expectEqual(@as(usize, 0), out.fallbacks);
        for (case.want) |needle| try testing.expect(out.has(needle));
        for (case.lacks) |needle| try testing.expect(!out.has(needle));
    }
}

test "inline <br> breaks the line" {
    for ([_][]const u8{ "a<br>b\n", "a<br/>b\n", "a<BR />b\n", "a<br\nclass=x>b\n" }) |input| {
        const out = try renderSource(input, 60);
        defer out.deinit();
        try testing.expectEqual(@as(usize, 0), out.fallbacks);
        try testing.expectEqualStrings("  a\n  b\n", out.text);
    }
    // Not a break: a tag that merely starts with "br".
    const out = try renderSource("a<bread>b\n", 60);
    defer out.deinit();
    try testing.expect(out.has("a<bread>b"));
}

test "raw-source fallback drops invisible characters like all document text" {
    const allocator = testing.allocator;
    var document = try markdown.parse(allocator, "keep X so\u{AD}ft\u{200B} \u{200E}bidi\u{202E} \u{FEFF}end\x1b[2J\n");
    defer document.deinit(allocator);
    // Force the fallback: plant a control byte the block renderer rejects.
    const first: []u8 = @constCast(document.blocks[0].paragraph.content[0].text);
    first[std.mem.indexOfScalar(u8, first, 'X').?] = 0x01;
    const out = try renderDoc(document, 40);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), out.fallbacks);
    try testing.expectEqualStrings("  keep X soft bidi end\u{FFFD}[2J\n", out.text);
}

test "fallback sanitize follows unicode.sanitize" {
    const out = try render_model.sanitize(testing.allocator, "a\tb\x01c\xffd\u{0085}é\u{AD}\u{200B}\u{2066}x\u{FE0F}\r\xe2\x82");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\tb\u{FFFD}c\u{FFFD}d\u{FFFD}éx\u{FE0F} \u{FFFD}\u{FFFD}", out);
}

const fragments = [_][]const u8{
    "<span\nclass=x>",               "</span>",                "<!-- a\nb -->",      "<!--",             "-->",
    "<a\nhref=\"u\">",               "</a>",                   "<br>",               "<br\n/>",          "<sup>",
    "</sup>",                        "<mark>",                 "<details>\n",        "<fnref id=\"1\">", "</fnref>",
    "**",                            "*",                      "_",                  "`",                "```\n",
    "```mermaid\ngraph TD\nA-->B\n", "# ",                     "- ",                 "1. ",              "- [ ] ",
    "> ",                            "| a | b |\n|---|---|\n", "| x |",              "---\n",            "~~",
    "[x](y)",                        "![i](u)",                "[^1]",               "[^1]: n\n",        "    code",
    "&#27;",                         "&amp;",                  "&#x202E;",           "\u{AD}",           "\u{200B}",
    "\u{202E}",                      "\u{2066}",               "\u{FEFF}",           "\u{2028}",         "\u{E0067}",
    "\u{1F3F4}",                     "e\u{0301}",              "\u{1F44D}\u{1F3FD}", "\u{200D}",         "\u{FE0F}",
    "\t",                            "\r\n",                   "\r",                 "\n",               "\n\n",
    "\x1b[2J",                       "\x00",                   "\x7f",               "\xc2\x85",         "\xff",
    "\xe2\x82",                      "<",                      ">",                  "\\",               "word ",
    "\u{4E2D}\u{6587}",              "<pre>\n",                "</pre>",             "<",                "\\\n",
};

fn randomDocument(random: std.Random, buf: *std.ArrayList(u8)) !void {
    buf.clearRetainingCapacity();
    const count = random.uintLessThan(usize, 24);
    for (0..count) |_| {
        if (random.uintLessThan(u8, 5) == 0) {
            const len = random.uintLessThan(usize, 12);
            for (0..len) |_| try buf.append(testing.allocator, random.int(u8));
        } else {
            try buf.appendSlice(testing.allocator, fragments[random.uintLessThan(usize, fragments.len)]);
        }
    }
}

test "property: random markdown-ish input always renders, never as a placeholder" {
    var prng = std.Random.DefaultPrng.init(0x6d657263);
    const random = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..2500) |iteration| {
        try randomDocument(random, &buf);
        const width: usize = if (iteration % 3 == 0) 20 else 60;
        // As the CLI sees it (decoded), and raw bytes straight to the parser.
        const decoded = try encoding.decode(testing.allocator, buf.items);
        defer decoded.deinit(testing.allocator);
        for ([_][]const u8{ decoded.text, buf.items }) |input| {
            const out = renderSource(input, width) catch |err| {
                std.debug.print("iteration {d}: {s} for input {any}\n", .{ iteration, @errorName(err), input });
                return err;
            };
            defer out.deinit();
            try testing.expect(!out.has("could not be rendered"));
            if (out.fallbacks != 0) {
                std.debug.print("iteration {d}: {d} fallback(s) for input {any}\n", .{ iteration, out.fallbacks, input });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "property: the raw-source fallback shows any source and never fails" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x66616c6c);
    const random = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (0..2500) |_| {
        try randomDocument(random, &buf);
        // A paragraph the renderer rejects (control byte), paired with an
        // arbitrary recorded source: the fallback must cope with any bytes.
        const content = try allocator.alloc(markdown.Inline, 1);
        content[0] = .{ .text = try allocator.dupe(u8, "bad \x01") };
        const blocks = try allocator.alloc(markdown.Block, 1);
        blocks[0] = .{ .paragraph = .{ .content = content } };
        const sources = try allocator.alloc([]const u8, 1);
        sources[0] = buf.items;
        const document: markdown.Document = .{ .blocks = blocks, .sources = sources };
        defer {
            document.deinit(allocator);
            allocator.free(sources);
        }
        const out = try renderDoc(document, 40);
        defer out.deinit();
        try testing.expectEqual(@as(usize, 1), out.fallbacks);
        try testing.expect(!out.has("could not be rendered"));
        // Every printable ASCII character of the source survives.
        for (buf.items) |byte| {
            if (byte > 0x20 and byte < 0x7f) try testing.expect(std.mem.indexOfScalar(u8, out.text, byte) != null);
        }
    }
}

test "fallback without a recorded source shows the block's own text" {
    const allocator = testing.allocator;
    const content = try allocator.alloc(markdown.Inline, 1);
    content[0] = .{ .text = try allocator.dupe(u8, "esc \x1b kept") };
    const blocks = try allocator.alloc(markdown.Block, 1);
    blocks[0] = .{ .paragraph = .{ .content = content } };
    const document: markdown.Document = .{ .blocks = blocks };
    defer document.deinit(allocator);
    const out = try renderDoc(document, 40);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), out.fallbacks);
    try testing.expectEqualStrings("  esc \u{FFFD} kept\n", out.text);
}
