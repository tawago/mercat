const std = @import("std");

const imports = @import("lint/imports.zig");
const gb = @import("lint/guarded_by.zig");
const banned = @import("lint/vocabulary.zig");
const TestDecl = gb.TestDecl;
const GbRef = gb.GbRef;

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

    var test_decls: std.ArrayList(TestDecl) = .empty;
    var gb_refs: std.ArrayList(GbRef) = .empty;
    var seen_files: std.ArrayList([]const u8) = .empty;

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

        if (!isTestFile(entry.basename)) {
            const code_lines = codeLines(contents);
            if (code_lines > 500) {
                const msg = try std.fmt.allocPrint(a, "{s}: {d} code lines exceeds the 500-code-line cap (blank and // lines are free)", .{ entry.path, code_lines });
                try violations.append(a, msg);
            }
        }

        try banned.scan(a, &violations, entry.path, contents, &banned.table);

        try imports.scanImports(a, &violations, entry.path, contents);

        const base_owned = try a.dupe(u8, entry.basename);
        try seen_files.append(a, base_owned);
        try gb.collectTests(a, &test_decls, base_owned, contents);
        try gb.collectGuardedBy(a, &gb_refs, try a.dupe(u8, entry.path), contents);
    }

    try gb.verifyGuardedBy(a, &violations, seen_files.items, test_decls.items, gb_refs.items);

    return LintReport{ .violations = try violations.toOwnedSlice(a), .arena = arena_ptr };
}

fn codeLines(contents: []const u8) usize {
    var count: usize = 0;
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        count += 1;
    }
    return count;
}

fn isTestFile(basename: []const u8) bool {
    return std.mem.indexOf(u8, basename, "_test") != null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const root: []const u8 = if (args.len >= 2) args[1] else "src/core/mermaid_v2";

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

    var saw_big = false;
    var saw_fallback = false;
    var saw_banned = false;
    for (report.violations) |v| {
        if (std.mem.indexOf(u8, v, "big_file.zig") != null) saw_big = true;
        if (std.mem.indexOf(u8, v, "dummy.zig") != null and std.mem.indexOf(u8, v, "fallback") != null) saw_fallback = true;
        if (std.mem.indexOf(u8, v, "banned.zig") != null and std.mem.indexOf(u8, v, "codepointWidth") != null) saw_banned = true;
    }
    try std.testing.expect(report.violations.len >= 3);
    try std.testing.expect(saw_big);
    try std.testing.expect(saw_fallback);
    try std.testing.expect(saw_banned);
}

test "code lines: blank and //-prefixed lines are free, indentation and CR are ignored" {
    try std.testing.expectEqual(@as(usize, 0), codeLines(""));
    try std.testing.expectEqual(@as(usize, 1), codeLines("const x = 1;"));
    try std.testing.expectEqual(@as(usize, 2), codeLines("//! doc\n\nconst x = 1;\n    // note\n\t/// doc\r\n  const y = 2;\n\r\n"));
}

test "the cap exempts *_test*.zig and nothing else" {
    try std.testing.expect(isTestFile("widget_test.zig"));
    try std.testing.expect(isTestFile("widget_test2.zig"));
    try std.testing.expect(isTestFile("layout_test_helpers.zig"));
    try std.testing.expect(!isTestFile("widget.zig"));
    try std.testing.expect(!isTestFile("latest.zig"));
    try std.testing.expect(!isTestFile("testing.zig"));
}

test {
    _ = imports;
    _ = gb;
    _ = banned;
}
