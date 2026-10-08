const std = @import("std");
const theme = @import("../core/theme.zig");
const color = @import("../core/theme/color.zig");
const Color = color.Color;

pub fn writeStyled(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), style: []const u8, text: []const u8, reset: []const u8) !void {
    try buffer.appendSlice(allocator, style);
    try buffer.appendSlice(allocator, text);
    try buffer.appendSlice(allocator, reset);
}

pub fn writeHyperlink(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), url: []const u8, text: []const u8, token: theme.StyleToken) !void {
    try buffer.appendSlice(allocator, "\x1b]8;;");
    try buffer.appendSlice(allocator, url);
    try buffer.appendSlice(allocator, "\x1b\\");

    try writeTokenStyled(allocator, buffer, token, text);

    try buffer.appendSlice(allocator, "\x1b]8;;\x1b\\");
}

pub const reset_sequence = "\x1b[0m";

pub fn writeTokenPrefix(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), token: theme.StyleToken) !void {
    var prefix: [48]u8 = undefined;
    const style = try formatStyle(&prefix, token);
    try buffer.appendSlice(allocator, style);
}

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
    try writeColorSgr(writer, token.fg, .fg);
    if (token.bg) |bg| {
        try writer.writeAll(";");
        try writeColorSgr(writer, bg, .bg);
    }
    try writer.writeAll("m");
    return buffer[0..stream.pos];
}

const Layer = enum { fg, bg };

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

test "formatStyle emits xterm-256 for index colors" {
    var buf: [48]u8 = undefined;
    const out = try formatStyle(&buf, .{ .fg = .{ .index = 81 }, .bold = true });
    try std.testing.expectEqualStrings("\x1b[1;38;5;81m", out);
}

test "formatStyle emits named SGR for ansi16 colors" {
    var buf: [48]u8 = undefined;
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
    try std.testing.expectEqualStrings("\x1b[38;5;231m", off);
    color.setTruecolor(false);
}

test "formatStyle emits terminal-default for default arm" {
    var buf: [48]u8 = undefined;
    const out = try formatStyle(&buf, .{ .fg = .default, .bg = .default });
    try std.testing.expectEqualStrings("\x1b[39;49m", out);
}
