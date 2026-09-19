const std = @import("std");

pub const TestDecl = struct { file: []const u8, name: []const u8 };

pub const GbRef = struct { src: []const u8, file: []const u8, name: []const u8 };

const gb_external = [_][]const u8{"lint_imports.zig"};

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

pub fn collectGuardedBy(
    a: std.mem.Allocator,
    list: *std.ArrayList(GbRef),
    src: []const u8,
    contents: []const u8,
) !void {
    const needle = "guarded-by: ";
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
                "{s}: guarded-by target file \"{s}\" not found",
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
                "{s}: guarded-by test \"{s}\" not found in {s}",
                .{ ref.src, ref.name, ref.file },
            ));
        }
    }
}

test "a guarded-by pointer at a missing test is reported" {
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
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "guarded-by test \"widget holds its old shape\" not found in widget_test.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[1], "guarded-by target file \"gone_test.zig\" not found") != null);
}

test "both guarded-by spellings are collected and the file is reduced to its basename" {
    const a = std.testing.allocator;
    var refs: std.ArrayList(GbRef) = .empty;
    defer refs.deinit(a);

    const src =
        "/// guarded-by: widget_test.zig \"widget holds its shape\"\n" ++
        "/// @guarded-by: layout/widget_test.zig \"widget holds its shape\"\n" ++
        "/// guarded-by: no quotes on this line\n";
    try collectGuardedBy(a, &refs, "widget.zig", src);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqualStrings("widget_test.zig", refs.items[0].file);
    try std.testing.expectEqualStrings("widget_test.zig", refs.items[1].file);
    try std.testing.expectEqualStrings("widget holds its shape", refs.items[1].name);
}
