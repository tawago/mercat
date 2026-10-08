const std = @import("std");

const imports = @import("lint/imports.zig");
const banned = @import("lint/vocabulary.zig");
const cycles = @import("lint/cycles.zig");

pub const LintReport = struct {
    violations: []const []const u8,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *LintReport) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub fn lint(allocator: std.mem.Allocator, root: []const u8) !LintReport {
    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    const a = arena_ptr.allocator();

    var violations: std.ArrayList([]const u8) = .empty;

    var production: std.ArrayList(cycles.Source) = .empty;

    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
        const msg = try std.fmt.allocPrint(a, "error: cannot open root '{s}': {s}", .{ root, @errorName(err) });
        try violations.append(a, msg);
        return LintReport{ .violations = try violations.toOwnedSlice(a), .arena = arena_ptr };
    };
    defer dir.close();

    var walker = try dir.walk(a);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        var it = std.mem.tokenizeScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |comp| {
            if (std.mem.eql(u8, comp, "fallback")) {
                const msg = try std.fmt.allocPrint(a, "{s}: forbidden 'fallback/' path component", .{entry.path});
                try violations.append(a, msg);
                break;
            }
        }

        const file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();
        const contents = try file.readToEndAlloc(a, 8 * 1024 * 1024);

        if (!imports.isTestFile(entry.basename)) {
            try production.append(a, .{ .path = try a.dupe(u8, entry.path), .contents = contents });
        }

        try banned.scan(a, &violations, entry.path, contents, &banned.table);

        try imports.scanImports(a, &violations, entry.path, contents);
    }

    try cycles.check(a, &violations, production.items);

    return LintReport{ .violations = try violations.toOwnedSlice(a), .arena = arena_ptr };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const root: []const u8 = if (args.len >= 2) args[1] else "src/core/mermaid/flowchart";

    {
        var probe = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
            std.debug.print("lint: cannot open root '{s}': {s}\n", .{ root, @errorName(err) });
            std.process.exit(2);
        };
        probe.close();
    }

    var report = try lint(allocator, root);
    defer report.deinit();

    if (report.violations.len == 0) {
        std.process.exit(0);
    }

    for (report.violations) |v| std.debug.print("{s}\n", .{v});
    std.process.exit(1);
}

test "lint flags bad fixtures" {
    const allocator = std.testing.allocator;
    var report = try lint(allocator, "tools/lint_fixtures/bad");
    defer report.deinit();

    var saw_fallback = false;
    var saw_banned = false;
    var saw_cycle = false;
    for (report.violations) |v| {
        if (std.mem.indexOf(u8, v, "dummy.zig") != null and std.mem.indexOf(u8, v, "fallback") != null) saw_fallback = true;
        if (std.mem.indexOf(u8, v, "banned.zig") != null and std.mem.indexOf(u8, v, "codepointWidth") != null) saw_banned = true;
        if (std.mem.indexOf(u8, v, "import cycle among 2 files: cycle_a.zig, cycle_b.zig") != null) saw_cycle = true;
    }
    try std.testing.expect(report.violations.len >= 3);
    try std.testing.expect(saw_fallback);
    try std.testing.expect(saw_banned);
    try std.testing.expect(saw_cycle);
}

test {
    _ = imports;
    _ = banned;
    _ = cycles;
}
