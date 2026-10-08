const std = @import("std");
const markdown = @import("parser.zig");
const decor_mod = @import("render/decor.zig");
const render_model = @import("render.zig");

const renderDocument = render_model.renderDocument;
const SpanStyle = render_model.SpanStyle;
const Line = render_model.Line;
const Span = render_model.Span;

const resolve = @import("../theme/resolve.zig");

test "heading underline_row: default glyph renders a full-width rule row in heading style" {
    const allocator = std.testing.allocator;
    var decor = decor_mod.Decor{};
    decor.slots[@intFromEnum(decor_mod.Slot.heading1)] = .{ .prefix = "# ", .underline_row = true };
    var document = try markdown.parse(allocator, "# Title");
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 12, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), rendered.lines.len);
    const row = rendered.lines[1];
    try std.testing.expectEqual(@as(usize, 1), row.spans.len);
    try std.testing.expectEqual(SpanStyle.heading1, row.spans[0].style);
    try std.testing.expectEqual(@as(usize, 12), row.displayWidth());
    try std.testing.expect(std.mem.indexOf(u8, row.spans[0].text, "\u{2500}") != null);
    for (row.spans[0].text) |ch| try std.testing.expect(ch != ' ');
}

test "heading underline_row: space glyph is a padded blank row carrying the heading bg (full_line_bg)" {
    const allocator = std.testing.allocator;
    var decor = decor_mod.Decor{};
    decor.slots[@intFromEnum(decor_mod.Slot.heading2)] = .{ .prefix = "## ", .underline_row = true, .underline_glyph = " ", .full_line_bg = true };
    var document = try markdown.parse(allocator, "## Head");
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 16, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);

    const row = rendered.lines[1];
    try std.testing.expectEqual(@as(usize, 16), row.displayWidth());
    for (row.spans) |span| {
        try std.testing.expectEqual(SpanStyle.heading2, span.style);
        for (span.text) |ch| try std.testing.expectEqual(@as(u8, ' '), ch);
    }
}

test "heading underline_row: wrapped heading gets exactly one row below the last line" {
    const allocator = std.testing.allocator;
    var decor = decor_mod.Decor{};
    decor.slots[@intFromEnum(decor_mod.Slot.heading1)] = .{ .underline_row = true };
    var document = try markdown.parse(allocator, "# aaaa bbbb cccc dddd");
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 8, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);

    var rule_rows: usize = 0;
    for (rendered.lines) |line| {
        if (line.spans.len == 1 and std.mem.indexOf(u8, line.spans[0].text, "\u{2500}") != null) rule_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), rule_rows);
    const last = rendered.lines[rendered.lines.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, last.spans[0].text, "\u{2500}") != null);
}

test "default (legacy) decor leaves headings unfilled and marked with #, with no extra row" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "# Title");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0 });
    defer rendered.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), rendered.lines.len);
    try std.testing.expect(std.mem.startsWith(u8, rendered.lines[0].spans[0].text, "# "));
    try std.testing.expect(rendered.lines[0].displayWidth() < 40);
}

test "hr width by mode: full fills the content width, fixed is literal but clamps" {
    const allocator = std.testing.allocator;
    const fixed = decor_mod.Decor{ .glyphs = .{ .hr_glyph = "-", .hr_mode = .fixed, .hr_count = 20 } };
    const cases = [_]struct { decor: *const decor_mod.Decor, width: usize, want: usize }{
        .{ .decor = &decor_mod.legacy, .width = 8, .want = 8 },
        .{ .decor = &fixed, .width = 40, .want = 20 },
        .{ .decor = &fixed, .width = 5, .want = 5 },
    };
    var document = try markdown.parse(allocator, "---");
    defer document.deinit(allocator);
    for (cases) |case| {
        var rendered = try renderDocument(allocator, document, .{ .width = case.width, .left_padding = 0, .decor = case.decor });
        defer rendered.deinit(allocator);
        try std.testing.expectEqual(case.want, rendered.lines[0].displayWidth());
    }
}

fn slotDecor(comptime slot: decor_mod.Slot, comptime value: decor_mod.SlotDecor) decor_mod.Decor {
    var d = decor_mod.Decor{};
    d.slots[@intFromEnum(slot)] = value;
    return d;
}

fn findSpan(rendered: anytype, style: ?SpanStyle, needle: []const u8) bool {
    for (rendered.lines) |line| for (line.spans) |span| {
        if (style != null and span.style != style.?) continue;
        if (std.mem.indexOf(u8, span.text, needle) != null) return true;
    };
    return false;
}

test "each decor knob reaches the rendered output" {
    const allocator = std.testing.allocator;
    const Rendered = render_model.Rendered;
    const Check = *const fn (Rendered) anyerror!void;
    const code_src = "```py\nx = 1\n```";
    const cases = [_]struct { name: []const u8, source: []const u8, width: usize = 40, decor: decor_mod.Decor, check: Check }{
        .{ .name = "prefix", .source = "## Heading", .decor = slotDecor(.heading2, .{ .prefix = "\u{2504}\u{2504} " }), .check = struct {
            fn f(r: Rendered) !void {
                try std.testing.expect(std.mem.startsWith(u8, r.lines[0].spans[0].text, "\u{2504}\u{2504} "));
            }
        }.f },
        .{ .name = "blank_wrap", .source = "# One\n\n## Two", .decor = slotDecor(.heading1, .{ .blank_wrap = true }), .check = struct {
            fn f(r: Rendered) !void {
                try std.testing.expectEqual(@as(usize, 0), r.lines[0].spans.len);
                try std.testing.expect(findSpan(r, .heading1, "One"));
            }
        }.f },
        .{ .name = "full_line_bg", .source = "# Title", .width = 20, .decor = slotDecor(.heading1, .{ .prefix = "\u{25C9}  ", .full_line_bg = true }), .check = struct {
            fn f(r: Rendered) !void {
                const line = r.lines[0];
                try std.testing.expect(std.mem.startsWith(u8, line.spans[0].text, "\u{25C9}"));
                const last = line.spans[line.spans.len - 1];
                try std.testing.expectEqual(SpanStyle.heading1, last.style);
                for (last.text) |ch| try std.testing.expectEqual(@as(u8, ' '), ch);
                try std.testing.expectEqual(@as(usize, 20), line.displayWidth());
            }
        }.f },
        .{ .name = "image suffix", .source = "![cat](c.png)", .decor = slotDecor(.image_alt, .{ .suffix = " \u{2192}" }), .check = struct {
            fn f(r: Rendered) !void {
                try std.testing.expect(findSpan(r, .image_alt, " \u{2192}"));
            }
        }.f },
        .{ .name = "link icon", .source = "See [site](https://x).", .decor = slotDecor(.link, .{ .icon = "\u{2192} " }), .check = struct {
            fn f(r: Rendered) !void {
                try std.testing.expect(findSpan(r, .link, "\u{2192}"));
            }
        }.f },
        .{ .name = "inline code chip", .source = "and `co`.", .decor = slotDecor(.code, .{ .prefix = " ", .suffix = " " }), .check = struct {
            fn f(r: Rendered) !void {
                try std.testing.expect(findSpan(r, .code, " co "));
            }
        }.f },
        .{ .name = "code frame rule", .source = code_src, .decor = .{ .glyphs = .{ .code_frame = .{ .kind = .rule, .border_glyph = "\u{2500}", .border_cap = 20 } } }, .check = struct {
            fn f(r: Rendered) !void {
                try std.testing.expect(!findSpan(r, null, "```"));
                var rule_lines: usize = 0;
                for (r.lines) |line| {
                    if (line.spans.len != 1 or std.mem.indexOf(u8, line.spans[0].text, "\u{2500}") == null) continue;
                    rule_lines += 1;
                    try std.testing.expectEqual(@as(usize, 20), line.displayWidth());
                }
                try std.testing.expectEqual(@as(usize, 2), rule_lines);
            }
        }.f },
        .{ .name = "code frame block", .source = code_src, .decor = .{ .glyphs = .{ .code_frame = .{ .kind = .block, .language_label = true, .pad = 2 } } }, .check = struct {
            fn f(r: Rendered) !void {
                try std.testing.expect(findSpan(r, null, " py "));
                try std.testing.expect(!findSpan(r, null, "```"));
            }
        }.f },
        .{ .name = "rounded table", .source = "| A | B |\n| --- | --- |\n| x | y |", .decor = .{ .glyphs = .{ .table_style = .rounded } }, .check = struct {
            fn f(r: Rendered) !void {
                try std.testing.expect(findSpan(r, null, "\u{256D}") and findSpan(r, null, "\u{256F}"));
            }
        }.f },
        .{ .name = "grid table (default)", .source = "| A | B |\n| --- | --- |\n| x | y |", .decor = .{}, .check = struct {
            fn f(r: Rendered) !void {
                try std.testing.expect(!findSpan(r, null, "\u{256D}"));
            }
        }.f },
    };
    for (cases) |case| {
        errdefer std.debug.print("knob: {s}\n", .{case.name});
        var document = try markdown.parse(allocator, case.source);
        defer document.deinit(allocator);
        var rendered = try renderDocument(allocator, document, .{ .width = case.width, .left_padding = 0, .decor = &case.decor });
        defer rendered.deinit(allocator);
        try case.check(rendered);
    }
}

fn firstMarkerSpan(line: Line) Span {
    for (line.spans) |span| {
        for (span.text) |ch| {
            if (ch != ' ') return span;
        }
    }
    return line.spans[0];
}

test "list/task markers carry the marker slot style; item text is list_item" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\- one
        \\
        \\1. two
        \\
        \\- [x] done
        \\
        \\- [ ] todo
    );
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0 });
    defer rendered.deinit(allocator);

    const expected = [_]struct { marker: []const u8, style: SpanStyle, text: []const u8 }{
        .{ .marker = "\u{2022} ", .style = .bullet, .text = "one" },
        .{ .marker = "1. ", .style = .ordered, .text = "two" },
        .{ .marker = "[x] ", .style = .task_on, .text = "done" },
        .{ .marker = "[ ] ", .style = .task_off, .text = "todo" },
    };
    var li: usize = 0;
    for (rendered.lines) |line| {
        if (line.spans.len == 0) continue;
        const e = expected[li];
        const marker = firstMarkerSpan(line);
        try std.testing.expectEqualStrings(e.marker, marker.text);
        try std.testing.expectEqual(e.style, marker.style);
        const text = line.spans[line.spans.len - 1];
        try std.testing.expectEqualStrings(e.text, text.text);
        try std.testing.expectEqual(SpanStyle.list_item, text.style);
        li += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), li);
}

test "list_item falls back to a theme's own body when unset (dracula)" {
    const drac = resolve.builtinResolved(std.testing.allocator, "dracula");
    try std.testing.expectEqual(drac.styles.body.fg, drac.styles.list_item.fg);
}

test {
    _ = @import("render_test2.zig");
    _ = @import("render_blocks_test.zig");
    _ = @import("render_input_test.zig");
    _ = @import("render_fallback_test.zig");
}
