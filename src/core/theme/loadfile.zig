//! Stage S1: nested-TOML `[theme.<slot>]` raw table parsing + user theme-file
//! discovery/loading. This module is deliberately "dumb": it collects RAW
//! string key/value pairs per slot with no color/enum interpretation. Typed
//! interpretation (parseColor, glyph validation, extends folding) is S3's job
//! (`theme/resolve.zig`). Keeping the parser interpretation-free keeps it
//! trivially testable and makes the inline-config path and the user-file path
//! share exactly one storage + merge code path (`RawThemeBuilder.set`).

const std = @import("std");

/// One raw, uninterpreted `key = value` pair (both strings owned by the
/// containing builder's allocator).
pub const RawKV = struct { key: []const u8, value: []const u8 };

/// A growable accumulator for `[theme]` / `[theme.<slot>]` tables — the one
/// storage form for raw theme data. The inline config path (`config.zig`)
/// feeds this incrementally line-by-line across multiple `applyTomlLike` calls
/// (default text then user config), and the file path (`parseThemeTables`)
/// fills one from a whole file. Consumers read it through the borrowed
/// `RawThemeTables` view (`view`). `set` implements the locked merge policy:
/// last-wins per key within a slot.
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

    /// Borrow the current contents as an immutable `RawThemeTables` view
    /// (allocation-free, no ownership transfer). The view only stays valid
    /// until the next `set` (which may reallocate the lists), and the strings
    /// it references live exactly as long as the builder.
    pub fn view(self: *const RawThemeBuilder) RawThemeTables {
        return .{ .top = self.top.items, .slots = self.slots.items };
    }
};

/// Immutable, borrowed view of a `RawThemeBuilder` (the resolver-facing
/// handoff form). Owns nothing — per-slot KVs are read via `slot.kvs.items`.
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
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        const decoded = try decodeQuotedString(alloc, value);
        defer alloc.free(decoded);
        try builder.set(alloc, slot, key, decoded);
    } else {
        try builder.set(alloc, slot, key, value);
    }
}

/// Parse a whole theme-file text into a raw builder (read it via `view`).
/// Only `[theme]` / `[theme.<slot>]` sections are collected; any other section
/// is ignored (a user theme file is expected to contain only theme tables, but
/// non-theme noise is tolerated rather than rejected — validation is S3's
/// job). The caller owns the result: `deinit` it, or parse into an arena (the
/// production path — `Registry.loadUserFile` — does the latter).
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

/// The one line/section walker shared by the inline-config path (`config.zig`)
/// and the theme-file path (`applyThemeLines`). It walks TOML-like text and,
/// for each `key = value` line, yields the key/value alongside the current
/// section — both raw (`section`) and split into `(table, subtable)`. Blank
/// lines, `#` comment lines, and `[section]` / `[table.subtable]` headers are
/// consumed silently, as is an inline `# ...` trailer on a value line. Values
/// are otherwise returned verbatim (quotes intact); consumers
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

/// Strip an inline TOML comment from an already-trimmed value: a `#` outside a
/// double-quoted string begins a comment; inside quotes it is literal (so
/// `heading_prefix = "#"` keeps its glyph). Quote tracking is escape-aware — a
/// `\"` inside a string does not end the string and expose a following `#`.
/// Whitespace between the value and the comment is trimmed off.
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

/// Parse a TOML inline array of strings (`["•", "◦", "‣"]`) into an owned slice
/// of element strings (each element is duped into `alloc`, as is the outer
/// slice). Returns null when `value` is not bracketed, so callers can fall back
/// to scalar handling. Splitting is quote- and escape-aware (the same rules
/// `stripInlineComment` uses), so an element may contain a comma or a `#`;
/// each element is decoded with `decodeQuotedString` (quotes stripped, escapes
/// resolved). Empty elements (a trailing comma, `""`, or `[]`) are skipped.
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

/// Strip surrounding quotes and decode the basic TOML escape sequences a string
/// value may contain: \" \\ \n \t \r \uXXXX \UXXXXXXXX. Returns freshly-owned
/// bytes the caller must free. A malformed or unknown escape is kept verbatim
/// (backslash preserved) — this is a deliberately small TOML-like parser, not a
/// validator. Decoded output is never longer than the input (every escape
/// shrinks: \n's two chars -> 1 byte, \uXXXX's six -> at most 3 UTF-8 bytes,
/// \U's ten -> at most 4), so a single input-sized buffer always suffices.
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

/// Decode a `\uXXXX`/`\UXXXXXXXX` escape at the start of `seq` (which points at
/// the leading backslash), writing the UTF-8 encoding into `out`. `digits` is 4
/// or 8. Returns the number of bytes written, or null if the escape is
/// truncated, not valid hex, or not a valid Unicode scalar.
fn decodeUnicodeEscape(seq: []const u8, digits: usize, out: []u8) ?usize {
    if (seq.len < 2 + digits) return null;
    const code = std.fmt.parseInt(u21, seq[2 .. 2 + digits], 16) catch return null;
    return std.unicode.utf8Encode(code, out) catch null;
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

/// Read + parse `<dir>/<name>.toml` into a raw builder (see
/// `parseThemeTables` for ownership). Returns null when the file does not
/// exist; other IO errors propagate.
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
