//! Import-boundary, file-size, and no-fallback linter for src/core/mermaid_v2/.
//!
//! Run via `zig build lint`. Walks the root directory recursively, reads every
//! `.zig` file, and checks:
//!   1. ≤ 500 newlines per file.
//!   2. No path component equals "fallback".
//!   3. Per-file `@import("...")` rules (tools/lint/imports.zig).
//!   4. Every `guarded-by: <file> "<test>"` pointer (preferred spelling
//!      `@guarded-by:`) resolves to a real test declaration somewhere in the
//!      tree (anchors the comment-promotion convention so a renamed/deleted
//!      test breaks the build, not silently; tools/lint/guarded_by.zig).
//!   5. No banned token (zone invariants; tools/lint/banned_tokens.zig).
//!
//! Exits 0 on success, 1 on any violation, 2 on I/O / missing-root errors.
//!
//! This root file owns the walk, the line cap, the fallback-path check, and
//! `main`; each per-check engine lives in a `tools/lint/` sibling. The
//! filename is load-bearing: guarded-by pointers may name it as an external
//! target (see `gb_external`).

const std = @import("std");

const imports = @import("lint/imports.zig");
const gb = @import("lint/guarded_by.zig");
const banned = @import("lint/banned_tokens.zig");
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

/// Walk `root` recursively and produce a report of every lint violation.
pub fn lint(allocator: std.mem.Allocator, root: []const u8) !LintReport {
    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    const a = arena_ptr.allocator();

    var violations: std.ArrayList([]const u8) = .empty;

    // Check 4 accumulators, cross-checked after the walk. Every slice below
    // points into arena-owned storage (file contents are never freed mid-walk),
    // so they stay valid until the report is deinit'd.
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

        // Check 2: no "fallback" component.
        var it = std.mem.tokenizeScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |comp| {
            if (std.mem.eql(u8, comp, "fallback")) {
                const msg = try std.fmt.allocPrint(a, "{s}: forbidden 'fallback/' path component", .{entry.path});
                try violations.append(a, msg);
                break;
            }
        }

        // Read the file.
        const file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();
        const contents = try file.readToEndAlloc(a, 8 * 1024 * 1024);

        // Check 1: 500-line cap (count newlines).
        var newlines: usize = 0;
        for (contents) |c| {
            if (c == '\n') newlines += 1;
        }
        if (newlines > 500) {
            const msg = try std.fmt.allocPrint(a, "{s}: {d} newlines exceeds 500-line cap", .{ entry.path, newlines });
            try violations.append(a, msg);
        }

        // Check 5: banned tokens.
        try banned.scan(a, &violations, entry.path, contents, &banned.table);

        // Check 3: import boundaries.
        try imports.scanImports(a, &violations, entry.path, contents);

        // Check 4: collect test declarations and guarded-by pointers.
        const base_owned = try a.dupe(u8, entry.basename);
        try seen_files.append(a, base_owned);
        try gb.collectTests(a, &test_decls, base_owned, contents);
        try gb.collectGuardedBy(a, &gb_refs, try a.dupe(u8, entry.path), contents);
    }

    try gb.verifyGuardedBy(a, &violations, seen_files.items, test_decls.items, gb_refs.items);

    return LintReport{ .violations = try violations.toOwnedSlice(a), .arena = arena_ptr };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const root: []const u8 = if (args.len >= 2) args[1] else "src/core/mermaid_v2";

    // Probe root before walking to give a clean exit-2 error.
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

test {
    _ = imports;
    _ = gb;
    _ = banned;
}
