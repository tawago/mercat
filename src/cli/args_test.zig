const std = @import("std");
const config = @import("../core/config.zig");
const args = @import("args.zig");

const parse = args.parse;
const parseDiag = args.parseDiag;
const Parsed = args.Parsed;
const Mode = args.Mode;
const OutputFormat = args.OutputFormat;
const Input = args.Input;

test "parses cli arguments" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--style", "dark", "-w", "88", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(Mode.cli, parsed.mode);
    try std.testing.expectEqual(@as(?usize, 88), parsed.width);
    try std.testing.expectEqualStrings("dark", parsed.style.?);
    try std.testing.expectEqualStrings("README.md", parsed.input.file);
}

test "--dump-theme captures the theme name" {
    const argv = [_][]const u8{ "mercat", "--dump-theme", "dracula" };
    const parsed = try parse(std.testing.allocator, &argv);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dracula", parsed.dump_theme.?);
}

test "--dump-theme without a value errors" {
    const argv = [_][]const u8{ "mercat", "--dump-theme" };
    try std.testing.expectError(error.MissingValue, parse(std.testing.allocator, &argv));
}

test "--style accepts any name; validation is deferred to the registry" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--style", "dracula", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("dracula", parsed.style.?);
    try std.testing.expectEqualStrings("dracula", parsed.effectiveTheme("light"));
    try std.testing.expectEqualStrings("light", (Parsed{}).effectiveTheme("light"));
}

test "supports heading marker override" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--no-heading-markers", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(?bool, false), parsed.heading_markers);
}

test "parses frontmatter style flag and rejects invalid values" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--frontmatter", "compact", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(config.FrontmatterStyle.compact, parsed.frontmatter.?);
    try std.testing.expectEqual(config.FrontmatterStyle.compact, parsed.effectiveFrontmatter(.panel));
    try std.testing.expectEqual(config.FrontmatterStyle.dim, (Parsed{}).effectiveFrontmatter(.dim));

    const bad = [_][]const u8{ "mercat", "--frontmatter", "table", "README.md" };
    try std.testing.expectError(error.InvalidFrontmatterStyle, parse(allocator, &bad));
}

test "frontmatter: missing value at end of argv errors MissingValue" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--frontmatter" };
    try std.testing.expectError(error.MissingValue, parse(allocator, &argv));
}

test "frontmatter: accepts every valid style spelling" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { text: []const u8, style: config.FrontmatterStyle }{
        .{ .text = "panel", .style = .panel },
        .{ .text = "dim", .style = .dim },
        .{ .text = "compact", .style = .compact },
        .{ .text = "raw", .style = .raw },
        .{ .text = "hidden", .style = .hidden },
    };
    for (cases) |case| {
        const argv = [_][]const u8{ "mercat", "--frontmatter", case.text, "README.md" };
        const parsed = try parse(allocator, &argv);
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(case.style, parsed.frontmatter.?);
    }
}

test "frontmatter: effectiveFrontmatter honors config when flag absent and flag wins when present" {
    const styles = [_]config.FrontmatterStyle{ .panel, .dim, .compact, .raw, .hidden };
    for (styles) |style| {
        try std.testing.expectEqual(style, (Parsed{}).effectiveFrontmatter(style));
    }
    const with_flag = Parsed{ .frontmatter = .hidden };
    for (styles) |config_value| {
        try std.testing.expectEqual(config.FrontmatterStyle.hidden, with_flag.effectiveFrontmatter(config_value));
    }
}

test "rejects pager plus tui" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "-p", "-t", "README.md" };
    try std.testing.expectError(error.IncompatibleModes, parse(allocator, &argv));
}

test "falls back to default width" {
    const parsed = Parsed{};
    try std.testing.expectEqual(@as(usize, 0), parsed.effectiveWidth(0));
    try std.testing.expectEqual(@as(usize, 92), parsed.effectiveWidth(92));
}

test "defaults to terminal format" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(OutputFormat.terminal, parsed.format);
    try std.testing.expectEqual(@as(?[]u8, null), parsed.output_path);
    try std.testing.expectEqual(false, parsed.monochrome);
}

test "parses plain format with output path and monochrome" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "plain", "-o", "out.txt", "--monochrome", "in.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(OutputFormat.plain, parsed.format);
    try std.testing.expectEqualStrings("out.txt", parsed.output_path.?);
    try std.testing.expectEqual(true, parsed.monochrome);
}

test "parses png format with long output flag" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "png", "--output", "out.png", "in.mmd" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(OutputFormat.png, parsed.format);
    try std.testing.expectEqualStrings("out.png", parsed.output_path.?);
}

test "rejects invalid format value" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "svg", "in.md" };
    try std.testing.expectError(error.InvalidFormat, parse(allocator, &argv));
}

test "rejects missing format value" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format" };
    try std.testing.expectError(error.MissingValue, parse(allocator, &argv));
}

test "rejects png without output" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "png", "in.mmd" };
    try std.testing.expectError(error.PngRequiresOutput, parse(allocator, &argv));
}

test "rejects png with pager" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "png", "-o", "out.png", "-p", "in.mmd" };
    try std.testing.expectError(error.PngWithPager, parse(allocator, &argv));
}

test "rejects tui with plain format" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "-t", "--format", "plain", "." };
    try std.testing.expectError(error.FormatRequiresCliMode, parse(allocator, &argv));
}

test "rejects tui with png format" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "png", "-o", "out.png", "-t", "." };
    try std.testing.expectError(error.FormatRequiresCliMode, parse(allocator, &argv));
}

test "rejects terminal format with output" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "-o", "out.txt", "in.md" };
    try std.testing.expectError(error.TerminalWithOutput, parse(allocator, &argv));
}

test "accepts monochrome with terminal format" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--monochrome", "in.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(OutputFormat.terminal, parsed.format);
    try std.testing.expectEqual(true, parsed.monochrome);
}

test "non-terminal width resolution" {
    var parsed = Parsed{ .width = 60 };
    try std.testing.expectEqual(@as(usize, 60), parsed.nonTerminalWidth(90));
    parsed = Parsed{};
    try std.testing.expectEqual(@as(usize, 90), parsed.nonTerminalWidth(90));
    try std.testing.expectEqual(@as(usize, 120), parsed.nonTerminalWidth(0));
}

test "output path is freed on deinit" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "plain", "-o", "out.txt", "in.md" };
    const parsed = try parse(allocator, &argv);
    parsed.deinit(allocator);
}

test "no arguments leaves input unset so stdin can be read implicitly" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"mercat"};
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(Input.none, std.meta.activeTag(parsed.input));
}

test "explicit dash still selects stdin" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "-" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(Input.stdin, std.meta.activeTag(parsed.input));
}

// ---- Messages: golden strings for every usage error ----

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
    try expectMessage(&.{ "mercat", "--them=dark" }, error.UnknownFlag, "unknown option '--them' (did you mean '--theme'?)");
    try expectMessage(&.{ "mercat", "--colour", "never" }, error.UnknownFlag, "unknown option '--colour' (did you mean '--color'?)");
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

test "message: invalid enum values list the valid ones" {
    try expectMessage(&.{ "mercat", "--format", "svg", "x.md" }, error.InvalidFormat, "invalid value 'svg' for '--format' (expected one of: terminal, plain, png)");
    try expectMessage(&.{ "mercat", "--frontmatter=zz", "x.md" }, error.InvalidFrontmatterStyle, "invalid value 'zz' for '--frontmatter' (expected one of: panel, dim, compact, raw, hidden)");
    try expectMessage(&.{ "mercat", "--box-style", "zz" }, error.InvalidBoxStyle, "invalid value 'zz' for '--box-style' (expected one of: standard, rounded, heavy, double, ascii)");
    try expectMessage(&.{ "mercat", "--layout", "zz" }, error.InvalidLayout, "invalid value 'zz' for '--layout' (expected one of: auto, sugiyama, tree, force)");
    try expectMessage(&.{ "mercat", "--crossing-heuristic", "zz" }, error.InvalidCrossingHeuristic, "invalid value 'zz' for '--crossing-heuristic' (expected one of: median, barycenter)");
    try expectMessage(&.{ "mercat", "--color", "yes" }, error.InvalidColor, "invalid value 'yes' for '--color' (expected one of: auto, always, never)");
    try expectMessage(&.{ "mercat", "--aspect-ratio", "-1" }, error.InvalidAspectRatio, "invalid value '-1' for '--aspect-ratio' (expected a positive number, e.g. 2.0)");
}

test "message: width outside 0 or 20..1000 names the range" {
    try expectMessage(&.{ "mercat", "-w", "eighty" }, error.InvalidWidth, "invalid width 'eighty' for '-w' (expected 0 for auto, or 20..1000)");
    try expectMessage(&.{ "mercat", "--width=5" }, error.InvalidWidth, "invalid width '5' for '--width' (expected 0 for auto, or 20..1000)");
    try expectMessage(&.{ "mercat", "-w1001" }, error.InvalidWidth, "invalid width '1001' for '-w' (expected 0 for auto, or 20..1000)");
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

test "help and version are not usage errors" {
    try std.testing.expectError(error.ShowHelp, parse(std.testing.allocator, &.{ "mercat", "--help" }));
    try std.testing.expectError(error.ShowVersion, parse(std.testing.allocator, &.{ "mercat", "-V" }));
    try std.testing.expect(!args.isUsageError(error.ShowHelp));
    try std.testing.expect(!args.isUsageError(error.ShowVersion));
}

// ---- Argument syntax ----

test "--flag=value works for value-taking long options" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, &.{ "mercat", "--width=80", "--theme=light", "--frontmatter=dim", "--color=never", "x.md" });
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(?usize, 80), parsed.width);
    try std.testing.expectEqualStrings("light", parsed.style.?);
    try std.testing.expectEqual(config.FrontmatterStyle.dim, parsed.frontmatter.?);
    try std.testing.expectEqual(args.ColorMode.never, parsed.color.?);
}

test "--output=path and --format=plain" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, &.{ "mercat", "--format=plain", "--output=out.txt", "x.md" });
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(OutputFormat.plain, parsed.format);
    try std.testing.expectEqualStrings("out.txt", parsed.output_path.?);
}

test "attached short values: -w80 and -oout.txt" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, &.{ "mercat", "-w80", "--format", "plain", "-oout.txt", "x.md" });
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(?usize, 80), parsed.width);
    try std.testing.expectEqualStrings("out.txt", parsed.output_path.?);
}

test "bundled short flags" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, &.{ "mercat", "-pw", "40", "x.md" });
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.pager);
    try std.testing.expectEqual(@as(?usize, 40), parsed.width);
}

test "'--' ends options so dash-leading file names work" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, &.{ "mercat", "-w", "80", "--", "-weird.md" });
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("-weird.md", parsed.input.file);

    const dash = try parse(allocator, &.{ "mercat", "--", "-" });
    defer dash.deinit(allocator);
    try std.testing.expectEqualStrings("-", dash.input.file);
}

test "--theme is canonical and --style stays an alias" {
    const allocator = std.testing.allocator;
    const a = try parse(allocator, &.{ "mercat", "--theme", "pink", "x.md" });
    defer a.deinit(allocator);
    try std.testing.expectEqualStrings("pink", a.style.?);
    const b = try parse(allocator, &.{ "mercat", "--style=pink", "x.md" });
    defer b.deinit(allocator);
    try std.testing.expectEqualStrings("pink", b.style.?);
}

test "--list-themes and --color parse" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, &.{ "mercat", "--list-themes", "--color", "always" });
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.list_themes);
    try std.testing.expectEqual(args.ColorMode.always, parsed.color.?);
}

test "--force-layout stays an alias of --layout" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, &.{ "mercat", "--force-layout=tree", "x.md" });
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(args.ForceLayout.tree, parsed.force_layout.?);
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

test "-w 0 means the export default for plain/png, not a literal 0" {
    const parsed = Parsed{ .width = 0 };
    try std.testing.expectEqual(@as(usize, 120), parsed.nonTerminalWidth(0));
    try std.testing.expectEqual(@as(usize, 120), parsed.nonTerminalWidth(90));
    try std.testing.expectEqual(@as(usize, 0), parsed.effectiveWidth(90));
}

// ---- Suggestions ----

test "suggest stays quiet for distant typos" {
    try std.testing.expectEqual(@as(?[]const u8, null), args.suggest("--zzzzzzzzzz"));
    try std.testing.expectEqualStrings("--list-themes", args.suggest("--list-theme").?);
}
