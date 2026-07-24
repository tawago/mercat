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

/// SGR reset sequence closing a styled run.
pub const reset_sequence = "\x1b[0m";

/// Writes the SGR style prefix for a StyleToken without any text or reset.
/// Lets callers coalesce a run of same-token spans behind one prefix/reset
/// pair, appending span text straight into the output buffer in between.
pub fn writeTokenPrefix(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), token: theme.StyleToken) !void {
    var prefix: [48]u8 = undefined;
    const style = try formatStyle(&prefix, token);
    try buffer.appendSlice(allocator, style);
}

/// Writes text with ANSI styling based on a StyleToken.
/// This is the CLI equivalent of theme.vaxisStyle() used by the TUI.
pub fn writeTokenStyled(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), token: theme.StyleToken, text: []const u8) !void {
    try writeTokenPrefix(allocator, buffer, token);
    try buffer.appendSlice(allocator, text);
    try buffer.appendSlice(allocator, reset_sequence);
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
    try writer.print("38;5;{d}", .{token.fg_index});
    if (token.bg_index) |bg| {
        try writer.print(";48;5;{d}", .{bg});
    }
    try writer.writeAll("m");
    return buffer[0..stream.pos];
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
