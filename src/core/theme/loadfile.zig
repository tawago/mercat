const std = @import("std");

pub const RawKV = struct { key: []const u8, value: []const u8 };

pub const RawThemeBuilder = struct {
    top: std.ArrayList(RawKV) = .empty,
    slots: std.ArrayList(Slot) = .empty,

    pub const Slot = struct {
        name: []const u8,
        kvs: std.ArrayList(RawKV) = .empty,
    };

    pub fn deinit(self: *RawThemeBuilder, alloc: std.mem.Allocator) void {
        freeKvList(alloc, &self.top);
        for (self.slots.items) |*slot| {
            alloc.free(slot.name);
            freeKvList(alloc, &slot.kvs);
        }
        self.slots.deinit(alloc);
    }

    pub fn set(
        self: *RawThemeBuilder,
        alloc: std.mem.Allocator,
        slot: ?[]const u8,
        key: []const u8,
        value: []const u8,
    ) !void {
        const list = if (slot) |name| try self.slotList(alloc, name) else &self.top;
        try setKv(alloc, list, key, value);
    }

    fn slotList(self: *RawThemeBuilder, alloc: std.mem.Allocator, name: []const u8) !*std.ArrayList(RawKV) {
        for (self.slots.items) |*slot| {
            if (std.mem.eql(u8, slot.name, name)) return &slot.kvs;
        }
        try self.slots.append(alloc, .{ .name = try alloc.dupe(u8, name) });
        return &self.slots.items[self.slots.items.len - 1].kvs;
    }

    pub fn view(self: *const RawThemeBuilder) RawThemeTables {
        return .{ .top = self.top.items, .slots = self.slots.items };
    }
};

pub const RawThemeTables = struct {
    top: []const RawKV,
    slots: []const RawThemeBuilder.Slot,
};

fn freeKvList(alloc: std.mem.Allocator, list: *std.ArrayList(RawKV)) void {
    for (list.items) |kv| {
        alloc.free(kv.key);
        alloc.free(kv.value);
    }
    list.deinit(alloc);
}

fn setKv(alloc: std.mem.Allocator, list: *std.ArrayList(RawKV), key: []const u8, value: []const u8) !void {
    for (list.items) |*kv| {
        if (std.mem.eql(u8, kv.key, key)) {
            const dup = try alloc.dupe(u8, value);
            alloc.free(kv.value);
            kv.value = dup;
            return;
        }
    }
    const k = try alloc.dupe(u8, key);
    errdefer alloc.free(k);
    const v = try alloc.dupe(u8, value);
    try list.append(alloc, .{ .key = k, .value = v });
}

pub fn assignThemeValue(
    alloc: std.mem.Allocator,
    builder: *RawThemeBuilder,
    subtable: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    const slot: ?[]const u8 = if (subtable.len == 0) null else subtable;
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        const decoded = try decodeQuotedString(alloc, value);
        defer alloc.free(decoded);
        try builder.set(alloc, slot, key, decoded);
    } else {
        try builder.set(alloc, slot, key, value);
    }
}

pub fn parseThemeTables(alloc: std.mem.Allocator, text: []const u8) !RawThemeBuilder {
    var builder = RawThemeBuilder{};
    errdefer builder.deinit(alloc);
    try applyThemeLines(alloc, &builder, text);
    return builder;
}

fn applyThemeLines(alloc: std.mem.Allocator, builder: *RawThemeBuilder, text: []const u8) !void {
    var scanner = scanLines(text, "theme");
    while (scanner.next()) |event| {
        if (!std.mem.eql(u8, event.table, "theme")) continue;
        try assignThemeValue(alloc, builder, event.subtable, event.key, event.value);
    }
}

pub const LineScanner = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    section: []const u8,
    table: []const u8,
    subtable: []const u8,

    pub const Event = struct {
        section: []const u8,
        table: []const u8,
        subtable: []const u8,
        key: []const u8,
        value: []const u8,
    };

    pub fn next(self: *LineScanner) ?Event {
        while (self.lines.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                self.section = trimmed[1 .. trimmed.len - 1];
                const split = splitSection(self.section);
                self.table = split.table;
                self.subtable = split.subtable;
                continue;
            }

            const equals_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..equals_index], " \t");
            const value = stripInlineComment(std.mem.trim(u8, trimmed[equals_index + 1 ..], " \t"));
            return .{
                .section = self.section,
                .table = self.table,
                .subtable = self.subtable,
                .key = key,
                .value = value,
            };
        }
        return null;
    }
};

pub fn scanLines(text: []const u8, initial_section: []const u8) LineScanner {
    const split = splitSection(initial_section);
    return .{
        .lines = std.mem.splitScalar(u8, text, '\n'),
        .section = initial_section,
        .table = split.table,
        .subtable = split.subtable,
    };
}

pub fn splitSection(section: []const u8) struct { table: []const u8, subtable: []const u8 } {
    if (std.mem.indexOfScalar(u8, section, '.')) |dot| {
        return .{ .table = section[0..dot], .subtable = section[dot + 1 ..] };
    }
    return .{ .table = section, .subtable = "" };
}

pub fn stripInlineComment(value: []const u8) []const u8 {
    var in_quotes = false;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const ch = value[i];
        if (in_quotes and ch == '\\') {
            i += 1;
            continue;
        }
        if (ch == '"') {
            in_quotes = !in_quotes;
        } else if (ch == '#' and !in_quotes) {
            return std.mem.trim(u8, value[0..i], " \t");
        }
    }
    return value;
}

pub fn parseInlineArray(alloc: std.mem.Allocator, value: []const u8) !?[][]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return null;
    const body = trimmed[1 .. trimmed.len - 1];

    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |item| alloc.free(item);
        out.deinit(alloc);
    }

    var in_quotes = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        if (!at_end) {
            const ch = body[i];
            if (in_quotes and ch == '\\') {
                i += 1;
                continue;
            }
            if (ch == '"') {
                in_quotes = !in_quotes;
                continue;
            }
            if (ch != ',' or in_quotes) continue;
        }
        const element = std.mem.trim(u8, body[start..i], " \t");
        if (element.len != 0) {
            const decoded = try decodeQuotedString(alloc, element);
            if (decoded.len != 0) try out.append(alloc, decoded) else alloc.free(decoded);
        }
        start = i + 1;
    }
    return try out.toOwnedSlice(alloc);
}

pub fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

pub fn decodeQuotedString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const inner = stripQuotes(raw);
    var buf = try allocator.alloc(u8, inner.len);
    errdefer allocator.free(buf);

    var len: usize = 0;
    var i: usize = 0;
    while (i < inner.len) {
        const ch = inner[i];
        if (ch != '\\' or i + 1 >= inner.len) {
            buf[len] = ch;
            len += 1;
            i += 1;
            continue;
        }
        switch (inner[i + 1]) {
            '"' => {
                buf[len] = '"';
                len += 1;
                i += 2;
            },
            '\\' => {
                buf[len] = '\\';
                len += 1;
                i += 2;
            },
            'n' => {
                buf[len] = '\n';
                len += 1;
                i += 2;
            },
            't' => {
                buf[len] = '\t';
                len += 1;
                i += 2;
            },
            'r' => {
                buf[len] = '\r';
                len += 1;
                i += 2;
            },
            'u', 'U' => {
                const digits: usize = if (inner[i + 1] == 'u') 4 else 8;
                const decoded = decodeUnicodeEscape(inner[i..], digits, buf[len..]);
                if (decoded) |n| {
                    len += n;
                    i += 2 + digits;
                } else {
                    buf[len] = ch;
                    len += 1;
                    i += 1;
                }
            },
            else => {
                buf[len] = ch;
                len += 1;
                i += 1;
            },
        }
    }

    if (len == buf.len) return buf;
    return allocator.realloc(buf, len);
}

fn decodeUnicodeEscape(seq: []const u8, digits: usize, out: []u8) ?usize {
    if (seq.len < 2 + digits) return null;
    const code = std.fmt.parseInt(u21, seq[2 .. 2 + digits], 16) catch return null;
    return std.unicode.utf8Encode(code, out) catch null;
}

pub fn resolveThemeDir(alloc: std.mem.Allocator) !?[]u8 {
    if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |xdg| {
        defer alloc.free(xdg);
        return try std.fs.path.join(alloc, &.{ xdg, "mercat", "themes" });
    } else |_| {}

    if (std.process.getEnvVarOwned(alloc, "HOME")) |home| {
        defer alloc.free(home);
        return try std.fs.path.join(alloc, &.{ home, ".config", "mercat", "themes" });
    } else |_| {}

    return null;
}

pub fn readThemeFile(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?RawThemeBuilder {
    const filename = try std.fmt.allocPrint(alloc, "{s}.toml", .{name});
    defer alloc.free(filename);
    const path = try std.fs.path.join(alloc, &.{ dir, filename });
    defer alloc.free(path);

    const file = openFile(path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(contents);

    return try parseThemeTables(alloc, contents);
}

fn openFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, .{});
    return std.fs.cwd().openFile(path, .{});
}

test {
    _ = @import("loadfile_test.zig");
}
