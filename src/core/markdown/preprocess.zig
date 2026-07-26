//! Extended Markdown Syntax Pre-processor
//!
//! Transforms extended syntax not supported by koino into HTML tags that the
//! render pipeline can recognise and style appropriately.
//!
//! Transformations applied (outside code spans and fenced code blocks):
//!   ^text^        →  <sup>text</sup>      (superscript)
//!   ~text~        →  <sub>text</sub>      (subscript, single tilde only)
//!   ==text==      →  <mark>text</mark>    (highlighted text)
//!
//! Footnotes:
//!   [^label]: definition   →  definition line collected and appended at end
//!   [^label]               →  [^label] marker replaced with superscript ref
//!
//! Guarantees:
//!   - Content inside `backtick` inline code is never modified.
//!   - Content inside fenced code blocks (``` or ~~~) is never modified.
//!   - Escaped characters (\^ \~ \=) are not treated as syntax.
//!   - The returned slice is always caller-owned (allocator.free).

const std = @import("std");

// ---------------------------------------------------------------------------
// Unicode superscript / subscript character helpers
// ---------------------------------------------------------------------------

/// Return the UTF-8 encoding of the Unicode superscript for `char`, or null
/// if no superscript equivalent exists.
fn toSuperscript(char: u8) ?[]const u8 {
    return switch (char) {
        '0' => "⁰",
        '1' => "¹",
        '2' => "²",
        '3' => "³",
        '4' => "⁴",
        '5' => "⁵",
        '6' => "⁶",
        '7' => "⁷",
        '8' => "⁸",
        '9' => "⁹",
        '+' => "⁺",
        '-' => "⁻",
        '=' => "⁼",
        '(' => "⁽",
        ')' => "⁾",
        'a' => "ᵃ",
        'b' => "ᵇ",
        'c' => "ᶜ",
        'd' => "ᵈ",
        'e' => "ᵉ",
        'f' => "ᶠ",
        'g' => "ᵍ",
        'h' => "ʰ",
        'i' => "ⁱ",
        'j' => "ʲ",
        'k' => "ᵏ",
        'l' => "ˡ",
        'm' => "ᵐ",
        'n' => "ⁿ",
        'o' => "ᵒ",
        'p' => "ᵖ",
        // 'q' has no Unicode superscript equivalent
        'r' => "ʳ",
        's' => "ˢ",
        't' => "ᵗ",
        'u' => "ᵘ",
        'v' => "ᵛ",
        'w' => "ʷ",
        'x' => "ˣ",
        'y' => "ʸ",
        'z' => "ᶻ",
        else => null,
    };
}

/// Return the UTF-8 encoding of the Unicode subscript for `char`, or null
/// if no subscript equivalent exists.
fn toSubscript(char: u8) ?[]const u8 {
    return switch (char) {
        '0' => "₀",
        '1' => "₁",
        '2' => "₂",
        '3' => "₃",
        '4' => "₄",
        '5' => "₅",
        '6' => "₆",
        '7' => "₇",
        '8' => "₈",
        '9' => "₉",
        '+' => "₊",
        '-' => "₋",
        '=' => "₌",
        '(' => "₍",
        ')' => "₎",
        'a' => "ₐ",
        'e' => "ₑ",
        'h' => "ₕ",
        'i' => "ᵢ",
        'j' => "ⱼ",
        'k' => "ₖ",
        'l' => "ₗ",
        'm' => "ₘ",
        'n' => "ₙ",
        'o' => "ₒ",
        'p' => "ₚ",
        'r' => "ᵣ",
        's' => "ₛ",
        't' => "ₜ",
        'u' => "ᵤ",
        'v' => "ᵥ",
        'x' => "ₓ",
        else => null,
    };
}

/// Convert each character of `text` to its Unicode superscript equivalent.
/// Characters without a superscript mapping are kept as-is.
/// Caller owns the returned slice.
fn convertToSuperscript(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (text) |ch| {
        if (toSuperscript(ch)) |replacement| {
            try out.appendSlice(allocator, replacement);
        } else {
            try out.append(allocator, ch);
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Convert each character of `text` to its Unicode subscript equivalent.
/// Characters without a subscript mapping are kept as-is.
/// Caller owns the returned slice.
fn convertToSubscript(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (text) |ch| {
        if (toSubscript(ch)) |replacement| {
            try out.appendSlice(allocator, replacement);
        } else {
            try out.append(allocator, ch);
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Convert text to strikethrough by adding U+0336 (COMBINING LONG STROKE OVERLAY)
/// after each character. This creates a visual strikethrough effect: h̶e̶l̶l̶o̶
/// Caller owns the returned slice.
fn convertToStrikethrough(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const combining_stroke = "\u{0336}"; // COMBINING LONG STROKE OVERLAY (3 bytes)
    for (text) |ch| {
        try out.append(allocator, ch);
        // Don't add stroke to spaces or newlines
        if (ch != ' ' and ch != '\n' and ch != '\r' and ch != '\t') {
            try out.appendSlice(allocator, combining_stroke);
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Apply all extended-syntax transformations to `source`.
/// Returns a new heap-allocated string that the caller must free.
/// If no transformations are needed the returned string may still be a copy.
pub fn preprocess(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    // Work in two passes to keep each pass simple and correct.
    // Pass 1: inline spans (super/sub/highlight) - respects code fences & backticks.
    const after_spans = try transformSpans(allocator, source);
    errdefer allocator.free(after_spans);

    // Pass 2: footnotes - collect definitions, replace references.
    const after_footnotes = try transformFootnotes(allocator, after_spans);
    allocator.free(after_spans);
    return after_footnotes;
}

// ---------------------------------------------------------------------------
// Pass 1 – inline span syntax
// ---------------------------------------------------------------------------

const ConvertMode = enum {
    /// Wrap with open_tag / close_tag HTML tags.
    html_tag,
    /// Convert each character to its Unicode superscript equivalent.
    unicode_superscript,
    /// Convert each character to its Unicode subscript equivalent.
    unicode_subscript,
    /// Add combining long stroke overlay (U+0336) after each character.
    unicode_strikethrough,
};

const SpanRule = struct {
    open_char: u8,
    open_char2: ?u8, // non-null means the delimiter is two identical chars
    open_tag: []const u8,
    close_tag: []const u8,
    mode: ConvertMode = .html_tag,
};

const SPAN_RULES = [_]SpanRule{
    .{ .open_char = '^', .open_char2 = null, .open_tag = "", .close_tag = "", .mode = .unicode_superscript },
    .{ .open_char = '~', .open_char2 = '~', .open_tag = "", .close_tag = "", .mode = .unicode_strikethrough },
    .{ .open_char = '~', .open_char2 = null, .open_tag = "", .close_tag = "", .mode = .unicode_subscript },
    .{ .open_char = '=', .open_char2 = '=', .open_tag = "<mark>", .close_tag = "</mark>", .mode = .html_tag },
};

fn transformSpans(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var in_code_fence: bool = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;

    while (i < source.len) {
        // ── detect & skip fenced code blocks ──────────────────────────────
        if (!in_code_fence and (source[i] == '`' or source[i] == '~')) {
            const c = source[i];
            var run: usize = 0;
            while (i + run < source.len and source[i + run] == c) run += 1;
            if (run >= 3) {
                // Opening fence: copy verbatim until matching closing fence.
                in_code_fence = true;
                fence_char = c;
                fence_len = run;
                try out.appendSlice(allocator, source[i .. i + run]);
                i += run;
                continue;
            }
        }

        if (in_code_fence) {
            if (source[i] == fence_char) {
                var run: usize = 0;
                while (i + run < source.len and source[i + run] == fence_char) run += 1;
                try out.appendSlice(allocator, source[i .. i + run]);
                i += run;
                if (run >= fence_len) {
                    in_code_fence = false;
                    fence_char = 0;
                    fence_len = 0;
                }
                continue;
            }
            try out.append(allocator, source[i]);
            i += 1;
            continue;
        }

        // ── skip inline code spans (backtick runs) ────────────────────────
        if (source[i] == '`') {
            // Count opening backticks.
            var tick_len: usize = 0;
            while (i + tick_len < source.len and source[i + tick_len] == '`') tick_len += 1;
            const code_start = i;
            i += tick_len;
            // Find matching closing run.
            while (i < source.len) {
                if (source[i] == '`') {
                    var close_run: usize = 0;
                    while (i + close_run < source.len and source[i + close_run] == '`') close_run += 1;
                    if (close_run == tick_len) {
                        i += close_run;
                        break;
                    }
                    i += close_run;
                } else {
                    i += 1;
                }
            }
            try out.appendSlice(allocator, source[code_start..i]);
            continue;
        }

        // ── escaped characters ────────────────────────────────────────────
        if (source[i] == '\\' and i + 1 < source.len) {
            const next = source[i + 1];
            if (next == '^' or next == '~' or next == '=') {
                // Emit the escaped character literally (strip the backslash).
                try out.append(allocator, next);
                i += 2;
                continue;
            }
        }

        // ── try each span rule ────────────────────────────────────────────
        var matched = false;
        for (SPAN_RULES) |rule| {
            if (source[i] != rule.open_char) continue;

            // Skip footnote references [^...] - don't treat ^ after [ as superscript
            if (rule.open_char == '^' and i > 0 and source[i - 1] == '[') continue;

            // For two-char delimiters (==), require two chars.
            const delim_len: usize = if (rule.open_char2 != null) 2 else 1;
            if (delim_len == 2) {
                if (i + 1 >= source.len or source[i + 1] != rule.open_char2.?) continue;
            } else {
                // For single-char delimiters, skip doubled sequences so that
                // ~~strikethrough~~ is left for koino to handle.
                // If the char ahead is the same, emit two chars and skip.
                if (i + 1 < source.len and source[i + 1] == rule.open_char) {
                    try out.append(allocator, source[i]);
                    try out.append(allocator, source[i + 1]);
                    i += 2;
                    matched = true;
                    break;
                }
            }

            // Must not be followed immediately by whitespace (opening delimiter rule).
            const content_start = i + delim_len;
            if (content_start >= source.len) continue;
            if (source[content_start] == ' ' or source[content_start] == '\t' or source[content_start] == '\n') continue;

            // Find the closing delimiter (same chars, no whitespace before it).
            var j = content_start;
            var close_pos: ?usize = null;
            while (j < source.len) {
                // Don't span newlines for single-char delimiters (~, ^).
                if (delim_len == 1 and source[j] == '\n') break;
                if (source[j] == rule.open_char) {
                    if (delim_len == 2) {
                        if (j + 1 < source.len and source[j + 1] == rule.open_char2.?) {
                            if (j > content_start and source[j - 1] != ' ') {
                                close_pos = j;
                                break;
                            }
                            j += 2;
                            continue;
                        }
                    } else {
                        if (j > content_start and source[j - 1] != ' ') {
                            close_pos = j;
                            break;
                        }
                    }
                }
                j += 1;
            }

            if (close_pos) |cp| {
                const content = source[content_start..cp];
                // Reject empty content.
                if (content.len == 0) continue;
                switch (rule.mode) {
                    .html_tag => {
                        try out.appendSlice(allocator, rule.open_tag);
                        try out.appendSlice(allocator, content);
                        try out.appendSlice(allocator, rule.close_tag);
                    },
                    .unicode_superscript => {
                        const converted = try convertToSuperscript(allocator, content);
                        defer allocator.free(converted);
                        try out.appendSlice(allocator, converted);
                    },
                    .unicode_subscript => {
                        const converted = try convertToSubscript(allocator, content);
                        defer allocator.free(converted);
                        try out.appendSlice(allocator, converted);
                    },
                    .unicode_strikethrough => {
                        const converted = try convertToStrikethrough(allocator, content);
                        defer allocator.free(converted);
                        try out.appendSlice(allocator, converted);
                    },
                }
                i = cp + delim_len;
                matched = true;
                break;
            }
        }

        if (!matched) {
            try out.append(allocator, source[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Pass 2 – footnotes
// ---------------------------------------------------------------------------
//
// Strategy:
//   - Scan line by line for definition lines: `[^label]: text`
//   - Replace inline references `[^label]` with <sup>[N]</sup>
//   - Append a footnote section at the end of the document.
//
// Definitions are stripped from their original positions.
// References are replaced with numbered superscripts.

const FootnoteDef = struct {
    label: []const u8,
    text: []const u8,
    number: usize,
};

fn transformFootnotes(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    // First pass: collect all definition labels and their text.
    var defs: std.ArrayList(FootnoteDef) = .empty;
    defer {
        for (defs.items) |def| {
            allocator.free(def.label);
            allocator.free(def.text);
        }
        defs.deinit(allocator);
    }

    {
        var lines = std.mem.splitScalar(u8, source, '\n');
        var number: usize = 1;
        while (lines.next()) |line| {
            if (parseFootnoteDef(line)) |parsed| {
                // Check if we already have this label.
                var already = false;
                for (defs.items) |existing| {
                    if (std.mem.eql(u8, existing.label, parsed.label)) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    try defs.append(allocator, .{
                        .label = try allocator.dupe(u8, parsed.label),
                        .text = try allocator.dupe(u8, parsed.text),
                        .number = number,
                    });
                    number += 1;
                }
            }
        }
    }

    if (defs.items.len == 0) {
        // No footnotes at all - return a copy unchanged.
        return try allocator.dupe(u8, source);
    }

    // Second pass: rebuild source, stripping definition lines, replacing refs.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) try out.append(allocator, '\n');
        first_line = false;

        // Skip definition lines.
        if (parseFootnoteDef(line) != null) continue;

        // Replace inline references within this line.
        const replaced = try replaceFootnoteRefs(allocator, line, defs.items);
        defer allocator.free(replaced);
        try out.appendSlice(allocator, replaced);
    }

    // Append footnote definitions section if any.
    if (defs.items.len > 0) {
        try out.appendSlice(allocator, "\n\n---\n\n");
        for (defs.items) |def| {
            const line = try std.fmt.allocPrint(allocator, "<fndef id=\"{d}\">**[{d}]**</fndef> {s}\n\n", .{ def.number, def.number, def.text });
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
    }

    return try out.toOwnedSlice(allocator);
}

const FootnoteDefParsed = struct { label: []const u8, text: []const u8 };

fn parseFootnoteDef(line: []const u8) ?FootnoteDefParsed {
    // Pattern: `[^label]: text`  (may have leading spaces, max 3)
    var rest = line;
    var spaces: usize = 0;
    while (spaces < 4 and spaces < rest.len and rest[spaces] == ' ') spaces += 1;
    if (spaces == 4) return null; // indented code block
    rest = rest[spaces..];

    if (!std.mem.startsWith(u8, rest, "[^")) return null;
    const bracket_end = std.mem.indexOf(u8, rest, "]") orelse return null;
    if (bracket_end < 2) return null;
    if (bracket_end + 1 >= rest.len or rest[bracket_end + 1] != ':') return null;

    const label = rest[2..bracket_end];
    if (label.len == 0) return null;

    const text_start = bracket_end + 2;
    const text = std.mem.trimLeft(u8, rest[text_start..], " \t");
    return .{ .label = label, .text = text };
}

fn replaceFootnoteRefs(allocator: std.mem.Allocator, line: []const u8, defs: []const FootnoteDef) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        if (std.mem.startsWith(u8, line[i..], "[^")) {
            const bracket_end = std.mem.indexOf(u8, line[i..], "]") orelse {
                try out.append(allocator, line[i]);
                i += 1;
                continue;
            };
            const label = line[i + 2 .. i + bracket_end];
            var found_def: ?FootnoteDef = null;
            for (defs) |def| {
                if (std.mem.eql(u8, def.label, label)) {
                    found_def = def;
                    break;
                }
            }
            if (found_def) |def| {
                const ref = try std.fmt.allocPrint(allocator, "<fnref id=\"{d}\">[{d}]</fnref>", .{ def.number, def.number });
                defer allocator.free(ref);
                try out.appendSlice(allocator, ref);
                i += bracket_end + 1;
            } else {
                try out.append(allocator, line[i]);
                i += 1;
            }
        } else {
            try out.append(allocator, line[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "superscript basic" {
    const result = try preprocess(std.testing.allocator, "E=mc^2^");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("E=mc²", result);
}

test "superscript digits and symbols" {
    const result = try preprocess(std.testing.allocator, "10^-3^");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("10⁻³", result);
}

test "superscript letters" {
    const result = try preprocess(std.testing.allocator, "x^abc^");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("xᵃᵇᶜ", result);
}

test "superscript fallback for unknown char" {
    // 'q' has no Unicode superscript; it should pass through as-is.
    const result = try preprocess(std.testing.allocator, "x^q^");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("xq", result);
}

test "subscript basic" {
    const result = try preprocess(std.testing.allocator, "H~2~O");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("H₂O", result);
}

test "subscript digits and symbols" {
    const result = try preprocess(std.testing.allocator, "A~(n+1)~");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("A₍ₙ₊₁₎", result);
}

test "subscript letters" {
    const result = try preprocess(std.testing.allocator, "H~aei~");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hₐₑᵢ", result);
}

test "highlight basic" {
    const result = try preprocess(std.testing.allocator, "This is ==highlighted== text.");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("This is <mark>highlighted</mark> text.", result);
}

test "no transform inside backtick code" {
    const result = try preprocess(std.testing.allocator, "Use `^var^` in code");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Use `^var^` in code", result);
}

test "no transform inside fenced code block" {
    const source =
        \\```
        \\^superscript^ and ~subscript~ and ==highlight==
        \\```
    ;
    const result = try preprocess(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(source, result);
}

test "escaped delimiters" {
    const result = try preprocess(std.testing.allocator, "not \\^super\\^");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("not ^super^", result);
}

test "strikethrough converts to unicode" {
    // ~~text~~ is converted to Unicode combining long stroke overlay
    const result = try preprocess(std.testing.allocator, "~~deleted~~");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("d\u{0336}e\u{0336}l\u{0336}e\u{0336}t\u{0336}e\u{0336}d\u{0336}", result);
}

test "strikethrough preserves spaces" {
    const result = try preprocess(std.testing.allocator, "~~hello world~~");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("h\u{0336}e\u{0336}l\u{0336}l\u{0336}o\u{0336} w\u{0336}o\u{0336}r\u{0336}l\u{0336}d\u{0336}", result);
}

test "footnote definition and reference" {
    const source =
        \\See note[^1] here.
        \\
        \\[^1]: This is the footnote text.
    ;
    const result = try preprocess(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<fnref id=\"1\">[1]</fnref>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "This is the footnote text.") != null);
    // Definition line should be stripped from its original location.
    try std.testing.expect(std.mem.indexOf(u8, result, "[^1]:") == null);
}

test "footnote no definitions = no change" {
    const source = "No footnotes here.";
    const result = try preprocess(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(source, result);
}
