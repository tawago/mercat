//! Check 4: `@guarded-by: <file> "<test>"` pointer resolution — the anchor
//! for the comment-promotion convention (a why-claim in a comment must name
//! the test that guards it, and a renamed or deleted test must break the
//! build rather than silently orphan the claim).
//!
//! Split out of the tools/lint_imports.zig root; both violation message
//! strings are unchanged by the split.

const std = @import("std");

/// A `test "..."` declaration, keyed by the file basename it lives in.
pub const TestDecl = struct { file: []const u8, name: []const u8 };

/// A `@guarded-by: <file> "<name>"` pointer plus the file it was found in.
pub const GbRef = struct { src: []const u8, file: []const u8, name: []const u8 };

/// @guarded-by targets that live outside the scanned tree (their existence is
/// checked elsewhere): a pointer at a lint rule itself, not at a test.
const gb_external = [_][]const u8{"lint_imports.zig"};

/// Record every container-scope `test "..."` name in `contents` under `file_base`.
pub fn collectTests(
    a: std.mem.Allocator,
    list: *std.ArrayList(TestDecl),
    file_base: []const u8,
    contents: []const u8,
) !void {
    const needle = "test \"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, contents, i, needle)) |start| {
        i = start + needle.len;
        var p = start;
        while (p > 0 and (contents[p - 1] == ' ' or contents[p - 1] == '\t')) p -= 1;
        if (p != 0 and contents[p - 1] != '\n') continue;
        const name_start = start + needle.len;
        const q_close = std.mem.indexOfScalarPos(u8, contents, name_start, '"') orelse break;
        try list.append(a, .{ .file = file_base, .name = contents[name_start..q_close] });
        i = q_close + 1;
    }
}

/// Record every `@guarded-by: <file> "<name>"` pointer in `contents`. The file
/// is reduced to its basename, so a ref may spell a zone-relative path.
pub fn collectGuardedBy(
    a: std.mem.Allocator,
    list: *std.ArrayList(GbRef),
    src: []const u8,
    contents: []const u8,
) !void {
    const needle = "@guarded-by: ";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, contents, i, needle)) |start| {
        const after = start + needle.len;
        const line_end = std.mem.indexOfScalarPos(u8, contents, after, '\n') orelse contents.len;
        i = line_end;
        const q1 = std.mem.indexOfScalarPos(u8, contents, after, '"') orelse continue;
        if (q1 >= line_end) continue;
        const q2 = std.mem.indexOfScalarPos(u8, contents, q1 + 1, '"') orelse continue;
        if (q2 >= line_end) continue;
        var file_tok = std.mem.trim(u8, contents[after..q1], " \t");
        if (std.mem.lastIndexOfScalar(u8, file_tok, '/')) |s| file_tok = file_tok[s + 1 ..];
        try list.append(a, .{ .src = src, .file = file_tok, .name = contents[q1 + 1 .. q2] });
    }
}

/// Flag @guarded-by pointers whose target file or test name cannot be found.
/// Test matching is by basename, so the two `clusters_test.zig` siblings both
/// satisfy a ref that names either — good enough to catch renames/deletions.
pub fn verifyGuardedBy(
    a: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    seen_files: []const []const u8,
    tests: []const TestDecl,
    refs: []const GbRef,
) !void {
    outer: for (refs) |ref| {
        for (gb_external) |ext| if (std.mem.eql(u8, ref.file, ext)) continue :outer;

        var file_seen = false;
        for (seen_files) |sf| {
            if (std.mem.eql(u8, sf, ref.file)) {
                file_seen = true;
                break;
            }
        }
        if (!file_seen) {
            try violations.append(a, try std.fmt.allocPrint(
                a,
                "{s}: @guarded-by target file \"{s}\" not found",
                .{ ref.src, ref.file },
            ));
            continue;
        }

        var test_found = false;
        for (tests) |t| {
            if (std.mem.eql(u8, t.file, ref.file) and std.mem.eql(u8, t.name, ref.name)) {
                test_found = true;
                break;
            }
        }
        if (!test_found) {
            try violations.append(a, try std.fmt.allocPrint(
                a,
                "{s}: @guarded-by test \"{s}\" not found in {s}",
                .{ ref.src, ref.name, ref.file },
            ));
        }
    }
}

test "a @guarded-by pointer at a missing test is reported" {
    const a = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| a.free(v);
        violations.deinit(a);
    }

    const seen = [_][]const u8{"widget_test.zig"};
    const tests = [_]TestDecl{.{ .file = "widget_test.zig", .name = "widget holds its shape" }};
    const refs = [_]GbRef{
        .{ .src = "widget.zig", .file = "widget_test.zig", .name = "widget holds its shape" },
        .{ .src = "widget.zig", .file = "widget_test.zig", .name = "widget holds its old shape" },
        .{ .src = "widget.zig", .file = "gone_test.zig", .name = "widget holds its shape" },
    };

    try verifyGuardedBy(a, &violations, &seen, &tests, &refs);

    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "@guarded-by test \"widget holds its old shape\" not found in widget_test.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[1], "@guarded-by target file \"gone_test.zig\" not found") != null);
}
