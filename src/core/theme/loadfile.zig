//! Stage S1: nested-TOML `[theme.<slot>]` raw table parsing + user theme-file
//! discovery/loading. This module is deliberately "dumb": it collects RAW
//! string key/value pairs per slot with no color/enum interpretation. Typed
//! interpretation (parseColor, glyph validation, extends folding) is S3's job
//! (`theme/resolve.zig`). Keeping the parser interpretation-free keeps it
//! trivially testable and makes the inline-config path and the user-file path
//! share exactly one storage + merge code path (`RawThemeBuilder.set`).

const std = @import("std");

/// One raw, uninterpreted `key = value` pair (both strings owned by the
/// containing builder / tables allocator).
pub const RawKV = struct { key: []const u8, value: []const u8 };

/// A growable accumulator for `[theme]` / `[theme.<slot>]` tables. The inline
/// config path (`config.zig`) feeds this incrementally line-by-line across
/// multiple `applyTomlLike` calls (default text then user config), and the
/// file path (`parseThemeTables`) fills one then freezes it. `set` implements
/// the locked merge policy: last-wins per key within a slot.
pub const RawThemeBuilder = struct {
    /// Top-level `[theme]` keys (e.g. `extends`, `palette`).
    top: std.ArrayList(RawKV) = .empty,
    /// One entry per distinct `[theme.<slot>]` table.
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

    /// Set `key = value` under `slot` (null => top-level `[theme]`). Last-wins:
    /// a repeated key overwrites the earlier value in place.
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

    /// Freeze into an immutable `RawThemeTables` (transfers ownership of the
    /// duped strings; the builder is emptied and safe to `deinit`).
    pub fn toOwned(self: *RawThemeBuilder, alloc: std.mem.Allocator) !RawThemeTables {
        const top = try self.top.toOwnedSlice(alloc);
        errdefer alloc.free(top);

        var slots = try alloc.alloc(RawThemeTables.Slot, self.slots.items.len);
        errdefer alloc.free(slots);
        for (self.slots.items, 0..) |*slot, i| {
            slots[i] = .{ .name = slot.name, .kvs = try slot.kvs.toOwnedSlice(alloc) };
        }
        self.slots.deinit(alloc);
        self.slots = .empty;
        return .{ .top = top, .slots = slots };
    }
};

/// Immutable, fully-owned raw theme tables (the file-path / handoff form).
pub const RawThemeTables = struct {
    top: []RawKV,
    slots: []Slot,

    pub const Slot = struct { name: []const u8, kvs: []RawKV };

    pub fn deinit(self: *RawThemeTables, alloc: std.mem.Allocator) void {
        for (self.top) |kv| {
            alloc.free(kv.key);
            alloc.free(kv.value);
        }
        alloc.free(self.top);
        for (self.slots) |slot| {
            alloc.free(slot.name);
            for (slot.kvs) |kv| {
                alloc.free(kv.key);
                alloc.free(kv.value);
            }
            alloc.free(slot.kvs);
        }
        alloc.free(self.slots);
    }
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

/// Route a single `[theme.<subtable>]` key/value into the builder. `subtable`
/// == "" targets the top-level `[theme]` table. Shared by the inline-config
/// path (`config.zig`) and the file path so both use one merge code path.
pub fn assignThemeValue(
    alloc: std.mem.Allocator,
    builder: *RawThemeBuilder,
    subtable: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    const slot: ?[]const u8 = if (subtable.len == 0) null else subtable;
    try builder.set(alloc, slot, key, stripQuotes(value));
}

/// Parse a whole theme-file text into raw tables. Only `[theme]` /
/// `[theme.<slot>]` sections are collected; any other section is ignored (a
/// user theme file is expected to contain only theme tables, but non-theme
/// noise is tolerated rather than rejected — validation is S3's job).
pub fn parseThemeTables(alloc: std.mem.Allocator, text: []const u8) !RawThemeTables {
    var builder = RawThemeBuilder{};
    errdefer builder.deinit(alloc);
    try applyThemeLines(alloc, &builder, text);
    return builder.toOwned(alloc);
}

fn applyThemeLines(alloc: std.mem.Allocator, builder: *RawThemeBuilder, text: []const u8) !void {
    // A dedicated theme file *is* the `[theme]` table: its document-root keys
    // (e.g. a top-of-file `extends = "dracula"`) belong to the top-level theme
    // table without needing an explicit `[theme]` header. So the scanner starts
    // in section `theme` with an empty subtable. A later `[display]` (or any
    // non-theme) header parks `event.table` off `theme`, which we skip;
    // `[theme]`/`[theme.<slot>]` bring it back.
    var scanner = scanLines(text, "theme");
    while (scanner.next()) |event| {
        if (!std.mem.eql(u8, event.table, "theme")) continue;
        try assignThemeValue(alloc, builder, event.subtable, event.key, event.value);
    }
}

/// The one line/section walker shared by the inline-config path (`config.zig`)
/// and the theme-file path (`applyThemeLines`). It walks TOML-like text and,
/// for each `key = value` line, yields the key/value alongside the current
/// section — both raw (`section`) and split into `(table, subtable)`. Blank
/// lines, `#` comment lines, and `[section]` / `[table.subtable]` headers are
/// consumed silently. Values are returned verbatim (quotes intact); consumers
/// decode/strip as they see fit — this scanner is decode-free.
pub const LineScanner = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    section: []const u8,
    table: []const u8,
    subtable: []const u8,

    pub const Event = struct {
        /// The full current section header text (undotted or `table.subtable`).
        section: []const u8,
        /// `section` split on its first `.` — the part before the dot.
        table: []const u8,
        /// `section` split on its first `.` — the part after it (else "").
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
            const value = std.mem.trim(u8, trimmed[equals_index + 1 ..], " \t");
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

/// Open a `LineScanner` over `text`, starting in `initial_section` (before any
/// header is seen). Pass "" for the config path (document-root keys have no
/// section); pass "theme" for the theme-file path (a theme file's root keys
/// belong to the implicit top-level `[theme]` table).
pub fn scanLines(text: []const u8, initial_section: []const u8) LineScanner {
    const split = splitSection(initial_section);
    return .{
        .lines = std.mem.splitScalar(u8, text, '\n'),
        .section = initial_section,
        .table = split.table,
        .subtable = split.subtable,
    };
}

/// Split a section header on its first `.` into `(table, subtable)`. Undotted
/// sections yield an empty subtable, preserving flat behavior.
pub fn splitSection(section: []const u8) struct { table: []const u8, subtable: []const u8 } {
    if (std.mem.indexOfScalar(u8, section, '.')) |dot| {
        return .{ .table = section[0..dot], .subtable = section[dot + 1 ..] };
    }
    return .{ .table = section, .subtable = "" };
}

pub fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

/// Resolve the user theme directory: `$XDG_CONFIG_HOME/mercat/themes` else
/// `$HOME/.config/mercat/themes`. Returns null when neither env var is set.
/// Caller owns the returned path.
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

/// Read + parse `<dir>/<name>.toml`. Returns null when the file does not
/// exist; other IO errors propagate.
pub fn readThemeFile(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?RawThemeTables {
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

// ===================================================================
// Tests
// ===================================================================

test "parseThemeTables collects slot KVs" {
    const text =
        \\[theme.heading1]
        \\fg = "#ff0000"
        \\bold = true
        \\prefix = "> "
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tables.slots.len);
    try std.testing.expectEqualStrings("heading1", tables.slots[0].name);
    try std.testing.expectEqual(@as(usize, 3), tables.slots[0].kvs.len);
    // Quotes are stripped so spaces inside the prefix survive.
    try std.testing.expectEqualStrings("fg", tables.slots[0].kvs[0].key);
    try std.testing.expectEqualStrings("#ff0000", tables.slots[0].kvs[0].value);
    try std.testing.expectEqualStrings("> ", tables.slots[0].kvs[2].value);
}

test "parseThemeTables lands top-level [theme] keys in .top" {
    const text =
        \\[theme]
        \\extends = "dark"
        \\palette = "truecolor"
        \\[theme.link]
        \\fg = "#00ff00"
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), tables.top.len);
    try std.testing.expectEqualStrings("extends", tables.top[0].key);
    try std.testing.expectEqualStrings("dark", tables.top[0].value);
    try std.testing.expectEqual(@as(usize, 1), tables.slots.len);
    try std.testing.expectEqualStrings("link", tables.slots[0].name);
}

test "document-root keys before any header land in top-level [theme]" {
    // A theme file IS the [theme] table: a bare top-of-file `extends` must be
    // collected as a top-level key, no explicit [theme] header required.
    const text =
        \\extends = "dracula"
        \\[theme.heading1]
        \\fg = "#ff0000"
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tables.top.len);
    try std.testing.expectEqualStrings("extends", tables.top[0].key);
    try std.testing.expectEqualStrings("dracula", tables.top[0].value);
    try std.testing.expectEqual(@as(usize, 1), tables.slots.len);
    try std.testing.expectEqualStrings("heading1", tables.slots[0].name);
}

test "a non-theme header after root keys turns collection off" {
    const text =
        \\extends = "dracula"
        \\[display]
        \\theme = "dark"
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);
    // Only the root `extends` is a theme key; the [display] value is ignored.
    try std.testing.expectEqual(@as(usize, 1), tables.top.len);
    try std.testing.expectEqualStrings("extends", tables.top[0].key);
    try std.testing.expectEqual(@as(usize, 0), tables.slots.len);
}

test "repeated [theme.link] blocks merge last-wins per key" {
    const text =
        \\[theme.link]
        \\fg = "#111111"
        \\underline = true
        \\[theme.link]
        \\fg = "#222222"
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);

    // One merged slot, not two.
    try std.testing.expectEqual(@as(usize, 1), tables.slots.len);
    try std.testing.expectEqual(@as(usize, 2), tables.slots[0].kvs.len);
    try std.testing.expectEqualStrings("fg", tables.slots[0].kvs[0].key);
    // Last write wins in place.
    try std.testing.expectEqualStrings("#222222", tables.slots[0].kvs[0].value);
    try std.testing.expectEqualStrings("underline", tables.slots[0].kvs[1].key);
}

test "unknown slot name is retained raw, not dropped" {
    // Validation is deferred to S3; the parser keeps whatever slot it sees.
    const text =
        \\[theme.not_a_real_slot]
        \\fg = "#abcdef"
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tables.slots.len);
    try std.testing.expectEqualStrings("not_a_real_slot", tables.slots[0].name);
}

test "non-theme sections are ignored by parseThemeTables" {
    const text =
        \\[display]
        \\theme = "dark"
        \\[theme.strong]
        \\bold = true
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tables.top.len);
    try std.testing.expectEqual(@as(usize, 1), tables.slots.len);
    try std.testing.expectEqualStrings("strong", tables.slots[0].name);
}

test "splitSection splits on first dot; undotted yields empty subtable" {
    const a = splitSection("theme.heading1");
    try std.testing.expectEqualStrings("theme", a.table);
    try std.testing.expectEqualStrings("heading1", a.subtable);

    const b = splitSection("display");
    try std.testing.expectEqualStrings("display", b.table);
    try std.testing.expectEqualStrings("", b.subtable);
}

test "readThemeFile round-trips a temp theme file; missing returns null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "solarized.toml",
        .data =
        \\[theme.heading1]
        \\fg = "#268bd2"
        ,
    });

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var tables = (try readThemeFile(std.testing.allocator, dir_path, "solarized")).?;
    defer tables.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), tables.slots.len);
    try std.testing.expectEqualStrings("heading1", tables.slots[0].name);

    // A name with no file returns null rather than erroring.
    const missing = try readThemeFile(std.testing.allocator, dir_path, "nonexistent");
    try std.testing.expect(missing == null);
}

test "RawThemeBuilder.set merges last-wins and top vs slot separate" {
    var b = RawThemeBuilder{};
    defer b.deinit(std.testing.allocator);

    try b.set(std.testing.allocator, null, "extends", "dark");
    try b.set(std.testing.allocator, "heading1", "fg", "#111");
    try b.set(std.testing.allocator, "heading1", "fg", "#222");

    try std.testing.expectEqual(@as(usize, 1), b.top.items.len);
    try std.testing.expectEqual(@as(usize, 1), b.slots.items.len);
    try std.testing.expectEqual(@as(usize, 1), b.slots.items[0].kvs.items.len);
    try std.testing.expectEqualStrings("#222", b.slots.items[0].kvs.items[0].value);
}
