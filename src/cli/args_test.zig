const std = @import("std");
const config = @import("../core/config.zig");
const args = @import("args.zig");

const parse = args.parse;
const parseDiag = args.parseDiag;
const Parsed = args.Parsed;

/// Parses `argv` and compares every field of the result with `want`.
fn expectParsed(argv: []const []const u8, want: Parsed) !void {
    const got = try parse(std.testing.allocator, argv);
    defer got.deinit(std.testing.allocator);
    inline for (std.meta.fields(Parsed)) |f| {
        const w = @field(want, f.name);
        const g = @field(got, f.name);
        switch (@TypeOf(w)) {
            ?[]const u8, ?[]u8 => {
                try std.testing.expectEqual(w == null, g == null);
                if (w) |s| try std.testing.expectEqualStrings(s, g.?);
            },
            args.Input => {
                try std.testing.expectEqual(std.meta.activeTag(w), std.meta.activeTag(g));
                if (w.filePath()) |p| try std.testing.expectEqualStrings(p, g.filePath().?);
            },
            else => try std.testing.expectEqual(w, g),
        }
    }
}

const ParseRow = struct { argv: []const []const u8, want: Parsed };
const x_md: args.Input = .{ .file = "x.md" };

test "every flag_table row parses into its field" {
    for ([_][]const u8{ "--help", "-h" }) |a| {
        try std.testing.expectError(error.ShowHelp, parse(std.testing.allocator, &.{ "mercat", a }));
    }
    for ([_][]const u8{ "--version", "-v", "-V" }) |a| {
        try std.testing.expectError(error.ShowVersion, parse(std.testing.allocator, &.{ "mercat", a }));
    }
    const out: ?[]u8 = @constCast("out.txt");
    const rows = [_]ParseRow{
        .{ .argv = &.{ "mercat", "--pager", "x.md" }, .want = .{ .input = x_md, .pager = true } },
        .{ .argv = &.{ "mercat", "-p", "x.md" }, .want = .{ .input = x_md, .pager = true } },
        .{ .argv = &.{ "mercat", "--tui", "x.md" }, .want = .{ .input = x_md, .mode = .tui } },
        .{ .argv = &.{ "mercat", "-t", "x.md" }, .want = .{ .input = x_md, .mode = .tui } },
        .{ .argv = &.{ "mercat", "--width", "88", "x.md" }, .want = .{ .input = x_md, .width = 88 } },
        .{ .argv = &.{ "mercat", "-w", "88", "x.md" }, .want = .{ .input = x_md, .width = 88 } },
        .{ .argv = &.{ "mercat", "--theme", "dark", "x.md" }, .want = .{ .input = x_md, .style = "dark" } },
        .{ .argv = &.{ "mercat", "--style", "dracula", "x.md" }, .want = .{ .input = x_md, .style = "dracula" } },
        .{ .argv = &.{ "mercat", "--dump-theme", "dracula" }, .want = .{ .dump_theme = "dracula" } },
        .{ .argv = &.{ "mercat", "--list-themes" }, .want = .{ .list_themes = true } },
        .{ .argv = &.{ "mercat", "--color", "always", "x.md" }, .want = .{ .input = x_md, .color = .always } },
        .{ .argv = &.{ "mercat", "--heading-markers", "x.md" }, .want = .{ .input = x_md, .heading_markers = true } },
        .{ .argv = &.{ "mercat", "--no-heading-markers", "x.md" }, .want = .{ .input = x_md, .heading_markers = false } },
        .{ .argv = &.{ "mercat", "--frontmatter", "compact", "x.md" }, .want = .{ .input = x_md, .frontmatter = .compact } },
        .{ .argv = &.{ "mercat", "--format", "plain", "x.md" }, .want = .{ .input = x_md, .format = .plain } },
        .{ .argv = &.{ "mercat", "--format", "plain", "--output", "out.txt", "x.md" }, .want = .{ .input = x_md, .format = .plain, .output_path = out } },
        .{ .argv = &.{ "mercat", "--format", "plain", "-o", "out.txt", "x.md" }, .want = .{ .input = x_md, .format = .plain, .output_path = out } },
        .{ .argv = &.{ "mercat", "--format", "png", "-o", "out.txt", "--monochrome", "x.md" }, .want = .{ .input = x_md, .format = .png, .output_path = out, .monochrome = true } },
        .{ .argv = &.{ "mercat", "--box-style", "rounded", "x.md" }, .want = .{ .input = x_md, .box_style = .rounded } },
        .{ .argv = &.{ "mercat", "--layout", "tree", "x.md" }, .want = .{ .input = x_md, .force_layout = .tree } },
        .{ .argv = &.{ "mercat", "--force-layout", "tree", "x.md" }, .want = .{ .input = x_md, .force_layout = .tree } },
        .{ .argv = &.{ "mercat", "--crossing-heuristic", "barycenter", "x.md" }, .want = .{ .input = x_md, .crossing_heuristic = .barycenter } },
        .{ .argv = &.{ "mercat", "--aspect-ratio", "2.5", "x.md" }, .want = .{ .input = x_md, .aspect_ratio = 2.5 } },
        .{ .argv = &.{ "mercat", "--debug-mermaid", "x.md" }, .want = .{ .input = x_md, .debug_mermaid = true } },
    };
    for (rows) |row| try expectParsed(row.argv, row.want);

    // Every spelling in flag_table, aliases included, has a row above.
    const shown = [_][]const u8{ "--help", "-h", "--version", "-v", "-V" };
    for (args.flag_table) |spec| {
        var seen = false;
        for (shown) |a| seen = seen or std.mem.eql(u8, a, spec.name);
        for (rows) |row| for (row.argv) |a| {
            seen = seen or std.mem.eql(u8, a, spec.name);
        };
        if (!seen) std.debug.print("flag_table row without a test: {s}\n", .{spec.name});
        try std.testing.expect(seen);
    }
}

test "argument syntax forms" {
    const out: ?[]u8 = @constCast("out.txt");
    const rows = [_]ParseRow{
        .{ .argv = &.{"mercat"}, .want = .{} },
        .{ .argv = &.{ "mercat", "-" }, .want = .{ .input = .stdin } },
        .{ .argv = &.{ "mercat", "--width=80", "--theme=light", "--frontmatter=dim", "--color=never", "x.md" }, .want = .{ .input = x_md, .width = 80, .style = "light", .frontmatter = .dim, .color = .never } },
        .{ .argv = &.{ "mercat", "--style=pink", "--force-layout=tree", "x.md" }, .want = .{ .input = x_md, .style = "pink", .force_layout = .tree } },
        .{ .argv = &.{ "mercat", "--format=plain", "--output=out.txt", "x.md" }, .want = .{ .input = x_md, .format = .plain, .output_path = out } },
        .{ .argv = &.{ "mercat", "-w80", "--format", "plain", "-oout.txt", "x.md" }, .want = .{ .input = x_md, .width = 80, .format = .plain, .output_path = out } },
        .{ .argv = &.{ "mercat", "-pw", "40", "x.md" }, .want = .{ .input = x_md, .pager = true, .width = 40 } },
    };
    for (rows) |row| try expectParsed(row.argv, row.want);
    // Bundled no-value flags are still separate options.
    try std.testing.expectError(error.IncompatibleModes, parse(std.testing.allocator, &.{ "mercat", "-pt", "x.md" }));
    // Other parse errors keep their short-option wording.
    var note_buf: [64]u8 = undefined;
    const empty: args.Diagnostic = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), args.describeNote(&note_buf, error.UnknownFlag, &empty));
}

test "message: --monochrome without --format png is a usage error" {
    try expectMessage(&.{ "mercat", "--monochrome", "in.md" }, error.MonochromeRequiresPng, "'--monochrome' only applies to --format png");
    try expectMessage(&.{ "mercat", "--format", "plain", "--monochrome", "in.md" }, error.MonochromeRequiresPng, "'--monochrome' only applies to --format png");
}

test "message: an empty -o value is a usage error" {
    try expectMessage(&.{ "mercat", "--format", "plain", "-o", "", "in.md" }, error.EmptyOutputPath, "option '-o' needs a non-empty file name");
    try expectMessage(&.{ "mercat", "--format", "png", "--output=", "in.md" }, error.EmptyOutputPath, "option '--output' needs a non-empty file name");
}

fn expectSingleDash(argv: []const []const u8, option: []const u8, long: []const u8) !void {
    var d: args.Diagnostic = .{};
    try std.testing.expectError(error.SingleDashLongOption, parseDiag(std.testing.allocator, argv, &d));
    var buf: [128]u8 = undefined;
    var msg_buf: [128]u8 = undefined;
    const want = try std.fmt.bufPrint(&msg_buf, "unknown option '{s}'", .{option});
    try std.testing.expectEqualStrings(want, args.describe(&buf, error.SingleDashLongOption, &d));
    const note_want = try std.fmt.bufPrint(&msg_buf, "did you mean '{s}'?", .{long});
    try std.testing.expectEqualStrings(note_want, args.describeNote(&buf, error.SingleDashLongOption, &d).?);
}

test "single-dash long options get a did-you-mean instead of short-cluster errors" {
    try expectSingleDash(&.{ "mercat", "-width", "80", "x.md" }, "-width", "--width");
    // Not "-o utput": no stray file named "utput" is written.
    try expectSingleDash(&.{ "mercat", "--format", "plain", "-output", "x", "y.md" }, "-output", "--output");
    try expectSingleDash(&.{ "mercat", "-theme=dark", "x.md" }, "-theme", "--theme");
    try expectSingleDash(&.{ "mercat", "-out", "x" }, "-out", "--output");
}

test "prescanColor finds the last valid --color before '--'" {
    try std.testing.expectEqual(@as(?args.ColorMode, .never), args.prescanColor(&.{ "mercat", "--bogus", "--color=never" }));
    try std.testing.expectEqual(@as(?args.ColorMode, .never), args.prescanColor(&.{ "mercat", "--color", "always", "--color", "never" }));
    try std.testing.expectEqual(@as(?args.ColorMode, .always), args.prescanColor(&.{ "mercat", "--color=always", "--color=bad" }));
    try std.testing.expectEqual(@as(?args.ColorMode, null), args.prescanColor(&.{ "mercat", "--", "--color=never" }));
    try std.testing.expectEqual(@as(?args.ColorMode, null), args.prescanColor(&.{ "mercat", "--color" }));
}

test "width resolution: -w 0 means the export default for plain/png" {
    var parsed = Parsed{ .width = 60 };
    try std.testing.expectEqual(@as(usize, 60), parsed.nonTerminalWidth(90));
    parsed = Parsed{};
    try std.testing.expectEqual(@as(usize, 90), parsed.nonTerminalWidth(90));
    try std.testing.expectEqual(@as(usize, 120), parsed.nonTerminalWidth(0));
    parsed = Parsed{ .width = 0 };
    try std.testing.expectEqual(@as(usize, 120), parsed.nonTerminalWidth(90));
    try std.testing.expectEqual(@as(usize, 0), parsed.effectiveWidth(90));
}

// ---- Messages: golden strings for usage errors ----

fn expectMessage(argv: []const []const u8, expected_err: args.ParseError, expected: []const u8) !void {
    var d: args.Diagnostic = .{};
    const result = parseDiag(std.testing.allocator, argv, &d);
    if (result) |parsed| {
        parsed.deinit(std.testing.allocator);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(expected_err, err);
        var buf: [512]u8 = undefined;
        try std.testing.expectEqualStrings(expected, args.describe(&buf, err, &d));
        try std.testing.expect(args.isUsageError(err));
    }
}

test "message: unknown option with did-you-mean" {
    try expectMessage(&.{ "mercat", "--widht", "80" }, error.UnknownFlag, "unknown option '--widht' (did you mean '--width'?)");
    try expectMessage(&.{ "mercat", "--out", "x" }, error.UnknownFlag, "unknown option '--out' (did you mean '--output'?)");
}

test "message: unknown option without a close match has no suggestion" {
    try expectMessage(&.{ "mercat", "--bogus-thing" }, error.UnknownFlag, "unknown option '--bogus-thing'");
    try expectMessage(&.{ "mercat", "-x" }, error.UnknownFlag, "unknown option '-x'");
}

test "message: missing option argument" {
    try expectMessage(&.{ "mercat", "--format" }, error.MissingValue, "option '--format' requires an argument");
    try expectMessage(&.{ "mercat", "-w" }, error.MissingValue, "option '-w' requires an argument");
}

test "message: flag that takes no value given one with =" {
    try expectMessage(&.{ "mercat", "--pager=yes", "x.md" }, error.UnexpectedValue, "option '--pager' does not take an argument");
}

test "message: invalid enum values list every valid one" {
    try expectMessage(&.{ "mercat", "--format", "svg", "x.md" }, error.InvalidFormat, "invalid value 'svg' for '--format' (expected one of: terminal, plain, png)");
    try expectMessage(&.{ "mercat", "--aspect-ratio", "-1" }, error.InvalidAspectRatio, "invalid value '-1' for '--aspect-ratio' (expected a positive number, e.g. 2.0)");
    const cases = .{
        .{ "--format", error.InvalidFormat, args.OutputFormat },
        .{ "--frontmatter", error.InvalidFrontmatterStyle, config.FrontmatterStyle },
        .{ "--box-style", error.InvalidBoxStyle, args.BoxDrawingStyle },
        .{ "--layout", error.InvalidLayout, args.ForceLayout },
        .{ "--crossing-heuristic", error.InvalidCrossingHeuristic, args.CrossingReductionHeuristic },
        .{ "--color", error.InvalidColor, args.ColorMode },
    };
    inline for (cases) |case| {
        var d: args.Diagnostic = .{};
        try std.testing.expectError(case[1], parseDiag(std.testing.allocator, &.{ "mercat", case[0], "zz", "x.md" }, &d));
        var buf: [512]u8 = undefined;
        const msg = args.describe(&buf, case[1], &d);
        inline for (comptime std.meta.fieldNames(case[2])) |name| {
            if (std.mem.indexOf(u8, msg, name) == null) {
                std.debug.print("'{s}' missing from: {s}\n", .{ name, msg });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "message: width outside 0 or 20..1000 names the range" {
    try expectMessage(&.{ "mercat", "--width=5" }, error.InvalidWidth, "invalid width '5' for '--width' (expected 0 for auto, or 20..1000)");
}

test "message: conflicting options" {
    try expectMessage(&.{ "mercat", "-p", "-t", "x.md" }, error.IncompatibleModes, "'-p' and '-t' cannot be used together");
    try expectMessage(&.{ "mercat", "--tui", "--pager", "x.md" }, error.IncompatibleModes, "'--pager' and '--tui' cannot be used together");
    try expectMessage(&.{ "mercat", "-t", "--format", "plain", "x.md" }, error.FormatRequiresCliMode, "'-t' cannot be used with --format plain");
    try expectMessage(&.{ "mercat", "--format", "png", "-o", "o.png", "-p", "x.md" }, error.PngWithPager, "'-p' cannot be used with --format png");
}

test "message: multiple inputs" {
    try expectMessage(&.{ "mercat", "a.md", "b.md" }, error.MultipleInputs, "more than one input given ('a.md' and 'b.md'); mercat renders one file at a time");
    try expectMessage(&.{ "mercat", "-", "b.md" }, error.MultipleInputs, "more than one input given ('-' and 'b.md'); mercat renders one file at a time");
}

test "message: png without -o and -o without an export format" {
    try expectMessage(&.{ "mercat", "--format", "png", "x.md" }, error.PngRequiresOutput, "--format png needs an output file; add -o <file>.png");
    try expectMessage(&.{ "mercat", "-o", "out.txt", "x.md" }, error.TerminalWithOutput, "-o needs --format plain or --format png (terminal output goes to stdout)");
}

// ---- Argument syntax ----

test "'--' ends options so dash-leading file names work" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, &.{ "mercat", "-w", "80", "--", "-weird.md" });
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("-weird.md", parsed.input.file);

    const dash = try parse(allocator, &.{ "mercat", "--", "-" });
    defer dash.deinit(allocator);
    try std.testing.expectEqualStrings("-", dash.input.file);
}

// ---- Width ----

test "width accepts 0 and 20..1000 only" {
    for ([_][]const u8{ "0", "20", "80", "1000" }) |ok| {
        _ = try args.parseWidth(ok);
    }
    for ([_][]const u8{ "1", "19", "1001", "-3", "", "8x" }) |bad| {
        try std.testing.expectError(error.InvalidWidth, args.parseWidth(bad));
    }
}
