//! ANSI Escape Sequence Utilities
//!
//! This module provides ANSI output for CLI rendering:
//!
//!   - writeTokenStyled(): Converts StyleToken → ANSI escape codes
//!   - stripAlloc(): Removes ANSI codes from text
//!   - parseStyledLinesAlloc(): Parses ANSI text into vaxis.Segment for TUI
//!
//! In the styled text pipeline:
//!   CLI: Span.style → theme.token() → StyleToken → writeTokenStyled() → ANSI output
//!   TUI: Span.style → theme.token() → StyleToken → theme.vaxisStyle() → vaxis.Style

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("../core/theme.zig");
const color = @import("../core/theme/color.zig");
const Color = color.Color;

pub const StyledLine = struct {
    segments: []vaxis.Segment,

    pub fn deinit(self: StyledLine, allocator: std.mem.Allocator) void {
        for (self.segments) |segment| allocator.free(segment.text);
        allocator.free(self.segments);
    }
};

pub fn writeStyled(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), style: []const u8, text: []const u8, reset: []const u8) !void {
    try buffer.appendSlice(allocator, style);
    try buffer.appendSlice(allocator, text);
    try buffer.appendSlice(allocator, reset);
}

/// Writes text as an OSC 8 hyperlink with optional styling.
/// OSC 8 format: ESC ] 8 ; params ; URI ST text ESC ] 8 ; ; ST
pub fn writeHyperlink(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), url: []const u8, text: []const u8, token: theme.StyleToken) !void {
    // OSC 8 hyperlink start
    try buffer.appendSlice(allocator, "\x1b]8;;");
    try buffer.appendSlice(allocator, url);
    try buffer.appendSlice(allocator, "\x1b\\");

    // Write the text with styling
    try writeTokenStyled(allocator, buffer, token, text);

    // OSC 8 hyperlink end
    try buffer.appendSlice(allocator, "\x1b]8;;\x1b\\");
}

/// Writes text with ANSI styling based on a StyleToken.
/// This is the CLI equivalent of theme.vaxisStyle() used by the TUI.
pub fn writeTokenStyled(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), token: theme.StyleToken, text: []const u8) !void {
    var prefix: [48]u8 = undefined;
    const style = try formatStyle(&prefix, token);
    try buffer.appendSlice(allocator, style);
    try buffer.appendSlice(allocator, text);
    try buffer.appendSlice(allocator, "\x1b[0m");
}

fn formatStyle(buffer: []u8, token: theme.StyleToken) ![]const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    try writer.writeAll("\x1b[");
    var first = true;
    if (token.bold) {
        try writer.writeAll("1");
        first = false;
    }
    if (token.italic) {
        if (!first) try writer.writeAll(";");
        try writer.writeAll("3");
        first = false;
    }
    if (token.underline) {
        if (!first) try writer.writeAll(";");
        try writer.writeAll("4");
        first = false;
    }
    if (token.strikethrough) {
        if (!first) try writer.writeAll(";");
        try writer.writeAll("9");
        first = false;
    }
    if (!first) try writer.writeAll(";");
    try writeColorSgr(writer, token.fg, .fg);
    if (token.bg) |bg| {
        try writer.writeAll(";");
        try writeColorSgr(writer, bg, .bg);
    }
    try writer.writeAll("m");
    return buffer[0..stream.pos];
}

const Layer = enum { fg, bg };

/// Emit the SGR color parameters (no leading/trailing separators, no `m`) for
/// one color on one layer. `rgb` emits `38;2;r;g;b` when the terminal supports
/// truecolor, otherwise downgrades to the nearest xterm-256 index. `ansi16`
/// emits the named-color codes (30-37/90-97 fg, 40-47/100-107 bg) so the
/// terminal's own palette decides the hue.
fn writeColorSgr(writer: anytype, c: Color, layer: Layer) !void {
    const is_fg = layer == .fg;
    switch (c) {
        .default => try writer.writeAll(if (is_fg) "39" else "49"),
        .index => |n| try writeIndexed(writer, is_fg, n),
        .ansi16 => |a| {
            const slot = a.index();
            const base: u16 = if (slot < 8)
                (if (is_fg) @as(u16, 30) else 40)
            else
                (if (is_fg) @as(u16, 90) else 100);
            try writer.print("{d}", .{base + (slot % 8)});
        },
        .rgb => |v| {
            if (color.truecolorEnabled()) {
                if (is_fg) {
                    try writer.print("38;2;{d};{d};{d}", .{ v.r, v.g, v.b });
                } else {
                    try writer.print("48;2;{d};{d};{d}", .{ v.r, v.g, v.b });
                }
            } else {
                try writeIndexed(writer, is_fg, color.to256(c).?);
            }
        },
    }
}

fn writeIndexed(writer: anytype, is_fg: bool, n: u8) !void {
    if (is_fg) {
        try writer.print("38;5;{d}", .{n});
    } else {
        try writer.print("48;5;{d}", .{n});
    }
}

pub fn stripAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '[') {
            index += 2;
            while (index < text.len) : (index += 1) {
                const char = text[index];
                if ((char >= '@' and char <= '~') or char == 'm') {
                    index += 1;
                    break;
                }
            }
            continue;
        }
        try output.append(allocator, text[index]);
        index += 1;
    }

    return try output.toOwnedSlice(allocator);
}

pub fn parseStyledLinesAlloc(allocator: std.mem.Allocator, text: []const u8) ![]StyledLine {
    var lines: std.ArrayList(StyledLine) = .empty;
    errdefer {
        for (lines.items) |line| line.deinit(allocator);
        lines.deinit(allocator);
    }

    var current_segments: std.ArrayList(vaxis.Segment) = .empty;
    defer current_segments.deinit(allocator);

    var style: vaxis.Style = .{};
    var index: usize = 0;
    var start: usize = 0;

    while (index < text.len) {
        if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '[') {
            if (start < index) try appendSegment(allocator, &current_segments, text[start..index], style);
            index += 2;
            const sequence_start = index;
            while (index < text.len and text[index] != 'm') : (index += 1) {}
            if (index < text.len and text[index] == 'm') {
                try applySgr(&style, text[sequence_start..index]);
                index += 1;
            }
            start = index;
            continue;
        }

        if (text[index] == '\n') {
            if (start < index) try appendSegment(allocator, &current_segments, text[start..index], style);
            try lines.append(allocator, .{ .segments = try current_segments.toOwnedSlice(allocator) });
            current_segments = .empty;
            index += 1;
            start = index;
            continue;
        }

        index += 1;
    }

    if (start < text.len) try appendSegment(allocator, &current_segments, text[start..], style);
    if (current_segments.items.len != 0 or text.len == 0 or text[text.len - 1] == '\n') {
        try lines.append(allocator, .{ .segments = try current_segments.toOwnedSlice(allocator) });
        current_segments = .empty;
    }

    return try lines.toOwnedSlice(allocator);
}

fn appendSegment(allocator: std.mem.Allocator, segments: *std.ArrayList(vaxis.Segment), text: []const u8, style: vaxis.Style) !void {
    if (text.len == 0) return;
    try segments.append(allocator, .{ .text = try allocator.dupe(u8, text), .style = style });
}

fn applySgr(style: *vaxis.Style, sequence: []const u8) !void {
    if (sequence.len == 0) {
        style.* = .{};
        return;
    }

    var iter = std.mem.splitScalar(u8, sequence, ';');
    while (iter.next()) |raw| {
        const code = std.fmt.parseUnsigned(u16, raw, 10) catch 0;
        switch (code) {
            0 => style.* = .{},
            1 => style.bold = true,
            3 => style.italic = true,
            4 => style.ul_style = .single,
            9 => style.strikethrough = true,
            22 => {
                style.bold = false;
                style.dim = false;
            },
            23 => style.italic = false,
            24 => style.ul_style = .off,
            29 => style.strikethrough = false,
            38 => {
                const mode = iter.next() orelse break;
                if (std.mem.eql(u8, mode, "5")) {
                    const value = iter.next() orelse break;
                    style.fg = .{ .index = std.fmt.parseUnsigned(u8, value, 10) catch 0 };
                }
            },
            39 => style.fg = .default,
            48 => {
                const mode = iter.next() orelse break;
                if (std.mem.eql(u8, mode, "5")) {
                    const value = iter.next() orelse break;
                    style.bg = .{ .index = std.fmt.parseUnsigned(u8, value, 10) catch 0 };
                }
            },
            49 => style.bg = .default,
            else => {},
        }
    }
}

test "strips ansi escape sequences" {
    const allocator = std.testing.allocator;
    const stripped = try stripAlloc(allocator, "\x1b[31mhello\x1b[0m world");
    defer allocator.free(stripped);

    try std.testing.expectEqualStrings("hello world", stripped);
}

test "formatStyle emits xterm-256 for index colors" {
    var buf: [48]u8 = undefined;
    const out = try formatStyle(&buf, .{ .fg = .{ .index = 81 }, .bold = true });
    try std.testing.expectEqualStrings("\x1b[1;38;5;81m", out);
}

test "formatStyle emits named SGR for ansi16 colors" {
    var buf: [48]u8 = undefined;
    // blue (slot 4) fg → 34; bright_green (slot 10) bg → 102.
    const out = try formatStyle(&buf, .{ .fg = .{ .ansi16 = .blue }, .bg = .{ .ansi16 = .bright_green } });
    try std.testing.expectEqualStrings("\x1b[34;102m", out);
}

test "formatStyle emits truecolor when enabled, downgrades when off" {
    var buf: [48]u8 = undefined;
    const tok: theme.StyleToken = .{ .fg = color.rgb(255, 255, 255) };

    color.setTruecolor(true);
    const on = try formatStyle(&buf, tok);
    try std.testing.expectEqualStrings("\x1b[38;2;255;255;255m", on);

    color.setTruecolor(false);
    var buf2: [48]u8 = undefined;
    const off = try formatStyle(&buf2, tok);
    // Pure white downgrades to cube index 231.
    try std.testing.expectEqualStrings("\x1b[38;5;231m", off);
    color.setTruecolor(false);
}

test "formatStyle emits terminal-default for default arm" {
    var buf: [48]u8 = undefined;
    const out = try formatStyle(&buf, .{ .fg = .default, .bg = .default });
    try std.testing.expectEqualStrings("\x1b[39;49m", out);
}

test "parses ansi styled lines" {
    const allocator = std.testing.allocator;
    const lines = try parseStyledLinesAlloc(allocator, "\x1b[1;38;5;81mTitle\x1b[0m\nplain");
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqual(@as(usize, 1), lines[0].segments.len);
    try std.testing.expect(lines[0].segments[0].style.bold);
    try std.testing.expectEqualStrings("Title", lines[0].segments[0].text);
}
