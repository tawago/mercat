//! Tests for render_model.zig (split out to keep the module under the
//! line-count limit). Exercises the public renderDocument surface.
const std = @import("std");
const markdown = @import("parser.zig");
const decor_mod = @import("render/decor.zig");
const render_model = @import("render.zig");

const renderDocument = render_model.renderDocument;
const SpanStyle = render_model.SpanStyle;
const Line = render_model.Line;
const Span = render_model.Span;

const resolve = @import("../theme/resolve.zig");

/// Resolve a built-in preset to its baked `Decor` for render-consumption tests.
/// The returned `Decor`'s slice fields point at static preset literals, so it
/// outlives the (deinit'd) registry.
fn presetDecor(alloc: std.mem.Allocator, name: []const u8) !decor_mod.Decor {
    var reg = resolve.Registry.init(alloc);
    defer reg.deinit();
    var diag = resolve.Diagnostics.init(alloc);
    defer diag.deinit();
    const r = try reg.resolve(name, .default, null, &diag);
    return r.decor;
}

test "markview heading emits its prefix and a full-line bg fill span" {
    const allocator = std.testing.allocator;
    const decor = try presetDecor(allocator, "markview");
    var document = try markdown.parse(allocator, "# Title");
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 20, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);

    const line = rendered.lines[0];
    // The heading prefix is the markview safe mark, not "# ".
    try std.testing.expect(std.mem.startsWith(u8, line.spans[0].text, "\u{25C9}")); // ◉
    // full_line_bg materialized a trailing heading-styled padding span to width.
    const last = line.spans[line.spans.len - 1];
    try std.testing.expectEqual(SpanStyle.heading1, last.style);
    for (last.text) |ch| try std.testing.expectEqual(@as(u8, ' '), ch);
    try std.testing.expectEqual(@as(usize, 20), line.displayWidth());
}

test "heading underline_row: default glyph renders a full-width rule row in heading style" {
    const allocator = std.testing.allocator;
    var decor = decor_mod.Decor{};
    // Enable the underline row on heading1 with the default "─" glyph.
    decor.slotPtr(.heading1).* = .{ .prefix = "# ", .underline_row = true };
    var document = try markdown.parse(allocator, "# Title");
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 12, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);

    // Line 0 is the heading; line 1 is the underline row.
    try std.testing.expectEqual(@as(usize, 2), rendered.lines.len);
    const row = rendered.lines[1];
    try std.testing.expectEqual(@as(usize, 1), row.spans.len);
    try std.testing.expectEqual(SpanStyle.heading1, row.spans[0].style);
    try std.testing.expectEqual(@as(usize, 12), row.displayWidth());
    // Every column is the "─" glyph.
    try std.testing.expect(std.mem.indexOf(u8, row.spans[0].text, "\u{2500}") != null);
    for (row.spans[0].text) |ch| try std.testing.expect(ch != ' ');
}

test "heading underline_row: space glyph is a padded blank row carrying the heading bg (full_line_bg)" {
    const allocator = std.testing.allocator;
    var decor = decor_mod.Decor{};
    decor.slotPtr(.heading2).* = .{ .prefix = "## ", .underline_row = true, .underline_glyph = " ", .full_line_bg = true };
    var document = try markdown.parse(allocator, "## Head");
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 16, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);

    const row = rendered.lines[1];
    // Blank (all spaces) but carrying the heading2 style so the bg tints, and
    // full_line_bg materialized it to the full render width.
    try std.testing.expectEqual(@as(usize, 16), row.displayWidth());
    for (row.spans) |span| {
        try std.testing.expectEqual(SpanStyle.heading2, span.style);
        for (span.text) |ch| try std.testing.expectEqual(@as(u8, ' '), ch);
    }
}

test "heading underline_row: wrapped heading gets exactly one row below the last line" {
    const allocator = std.testing.allocator;
    var decor = decor_mod.Decor{};
    decor.slotPtr(.heading1).* = .{ .underline_row = true };
    var document = try markdown.parse(allocator, "# aaaa bbbb cccc dddd");
    defer document.deinit(allocator);

    // Narrow width forces the heading to wrap over multiple lines.
    var rendered = try renderDocument(allocator, document, .{ .width = 8, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);

    var rule_rows: usize = 0;
    for (rendered.lines) |line| {
        if (line.spans.len == 1 and std.mem.indexOf(u8, line.spans[0].text, "\u{2500}") != null) rule_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), rule_rows);
    // The rule is the LAST line (below the last wrapped heading line).
    const last = rendered.lines[rendered.lines.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, last.spans[0].text, "\u{2500}") != null);
}

test "heading underline_row off by default: no extra row (byte-identical to legacy)" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "# Title");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0 });
    defer rendered.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), rendered.lines.len);
}

test "ansi heading dotted prefix survives into the render" {
    const allocator = std.testing.allocator;
    const decor = try presetDecor(allocator, "ansi");
    var document = try markdown.parse(allocator, "## Heading");
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);

    try std.testing.expect(std.mem.startsWith(u8, rendered.lines[0].spans[0].text, "\u{2504}\u{2504} ")); // ┄┄
}

test "pink heading bar prefixes and h1 blank-wrap render" {
    const allocator = std.testing.allocator;
    const decor = try presetDecor(allocator, "pink");
    var document = try markdown.parse(allocator,
        \\# One
        \\
        \\## Two
    );
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);

    // h1 has no marker but a leading own blank line (blank_wrap).
    try std.testing.expectEqual(@as(usize, 0), rendered.lines[0].spans.len);
    var saw_bar = false;
    for (rendered.lines) |line| {
        for (line.spans) |span| {
            if (std.mem.indexOf(u8, span.text, "\u{258C}") != null) saw_bar = true; // ▌ (h2 bar)
        }
    }
    try std.testing.expect(saw_bar);
}

test "default (legacy) decor leaves headings unfilled and marked with #" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "# Title");
    defer document.deinit(allocator);
    // No decor override => legacy.
    var rendered = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0 });
    defer rendered.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, rendered.lines[0].spans[0].text, "# "));
    // No full-line fill: the line width is just the content, not padded to 40.
    try std.testing.expect(rendered.lines[0].displayWidth() < 40);
}

test "hr full mode fills the content width" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "---");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 8, .left_padding = 0 });
    defer rendered.deinit(allocator);
    // 8 columns of ─.
    try std.testing.expectEqual(@as(usize, 8), rendered.lines[0].displayWidth());
}

test "hr fixed mode is literal but clamps to width" {
    const allocator = std.testing.allocator;
    const decor = decor_mod.Decor{ .glyphs = .{ .hr_glyph = "-", .hr_mode = .fixed, .hr_count = 20 } };
    var document = try markdown.parse(allocator, "---");
    defer document.deinit(allocator);

    // Wide: the literal count of 20 is drawn.
    var wide = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0, .decor = &decor });
    defer wide.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 20), wide.lines[0].displayWidth());

    // Narrow: clamped to the available width.
    var narrow = try renderDocument(allocator, document, .{ .width = 5, .left_padding = 0, .decor = &decor });
    defer narrow.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), narrow.lines[0].displayWidth());
}

test "markview rounded table draws rounded corners; dark stays grid" {
    const allocator = std.testing.allocator;
    const src =
        \\| A | B |
        \\| --- | --- |
        \\| x | y |
    ;
    var document = try markdown.parse(allocator, src);
    defer document.deinit(allocator);

    const decor = try presetDecor(allocator, "markview");
    var rounded = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0, .decor = &decor });
    defer rounded.deinit(allocator);
    var saw_tl = false;
    var saw_br = false;
    for (rounded.lines) |line| for (line.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "\u{256D}") != null) saw_tl = true; // ╭
        if (std.mem.indexOf(u8, span.text, "\u{256F}") != null) saw_br = true; // ╯
    };
    try std.testing.expect(saw_tl and saw_br);

    // Default (grid) has no rounded corners.
    var grid = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0 });
    defer grid.deinit(allocator);
    for (grid.lines) |line| for (line.spans) |span| {
        try std.testing.expect(std.mem.indexOf(u8, span.text, "\u{256D}") == null);
    };
}

test "markview link icon and inline-code chip render" {
    const allocator = std.testing.allocator;
    const decor = try presetDecor(allocator, "markview");
    var document = try markdown.parse(allocator, "See [site](https://x) and `co`.");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 80, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);

    var saw_icon = false;
    var saw_chip = false;
    for (rendered.lines) |line| for (line.spans) |span| {
        if (span.style == .link and std.mem.indexOf(u8, span.text, "\u{2192}") != null) saw_icon = true; // →
        // The chip prefix/suffix (" ") merges with the code text into " co ".
        if (span.style == .code and std.mem.startsWith(u8, span.text, " ") and std.mem.endsWith(u8, span.text, " ")) saw_chip = true;
    };
    try std.testing.expect(saw_icon);
    try std.testing.expect(saw_chip);
}

test "dracula image alt gets a trailing arrow suffix" {
    const allocator = std.testing.allocator;
    const decor = try presetDecor(allocator, "dracula");
    var document = try markdown.parse(allocator, "![cat](c.png)");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 80, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);
    var saw_suffix = false;
    for (rendered.lines) |line| for (line.spans) |span| {
        if (span.style == .image_alt and std.mem.indexOf(u8, span.text, " \u{2192}") != null) saw_suffix = true; // " →"
    };
    try std.testing.expect(saw_suffix);
}

test "ansi rule code frame brackets code with border rules, no fences" {
    const allocator = std.testing.allocator;
    const decor = try presetDecor(allocator, "ansi");
    var document = try markdown.parse(allocator,
        \\```py
        \\x = 1
        \\```
    );
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);
    // No ``` fence lines; a top and bottom ─ rule capped at 20.
    var saw_fence = false;
    var rule_lines: usize = 0;
    for (rendered.lines) |line| {
        for (line.spans) |span| {
            if (std.mem.indexOf(u8, span.text, "```") != null) saw_fence = true;
        }
        if (line.spans.len == 1 and std.mem.indexOf(u8, line.spans[0].text, "\u{2500}") != null) {
            rule_lines += 1;
            try std.testing.expectEqual(@as(usize, 20), line.displayWidth());
        }
    }
    try std.testing.expect(!saw_fence);
    try std.testing.expectEqual(@as(usize, 2), rule_lines);
}

test "markview block code frame emits a language label chip" {
    const allocator = std.testing.allocator;
    const decor = try presetDecor(allocator, "markview");
    var document = try markdown.parse(allocator,
        \\```py
        \\x = 1
        \\```
    );
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0, .decor = &decor });
    defer rendered.deinit(allocator);
    var saw_label = false;
    var saw_fence = false;
    for (rendered.lines) |line| for (line.spans) |span| {
        if (std.mem.indexOf(u8, span.text, " py ") != null) saw_label = true;
        if (std.mem.indexOf(u8, span.text, "```") != null) saw_fence = true;
    };
    try std.testing.expect(saw_label);
    try std.testing.expect(!saw_fence);
}

const theme = @import("../theme.zig");
const cidx = @import("../theme/color.zig").idx;

/// The first non-whitespace-only span on a line (skips leading padding spans).
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
    // Legacy decor (default), left_padding 0 so the marker is span[0].
    var rendered = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0 });
    defer rendered.deinit(allocator);

    // Each list line: marker span in its slot style, then body text.
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
        // Item text carries its own list_item slot (markers keep their slots).
        const text = line.spans[line.spans.len - 1];
        try std.testing.expectEqualStrings(e.text, text.text);
        try std.testing.expectEqual(SpanStyle.list_item, text.style);
        li += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), li);
}

test "default dark: markers resolve to the muted color, item text to list_item (250)" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "- one");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 40, .left_padding = 0 });
    defer rendered.deinit(allocator);

    const pal = theme.neutralDark;
    const marker = firstMarkerSpan(rendered.lines[0]);
    const text = rendered.lines[0].spans[rendered.lines[0].spans.len - 1];
    // The bullet slot falls back to muted in dark → byte-identical marker color.
    try std.testing.expectEqual(pal.muted.fg, theme.token(pal, marker.style).fg);
    // Item text now has its own register: dark list_item = 250 (one softer than 254 body).
    try std.testing.expectEqual(cidx(250), theme.token(pal, text.style).fg);
    try std.testing.expectEqual(cidx(254), pal.body.fg);
}

test "dark list_item = 250, light = 236 (own register, one step softer than body)" {
    const dark = theme.neutralDark;
    const light = theme.neutralLight;
    try std.testing.expectEqual(cidx(250), dark.list_item.fg);
    try std.testing.expectEqual(cidx(254), dark.body.fg);
    try std.testing.expectEqual(cidx(236), light.list_item.fg);
    try std.testing.expectEqual(cidx(234), light.body.fg);
}

test "list_item falls back to a theme's own body when unset (dracula)" {
    const drac = resolve.builtinResolved(std.testing.allocator, "dracula");
    // dracula sets no list_item slot → it inherits dracula's own body, not the
    // dark base's list_item (byte-identical to the pre-slot item-text rendering).
    try std.testing.expectEqual(drac.styles.body.fg, drac.styles.list_item.fg);
}

test {
    _ = @import("render_test2.zig");
}
