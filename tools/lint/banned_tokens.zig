//! Check 5: banned tokens. Each row states a zone invariant that is cheaper
//! to state as a token than as an import rule: a symbol that may be defined
//! in exactly one place, a path that must be reached through its named
//! module, an environment read that belongs to one file. Matching is a plain
//! case-sensitive substring scan over the whole file, comments included, so
//! the invariant also holds for prose. POLICY: tokens are FULL identifiers or
//! longer (e.g. "pub fn codepointWidth", "getenv") — never bare word stems.
//! Exemptions are by basename (the matching gb_external uses), via `allow`
//! (everywhere except) or `only` (nowhere except).

const std = @import("std");

pub const Row = struct {
    token: []const u8,
    why: []const u8,
    allow: []const []const u8 = &.{},
    only: []const []const u8 = &.{},
};

pub const table = [_]Row{
    .{
        .token = "pub fn codepointWidth",
        .why = "src/lib/unicode.zig is the Unicode width authority; a codepointWidth may exist there and as the prim entry point in base/types.zig, never as a third table",
        .allow = &.{ "unicode.zig", "types.zig" },
    },
    .{
        .token = "lib/unicode.zig",
        .why = "import the Unicode authority as the named module \"unicode\" so consumers cannot bypass one shared module identity",
        .allow = &.{ "types.zig", "imports.zig", "banned_tokens.zig" },
    },
    .{
        .token = "getenv",
        .why = "entry.zig is the sole env-knob reader in mermaid_v2 (see its header); thread values down as plain parameters",
        .allow = &.{"entry.zig"},
    },
};

fn basenameOf(rel_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, rel_path, std.fs.path.sep)) |s| return rel_path[s + 1 ..];
    return rel_path;
}

fn applies(row: Row, base: []const u8) bool {
    if (row.only.len != 0) {
        for (row.only) |f| if (std.mem.eql(u8, f, base)) return true;
        return false;
    }
    for (row.allow) |f| if (std.mem.eql(u8, f, base)) return false;
    return true;
}

/// One violation per (file, row): the fix is always "remove every occurrence".
/// Reports the 1-based line of the first hit.
pub fn scan(
    a: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    rel_path: []const u8,
    contents: []const u8,
    rows: []const Row,
) !void {
    const base = basenameOf(rel_path);
    for (rows) |row| {
        if (!applies(row, base)) continue;
        const hit = std.mem.indexOf(u8, contents, row.token) orelse continue;
        var line: usize = 1;
        for (contents[0..hit]) |c| {
            if (c == '\n') line += 1;
        }
        try violations.append(a, try std.fmt.allocPrint(
            a,
            "{s}:{d}: banned token \"{s}\": {s}",
            .{ rel_path, line, row.token, row.why },
        ));
    }
}

const testing = std.testing;

/// Collects into a caller-freed list so each test can inspect the messages.
const Collected = struct {
    list: std.ArrayList([]const u8),

    fn deinit(self: *Collected, a: std.mem.Allocator) void {
        for (self.list.items) |v| a.free(v);
        self.list.deinit(a);
    }
};

fn collect(
    a: std.mem.Allocator,
    rel_path: []const u8,
    contents: []const u8,
    rows: []const Row,
) !Collected {
    var out = Collected{ .list = .empty };
    try scan(a, &out.list, rel_path, contents, rows);
    return out;
}

test "banned token: violation names file, 1-based line, token, and why" {
    const a = testing.allocator;
    const rows = [_]Row{.{ .token = "OldName", .why = "renamed to NewName" }};
    var got = try collect(a, "layout/thing.zig", "a\nb OldName", &rows);
    defer got.deinit(a);

    try testing.expectEqual(@as(usize, 1), got.list.items.len);
    const msg = got.list.items[0];
    try testing.expect(std.mem.indexOf(u8, msg, "layout/thing.zig") != null);
    try testing.expect(std.mem.indexOf(u8, msg, ":2:") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "OldName") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "NewName") != null);
}

test "banned token: absent token yields nothing" {
    const a = testing.allocator;
    const rows = [_]Row{.{ .token = "OldName", .why = "renamed to NewName" }};
    var got = try collect(a, "layout/thing.zig", "nothing retired in here\n", &rows);
    defer got.deinit(a);

    try testing.expectEqual(@as(usize, 0), got.list.items.len);
}

test "banned token: allow exempts by basename" {
    const a = testing.allocator;
    const rows = [_]Row{.{
        .token = "OldName",
        .why = "renamed to NewName",
        .allow = &.{"prose.zig"},
    }};

    var exempt = try collect(a, "layout/prose.zig", "OldName", &rows);
    defer exempt.deinit(a);
    try testing.expectEqual(@as(usize, 0), exempt.list.items.len);

    var caught = try collect(a, "layout/other.zig", "OldName", &rows);
    defer caught.deinit(a);
    try testing.expectEqual(@as(usize, 1), caught.list.items.len);
}

test "banned token: only scopes a row to named basenames" {
    const a = testing.allocator;
    const rows = [_]Row{.{
        .token = "OldName",
        .why = "renamed to NewName",
        .only = &.{"lanes.zig"},
    }};

    var base_hit = try collect(a, "base/lanes.zig", "OldName", &rows);
    defer base_hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), base_hit.list.items.len);

    var layout_hit = try collect(a, "layout/lanes.zig", "OldName", &rows);
    defer layout_hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), layout_hit.list.items.len);

    var miss = try collect(a, "layout/back_edges.zig", "OldName", &rows);
    defer miss.deinit(a);
    try testing.expectEqual(@as(usize, 0), miss.list.items.len);
}

test "banned token: repeated occurrences report once per file" {
    const a = testing.allocator;
    const rows = [_]Row{.{ .token = "OldName", .why = "renamed to NewName" }};
    var got = try collect(a, "layout/thing.zig", "OldName\nOldName\nOldName\n", &rows);
    defer got.deinit(a);

    try testing.expectEqual(@as(usize, 1), got.list.items.len);
    try testing.expect(std.mem.indexOf(u8, got.list.items[0], ":1:") != null);
}

test "banned token: an env read outside entry.zig fires, and entry.zig is exempt" {
    const a = testing.allocator;
    var hit = try collect(a, "layout/thing.zig", "const v = std.posix.getenv(\"MERCAT_X\");\n", &table);
    defer hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), hit.list.items.len);
    try testing.expect(std.mem.indexOf(u8, hit.list.items[0], "entry.zig is the sole env-knob reader") != null);

    var exempt = try collect(a, "entry.zig", "const v = std.posix.getenv(\"MERCAT_X\");\n", &table);
    defer exempt.deinit(a);
    try testing.expectEqual(@as(usize, 0), exempt.list.items.len);
}

test "banned token: a third codepointWidth table fires, the two authorities are exempt" {
    const a = testing.allocator;
    var hit = try collect(a, "raster/labels.zig", "pub fn codepointWidth(cp: u21) u32 {\n", &table);
    defer hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), hit.list.items.len);

    var prim = try collect(a, "base/types.zig", "pub fn codepointWidth(cp: u21) u32 {\n", &table);
    defer prim.deinit(a);
    try testing.expectEqual(@as(usize, 0), prim.list.items.len);
}

test "banned token: production table is well-formed" {
    for (table) |row| {
        try testing.expect(row.token.len >= 4);
        try testing.expect(row.why.len != 0);
        try testing.expect(row.allow.len == 0 or row.only.len == 0);
    }
}
