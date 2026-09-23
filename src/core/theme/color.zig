const std = @import("std");

pub const Rgb = struct { r: u8, g: u8, b: u8 };
pub const Srgb = struct { r: u8, g: u8, b: u8 };

pub const Ansi16 = enum(u4) {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    pub fn parse(text: []const u8) ?Ansi16 {
        const table = [_]struct { name: []const u8, value: Ansi16 }{
            .{ .name = "black", .value = .black },
            .{ .name = "red", .value = .red },
            .{ .name = "green", .value = .green },
            .{ .name = "yellow", .value = .yellow },
            .{ .name = "blue", .value = .blue },
            .{ .name = "magenta", .value = .magenta },
            .{ .name = "cyan", .value = .cyan },
            .{ .name = "white", .value = .white },
            .{ .name = "bright_black", .value = .bright_black },
            .{ .name = "bright_red", .value = .bright_red },
            .{ .name = "bright_green", .value = .bright_green },
            .{ .name = "bright_yellow", .value = .bright_yellow },
            .{ .name = "bright_blue", .value = .bright_blue },
            .{ .name = "bright_magenta", .value = .bright_magenta },
            .{ .name = "bright_cyan", .value = .bright_cyan },
            .{ .name = "bright_white", .value = .bright_white },
            .{ .name = "gray", .value = .bright_black },
            .{ .name = "grey", .value = .bright_black },
        };
        for (table) |entry| {
            if (std.mem.eql(u8, entry.name, text)) return entry.value;
        }
        return null;
    }

    pub fn index(self: Ansi16) u8 {
        return @intFromEnum(self);
    }
};

pub const Color = union(enum) {
    default,
    index: u8,
    ansi16: Ansi16,
    rgb: Rgb,
};

pub fn idx(n: u8) Color {
    return .{ .index = n };
}

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .rgb = .{ .r = r, .g = g, .b = b } };
}

pub const ParseError = error{InvalidColor};

pub fn parseColor(text: []const u8) ParseError!Color {
    if (text.len == 0) return error.InvalidColor;
    if (std.mem.eql(u8, text, "default")) return .default;

    if (text[0] == '#') return parseHex(text[1..]);

    if (Ansi16.parse(text)) |named| return .{ .ansi16 = named };

    const n = std.fmt.parseUnsigned(u16, text, 10) catch return error.InvalidColor;
    if (n > 255) return error.InvalidColor;
    return .{ .index = @intCast(n) };
}

fn parseHex(hex: []const u8) ParseError!Color {
    switch (hex.len) {
        6 => return .{ .rgb = .{
            .r = try hexByte(hex[0..2]),
            .g = try hexByte(hex[2..4]),
            .b = try hexByte(hex[4..6]),
        } },
        3 => {
            const r = try hexNibble(hex[0]);
            const g = try hexNibble(hex[1]);
            const b = try hexNibble(hex[2]);
            return .{ .rgb = .{ .r = r * 17, .g = g * 17, .b = b * 17 } };
        },
        else => return error.InvalidColor,
    }
}

fn hexByte(pair: []const u8) ParseError!u8 {
    return (try hexNibble(pair[0])) * 16 + (try hexNibble(pair[1]));
}

fn hexNibble(c: u8) ParseError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidColor,
    };
}

var truecolor_flag: bool = false;

pub fn truecolorEnabled() bool {
    return truecolor_flag;
}

pub fn setTruecolor(value: bool) void {
    truecolor_flag = value;
}

pub fn detectTruecolorFromValue(colorterm: ?[]const u8) bool {
    const value = colorterm orelse return false;
    return std.mem.eql(u8, value, "truecolor") or std.mem.eql(u8, value, "24bit");
}

pub fn initTruecolor(allocator: std.mem.Allocator) void {
    const value = std.process.getEnvVarOwned(allocator, "COLORTERM") catch {
        setTruecolor(false);
        return;
    };
    defer allocator.free(value);
    setTruecolor(detectTruecolorFromValue(value));
}

pub fn toSrgb(c: Color) ?Srgb {
    return switch (c) {
        .default => null,
        .index => |n| xterm256ToSrgb(n),
        .ansi16 => |a| xterm256ToSrgb(a.index()),
        .rgb => |v| .{ .r = v.r, .g = v.g, .b = v.b },
    };
}

pub fn to256(c: Color) ?u8 {
    return switch (c) {
        .default => null,
        .index => |n| n,
        .ansi16 => |a| a.index(),
        .rgb => |v| rgbToNearest256(v),
    };
}

fn rgbToNearest256(v: Rgb) u8 {
    const ri = nearestCubeLevel(v.r);
    const gi = nearestCubeLevel(v.g);
    const bi = nearestCubeLevel(v.b);
    const cube_index: u8 = @intCast(16 + 36 * ri + 6 * gi + bi);
    const cube = xterm256ToSrgb(cube_index);
    const cube_err = squaredError(v, cube);

    const avg: u16 = (@as(u16, v.r) + v.g + v.b) / 3;
    var gray_index: u8 = undefined;
    if (avg < 8) {
        gray_index = 16;
    } else if (avg > 238) {
        gray_index = 231;
    } else {
        gray_index = @intCast(232 + (avg - 8) / 10);
    }
    const gray = xterm256ToSrgb(gray_index);
    const gray_err = squaredError(v, gray);

    return if (gray_err < cube_err) gray_index else cube_index;
}

fn nearestCubeLevel(value: u8) u8 {
    if (value < 48) return 0;
    if (value < 115) return 1;
    if (value < 155) return 2;
    if (value < 195) return 3;
    if (value < 235) return 4;
    return 5;
}

fn squaredError(a: Rgb, b: Srgb) u32 {
    const dr = @as(i32, a.r) - b.r;
    const dg = @as(i32, a.g) - b.g;
    const db = @as(i32, a.b) - b.b;
    return @intCast(dr * dr + dg * dg + db * db);
}

pub fn xterm256ToSrgb(index: u8) Srgb {
    if (index < 16) return system_colors[index];
    if (index < 232) {
        const i: u16 = @as(u16, index) - 16;
        const r = cube_levels[i / 36];
        const g = cube_levels[(i % 36) / 6];
        const b = cube_levels[i % 6];
        return .{ .r = r, .g = g, .b = b };
    }
    const gray: u8 = @intCast(8 + 10 * (@as(u16, index) - 232));
    return .{ .r = gray, .g = gray, .b = gray };
}

const cube_levels = [_]u8{ 0, 95, 135, 175, 215, 255 };

const system_colors = [16]Srgb{
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 128, .g = 0, .b = 0 },
    .{ .r = 0, .g = 128, .b = 0 },
    .{ .r = 128, .g = 128, .b = 0 },
    .{ .r = 0, .g = 0, .b = 128 },
    .{ .r = 128, .g = 0, .b = 128 },
    .{ .r = 0, .g = 128, .b = 128 },
    .{ .r = 192, .g = 192, .b = 192 },
    .{ .r = 128, .g = 128, .b = 128 },
    .{ .r = 255, .g = 0, .b = 0 },
    .{ .r = 0, .g = 255, .b = 0 },
    .{ .r = 255, .g = 255, .b = 0 },
    .{ .r = 0, .g = 0, .b = 255 },
    .{ .r = 255, .g = 0, .b = 255 },
    .{ .r = 0, .g = 255, .b = 255 },
    .{ .r = 255, .g = 255, .b = 255 },
};

const testing = std.testing;

test "parseColor hex 6-digit" {
    try testing.expectEqual(Color{ .rgb = .{ .r = 0xff, .g = 0x80, .b = 0x00 } }, try parseColor("#ff8000"));
}

test "parseColor hex 3-digit doubles nibbles" {
    try testing.expectEqual(Color{ .rgb = .{ .r = 0xff, .g = 0x00, .b = 0x33 } }, try parseColor("#f03"));
}

test "parseColor index" {
    try testing.expectEqual(Color{ .index = 236 }, try parseColor("236"));
}

test "parseColor ansi name" {
    try testing.expectEqual(Color{ .ansi16 = .blue }, try parseColor("blue"));
    try testing.expectEqual(Color{ .ansi16 = .bright_green }, try parseColor("bright_green"));
    try testing.expectEqual(Color{ .ansi16 = .bright_black }, try parseColor("gray"));
}

test "parseColor default" {
    try testing.expectEqual(Color.default, try parseColor("default"));
}

test "parseColor rejects invalid" {
    try testing.expectError(error.InvalidColor, parseColor(""));
    try testing.expectError(error.InvalidColor, parseColor("#12"));
    try testing.expectError(error.InvalidColor, parseColor("notacolor"));
    try testing.expectError(error.InvalidColor, parseColor("999"));
}

test "to256 passes through index and ansi16" {
    try testing.expectEqual(@as(?u8, 200), to256(.{ .index = 200 }));
    try testing.expectEqual(@as(?u8, 4), to256(.{ .ansi16 = .blue }));
    try testing.expectEqual(@as(?u8, null), to256(.default));
}

test "to256 maps rgb to nearest cube" {
    try testing.expectEqual(@as(?u8, 231), to256(rgb(255, 255, 255)));
    try testing.expectEqual(@as(?u8, 16), to256(rgb(0, 0, 0)));
    try testing.expectEqual(@as(?u8, 124), to256(rgb(175, 0, 0)));
    const g = to256(rgb(120, 120, 120)).?;
    try testing.expect(g >= 232 and g <= 255);
}

test "to256 round-trips exact cube anchors" {
    var i: u16 = 16;
    while (i < 232) : (i += 1) {
        const s = xterm256ToSrgb(@intCast(i));
        try testing.expectEqual(@as(?u8, @intCast(i)), to256(rgb(s.r, s.g, s.b)));
    }
}

test "toSrgb arms" {
    try testing.expectEqual(@as(?Srgb, null), toSrgb(.default));
    try testing.expectEqual(@as(?Srgb, .{ .r = 10, .g = 20, .b = 30 }), toSrgb(rgb(10, 20, 30)));
    try testing.expectEqual(@as(?Srgb, xterm256ToSrgb(236)), toSrgb(idx(236)));
    try testing.expectEqual(@as(?Srgb, xterm256ToSrgb(4)), toSrgb(.{ .ansi16 = .blue }));
}

test "detectTruecolor from COLORTERM value" {
    try testing.expect(detectTruecolorFromValue("truecolor"));
    try testing.expect(detectTruecolorFromValue("24bit"));
    try testing.expect(!detectTruecolorFromValue("256color"));
    try testing.expect(!detectTruecolorFromValue(null));
}

test "xterm-256 table anchors" {
    try testing.expectEqual(Srgb{ .r = 0, .g = 0, .b = 0 }, xterm256ToSrgb(0));
    try testing.expectEqual(Srgb{ .r = 255, .g = 255, .b = 255 }, xterm256ToSrgb(15));
}
