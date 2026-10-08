//! Theme names for --list-themes and for "unknown theme" messages.
const std = @import("std");
const presets = @import("../core/theme/presets.zig");
const loadfile = @import("../core/theme/loadfile.zig");
const suggest_mod = @import("../core/suggest.zig");

pub const Names = struct {
    arena: std.heap.ArenaAllocator,
    /// Built-ins first (in preset order), then user themes sorted by name.
    items: []const []const u8,

    pub fn deinit(self: *Names) void {
        self.arena.deinit();
    }

    pub fn contains(self: *const Names, name: []const u8) bool {
        for (self.items) |item| if (std.mem.eql(u8, item, name)) return true;
        return false;
    }

    /// The theme an unknown name most plausibly means ("drakula" -> "dracula").
    pub fn suggest(self: *const Names, name: []const u8) ?[]const u8 {
        return suggest_mod.closest(name, self.items);
    }

    /// "dark, light, …" for messages.
    pub fn joined(self: *Names) []const u8 {
        return std.mem.join(self.arena.allocator(), ", ", self.items) catch "";
    }
};

/// Collects built-in names plus `<stem>` for each `<stem>.toml` in the user
/// themes directory. A missing or unreadable directory contributes nothing.
pub fn collect(allocator: std.mem.Allocator) !Names {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const dir_path = loadfile.resolveThemeDir(a) catch null;
    const items = try collectFrom(a, dir_path);
    return .{ .arena = arena, .items = items };
}

pub fn collectFrom(a: std.mem.Allocator, dir_path: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (presets.ALL) |spec| try list.append(a, spec.name);

    var user: std.ArrayList([]const u8) = .empty;
    if (dir_path) |path| {
        if (openDir(path)) |opened| {
            var dir = opened;
            defer dir.close();
            var it = dir.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
                const stem = entry.name[0 .. entry.name.len - ".toml".len];
                if (stem.len == 0 or isBuiltin(stem)) continue;
                try user.append(a, try a.dupe(u8, stem));
            }
        } else |_| {}
    }
    std.mem.sort([]const u8, user.items, {}, lessThan);
    try list.appendSlice(a, user.items);
    return list.toOwnedSlice(a);
}

fn openDir(path: []const u8) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) return std.fs.openDirAbsolute(path, .{ .iterate = true });
    return std.fs.cwd().openDir(path, .{ .iterate = true });
}

fn isBuiltin(name: []const u8) bool {
    for (presets.ALL) |spec| if (std.mem.eql(u8, spec.name, name)) return true;
    return false;
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

test "collectFrom lists built-ins then sorted user themes, skipping non-toml and duplicates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "zeta.toml", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "alpha.toml", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "dark.toml", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const names = try collectFrom(arena.allocator(), path);

    try std.testing.expectEqual(presets.ALL.len + 2, names.len);
    try std.testing.expectEqualStrings("dark", names[0]);
    try std.testing.expectEqualStrings("alpha", names[presets.ALL.len]);
    try std.testing.expectEqualStrings("zeta", names[presets.ALL.len + 1]);
}

test "collectFrom with no directory lists only built-ins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const names = try collectFrom(arena.allocator(), "/nonexistent/mercat-themes");
    try std.testing.expectEqual(presets.ALL.len, names.len);
}
