const std = @import("std");
const args = @import("cli/args.zig");
const renderer = @import("cli/renderer.zig");
const pager = @import("cli/pager.zig");
const cli_input = @import("cli/input.zig");
const diag = @import("cli/diag.zig");
const cli_color = @import("cli/color.zig");
const cli_themes = @import("cli/themes.zig");
const tui_entry = @import("cli/tui_entry.zig");
const config = @import("core/config.zig");
const markdown = @import("core/markdown/parser.zig");
const encoding = @import("core/encoding.zig");

const cli_input_test = @import("cli/input_test.zig");
const render_model = @import("core/markdown/render.zig");
const theme = @import("core/theme.zig");
const plain = @import("export/plain.zig");
const export_types = @import("export/types.zig");
const export_layout = @import("export/layout.zig");
const export_font = @import("export/font.zig");
const export_png = @import("export/png.zig");
const export_glyph_sheet = @import("export/glyph_sheet.zig");
const export_test = @import("export/export_test.zig");
const terminal = @import("platform/terminal.zig");
const tui = @import("tui/app.zig");
const term_guard = @import("tui/term_guard.zig");
const theme_color = @import("core/theme/color.zig");
const theme_resolve = @import("core/theme/resolve.zig");
const theme_dump = @import("core/theme/dump.zig");

const VERSION = @import("build_options").version;

pub const std_options: std.Options = .{
    .log_level = .warn,
    .logFn = logFn,
};

/// Restores the terminal before reporting a crash, so a panic inside the TUI
/// never leaves the shell in the alternate screen with the mouse captured.
pub const panic = std.debug.FullPanic(term_guard.panicHandler);

var tui_active = std.atomic.Value(bool).init(false);

/// Library log output goes through the diagnostics module so it carries the
/// same "mercat: warning: …" shape as everything else on stderr.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args_: anytype,
) void {
    _ = scope;
    if (tui_active.load(.monotonic)) return;
    const diag_level: diag.Level = switch (level) {
        .err => .err,
        .warn => .warning,
        .info, .debug => .note,
    };
    diag.print(diag_level, format, args_);
}

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    run(allocator) catch |err| {
        diag.err("{s}", .{diag.describeError(err)});
        return diag.exit_failure;
    };
    return diag.exit_ok;
}

fn run(allocator: std.mem.Allocator) !void {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    // Config loads first so a usage error can honor `[display] color`; its
    // warnings are printed only once the command line parses.
    var warnings = config.Warnings.init(allocator);
    defer warnings.deinit();
    var loaded_config = try config.load(allocator, &warnings);
    defer loaded_config.deinit(allocator);

    const env = cli_color.Env.fromProcess();
    const stderr_tty = std.fs.File.stderr().isTty();
    var arg_diag: args.Diagnostic = .{};
    const parsed = args.parseDiag(allocator, argv, &arg_diag) catch |err| switch (err) {
        error.ShowHelp => return showHelp(allocator),
        error.ShowVersion => return writeStdoutOrFail("mercat " ++ VERSION ++ "\n"),
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.setColor(cli_color.resolveStderr(args.prescanColor(argv), loaded_config.display.color, env, stderr_tty));
            reportUsageError(err, &arg_diag);
        },
    };
    defer parsed.deinit(allocator);

    theme_color.initTruecolor(allocator);

    const stdout_tty = std.fs.File.stdout().isTty();
    const color_on = cli_color.resolve(parsed.color, loaded_config.display.color, env, stdout_tty);
    diag.setColor(cli_color.resolveStderr(parsed.color, loaded_config.display.color, env, stderr_tty));
    for (warnings.items()) |msg| diag.warn("{s}", .{msg});

    if (parsed.list_themes) return listThemes(allocator);
    if (parsed.dump_theme) |name| return runDumpTheme(allocator, name);

    var registry = theme_resolve.Registry.init(allocator);
    defer registry.deinit();
    registry.useThemeDir();
    var diag_list = theme_resolve.Diagnostics.init(allocator);
    defer diag_list.deinit();
    const theme_name = try checkThemeName(allocator, &registry, &diag_list, parsed, &loaded_config);

    // TUI entry checks run before any input is read, so `sleep 9 | mercat -t`
    // fails at once instead of blocking on the pipe.
    var input = parsed.input;
    if (parsed.mode == .tui) input = try checkTuiEntry(parsed.input);

    const raw_content = try readInput(allocator, input);
    defer allocator.free(raw_content);
    // Decode before anything parses: invalid UTF-8 becomes U+FFFD with one
    // warning, so every block still renders as markdown.
    const decoded = try encoding.decode(allocator, raw_content);
    defer decoded.deinit(allocator);
    const encoding_warning = try encodingWarning(allocator, inputTitle(input), decoded);
    defer if (encoding_warning) |w| allocator.free(w);
    if (encoding_warning) |w| diag.warn("{s}", .{w});
    const content = decoded.text;

    // Empty input renders to nothing: no stray newline on stdout, and an
    // empty file for `--format plain -o`.
    if (parsed.mode == .cli and parsed.format != .png and std.mem.trim(u8, content, " \t\r\n").len == 0) {
        if (parsed.format == .plain) writePlainOutput("", parsed.output_path);
        return;
    }

    var resolved = try registry.resolve(theme_name, loaded_config.display.syntax_theme, loaded_config.raw_theme.view(), &diag_list);
    const show_heading_markers = parsed.effectiveHeadingMarkers(loaded_config.display.heading_markers);
    const frontmatter_style = parsed.effectiveFrontmatter(loaded_config.display.frontmatter);

    if (parsed.mode == .tui) {
        tui_active.store(true, .monotonic);
        diag.setMuted(true);
        defer {
            diag.setMuted(false);
            tui_active.store(false, .monotonic);
        }
        const theme_warning = try themeWarning(allocator, &diag_list);
        defer if (theme_warning) |w| allocator.free(w);
        const startup_warning = try joinWarnings(allocator, encoding_warning, theme_warning);
        defer if (startup_warning) |w| allocator.free(w);
        try tui.run(allocator, inputTitle(input), input, content, loaded_config.general.editor, &resolved, startup_warning, show_heading_markers, frontmatter_style, parsed.force_layout orelse .auto, loaded_config.mermaid.subgraph_edges);
        return;
    }

    const render_width = switch (parsed.format) {
        .terminal => blk: {
            const configured = parsed.effectiveWidth(loaded_config.display.width);
            break :blk if (configured == 0) terminal.stdoutWidth() else configured;
        },
        .plain, .png => parsed.nonTerminalWidth(loaded_config.display.width),
    };

    try runCli(allocator, parsed, &loaded_config, &resolved, &diag_list, content, .{
        .width = render_width,
        .show_heading_markers = show_heading_markers,
        .frontmatter_style = frontmatter_style,
        .emit = cli_color.Emit.init(color_on, stdout_tty),
    });
}

fn showHelp(allocator: std.mem.Allocator) !void {
    const path = try config.resolveConfigPath(allocator);
    defer allocator.free(path);
    const state = if (std.fs.cwd().access(path, .{})) |_| "" else |_| " (not present; defaults apply)";
    const line = try std.fmt.allocPrint(allocator, "Config: {s}{s}\n  TOML; command-line flags win over environment, environment over config.\n", .{ path, state });
    defer allocator.free(line);
    writeStdoutOrFail(args.help_text);
    writeStdoutOrFail(line);
}

/// Writes informational output (help, version, theme lists). A closed pipe
/// exits 0; any other failure is "cannot write to stdout: …", exit 1.
fn writeStdoutOrFail(bytes: []const u8) void {
    pager.writeStdout(bytes) catch |err| diag.failStdout(err);
}

fn reportUsageError(err: args.ParseError, d: *const args.Diagnostic) noreturn {
    var buf: [512]u8 = undefined;
    diag.err("{s}", .{args.describe(&buf, err, d)});
    var note_buf: [256]u8 = undefined;
    if (args.describeNote(&note_buf, err, d)) |text| diag.note("{s}", .{text});
    // `mercat -weird.md` parses as `-w eird.md`; point at `--` when the token is a real file.
    if (d.token.len > 1 and d.token[0] == '-') {
        if (std.fs.cwd().access(d.token, .{})) |_| {
            diag.note("to open a file whose name starts with '-', use: mercat -- {s}", .{d.token});
        } else |_| {}
    }
    diag.writeRaw(diag.help_hint);
    std.process.exit(diag.exit_usage);
}

/// Validates the theme name before any work. An unknown `--theme` is a usage
/// error; an unknown config/env theme warns and falls back to dark.
fn checkThemeName(
    allocator: std.mem.Allocator,
    registry: *theme_resolve.Registry,
    diag_list: *theme_resolve.Diagnostics,
    parsed: args.Parsed,
    cfg: *const config.Config,
) ![]const u8 {
    const name = parsed.effectiveTheme(cfg.display.theme);
    if (registry.lookup(name, diag_list) != null) return name;

    var names = try cli_themes.collect(allocator);
    defer names.deinit();
    if (parsed.style != null) {
        diag.err("unknown theme '{s}' (expected one of: {s})", .{ name, names.joined() });
        usageExit(names.suggest(name));
    }
    const origin = if (cfg.theme_origin.len != 0) cfg.theme_origin else "config";
    diag.warn("{s}: unknown theme '{s}'; using dark (expected one of: {s})", .{ origin, name, names.joined() });
    if (names.suggest(name)) |s| diag.note("did you mean '{s}'?", .{s});
    return "dark";
}

/// Ends a usage error already reported: an optional did-you-mean note, the
/// --help pointer, exit 2.
fn usageExit(suggestion: ?[]const u8) noreturn {
    if (suggestion) |s| diag.note("did you mean '{s}'?", .{s});
    diag.writeRaw(diag.help_hint);
    std.process.exit(diag.exit_usage);
}

fn checkTuiEntry(input: args.Input) !args.Input {
    const path = input.filePath();
    const is_dir = if (path) |p| isDirectory(p) else false;
    const readme = if (std.fs.cwd().statFile(tui_entry.default_file)) |st| st.kind != .directory else |_| false;
    const outcome = tui_entry.decide(input, .{
        .stdin_tty = terminal.stdinIsTty(),
        .stdout_tty = terminal.stdoutIsTty(),
        .has_controlling_tty = terminal.hasControllingTty(),
        .stdin_pipe = terminal.stdinIsPipe(),
    }, .{ .input_is_dir = is_dir, .readme_exists = readme });
    switch (outcome) {
        .open => |file| return if (path == null) .{ .file = file } else input,
        .refuse => |refusal| {
            var buf: [256]u8 = undefined;
            diag.usage("{s}", .{tui_entry.message(&buf, refusal, input)});
        },
    }
}

fn isDirectory(path: []const u8) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    return st.kind == .directory;
}

fn listThemes(allocator: std.mem.Allocator) !void {
    var names = try cli_themes.collect(allocator);
    defer names.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (names.items) |name| {
        try out.appendSlice(allocator, name);
        try out.append(allocator, '\n');
    }
    writeStdoutOrFail(out.items);
}

const CliDisplay = struct {
    width: usize,
    show_heading_markers: bool,
    frontmatter_style: config.FrontmatterStyle,
    emit: cli_color.Emit,
};

fn runCli(
    allocator: std.mem.Allocator,
    parsed: args.Parsed,
    loaded_config: *const config.Config,
    resolved: *theme_resolve.ResolvedTheme,
    diag_list: *const theme_resolve.Diagnostics,
    content: []const u8,
    display: CliDisplay,
) !void {
    var document = if (cli_input.isMermaidSource(parsed.input.filePath(), content))
        try markdown.parseMermaid(allocator, content)
    else
        try markdown.parse(allocator, content);
    defer document.deinit(allocator);

    var rendered = try render_model.renderDocument(allocator, document, .{
        .width = display.width,
        .show_heading_markers = display.show_heading_markers,
        .decor = &resolved.decor,
        .frontmatter_style = display.frontmatter_style,
        .mermaid_debug = parsed.debug_mermaid,
        .mermaid_subgraph_edges = loaded_config.mermaid.subgraph_edges,
    });
    defer rendered.deinit(allocator);

    emitThemeDiagnostics(diag_list);

    switch (parsed.format) {
        .terminal => {
            const canvas: ?renderer.Canvas = if (resolved.canvasBg()) |bg|
                .{ .bg = bg, .width = display.width }
            else
                null;
            const output = try renderer.serializeWith(allocator, rendered, resolved.styles, canvas, .{
                .color = display.emit.color,
                .hyperlinks = display.emit.hyperlinks,
            });
            defer allocator.free(output);
            pager.writeOutput(allocator, output, loaded_config.general.pager, parsed.pager) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => diag.failStdout(err),
            };
        },
        .plain => {
            const output = plain.serialize(allocator, rendered) catch |err| {
                var buf: [192]u8 = undefined;
                diag.fail("plain export failed: {s}", .{exportDetail(&buf, err, .{})});
            };
            defer allocator.free(output);
            writePlainOutput(output, parsed.output_path);
        },
        .png => {
            const output_path = parsed.output_path.?;
            const options = export_layout.Options{
                .palette = resolved.styles,
                .color_mode = if (parsed.monochrome) .monochrome else .theme,
                .canvas_bg = resolved.canvasBg(),
            };

            var png_diag: export_png.Diagnostic = .{};
            exportPng(allocator, rendered, options, output_path, &png_diag) catch |err| {
                if (isExportError(err)) {
                    var buf: [192]u8 = undefined;
                    diag.fail("PNG export failed: {s}", .{exportDetail(&buf, err, png_diag)});
                }
                diag.failWrite(output_path, err);
            };
        },
    }
}

fn runDumpTheme(allocator: std.mem.Allocator, name: []const u8) !void {
    var diag_list = theme_resolve.Diagnostics.init(allocator);
    defer diag_list.deinit();
    var registry = theme_resolve.Registry.init(allocator);
    defer registry.deinit();
    registry.useThemeDir();

    if (registry.lookup(name, &diag_list) == null) {
        emitThemeDiagnostics(&diag_list);
        var names = try cli_themes.collect(allocator);
        defer names.deinit();
        diag.err("unknown theme '{s}' for '--dump-theme' (expected one of: {s})", .{ name, names.joined() });
        usageExit(names.suggest(name));
    }
    const folded = registry.mergedSpec(name, &diag_list).?;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try theme_dump.write(buf.writer(allocator), name, &folded);
    emitThemeDiagnostics(&diag_list);
    writeStdoutOrFail(buf.items);
}

fn themeWarning(allocator: std.mem.Allocator, diag_list: *const theme_resolve.Diagnostics) !?[]u8 {
    const n = diag_list.count();
    if (n == 0) return null;
    const first = diag_list.list.items[0].detail;
    return if (n == 1)
        try std.fmt.allocPrint(allocator, "theme: {s}", .{first})
    else
        try std.fmt.allocPrint(allocator, "theme: {s} (+{d} more)", .{ first, n - 1 });
}

/// The TUI status bar shows one startup message: both warnings, joined.
fn joinWarnings(allocator: std.mem.Allocator, first: ?[]const u8, second: ?[]const u8) !?[]u8 {
    if (first != null and second != null) return try std.fmt.allocPrint(allocator, "{s}; {s}", .{ first.?, second.? });
    const only = first orelse second orelse return null;
    return try allocator.dupe(u8, only);
}

fn emitThemeDiagnostics(diag_list: *const theme_resolve.Diagnostics) void {
    for (diag_list.list.items) |d| diag.warn("theme: {s}", .{d.detail});
}

fn isExportError(err: anyerror) bool {
    return switch (err) {
        error.MissingGlyph,
        error.FontInitFailed,
        error.PixelOverflow,
        error.ColumnOverflow,
        error.InvalidUtf8,
        error.InvalidControlScalar,
        error.InvalidPlainByte,
        => true,
        else => false,
    };
}

fn exportDetail(buf: []u8, err: anyerror, png_diag: export_png.Diagnostic) []const u8 {
    return switch (err) {
        error.MissingGlyph => std.fmt.bufPrint(
            buf,
            "no glyph for U+{X:0>4} at row {d}, column {d}",
            .{ png_diag.missing_codepoint, png_diag.row, png_diag.column },
        ) catch "missing glyph",
        error.FontInitFailed => "failed to initialize the embedded export font",
        error.PixelOverflow => "pixel dimensions overflow the u32 surface limit",
        error.ColumnOverflow => "rendered column count overflows",
        error.InvalidUtf8 => "invalid UTF-8 in rendered text",
        error.InvalidControlScalar, error.InvalidPlainByte => "control scalar in rendered text",
        else => diag.describeError(err),
    };
}

fn exportPng(
    allocator: std.mem.Allocator,
    rendered: render_model.Rendered,
    options: export_layout.Options,
    output_path: []const u8,
    png_diag: *export_png.Diagnostic,
) !void {
    const face = export_font.Font.init(options.font_pixel_height) catch return error.FontInitFailed;

    var doc = try export_layout.build(allocator, rendered, &face, options);
    defer doc.deinit(allocator);

    const result = try export_png.writeFile(allocator, doc, &face, options.color_mode, output_path, png_diag);
    result.deinit(allocator);
}

fn writePlainOutput(output: []const u8, output_path: ?[]const u8) void {
    const path = output_path orelse return writeStdoutOrFail(output);
    const file = std.fs.cwd().createFile(path, .{}) catch |err| diag.failWrite(path, err);
    defer file.close();
    file.writeAll(output) catch |err| diag.failWrite(path, err);
}

/// The one-line warning for input that was not valid UTF-8, or null.
pub fn encodingWarning(allocator: std.mem.Allocator, name: []const u8, decoded: encoding.Decoded) !?[]u8 {
    const issue = decoded.issue orelse return null;
    var buf: [512]u8 = undefined;
    return try allocator.dupe(u8, encoding.describeIssue(&buf, name, decoded.encoding, issue));
}

fn inputTitle(input: args.Input) []const u8 {
    return switch (input) {
        .file => |path| path,
        .stdin, .none => "stdin",
    };
}

const max_input_bytes = 256 * 1024 * 1024;

/// Reads the whole input. Every failure is reported here with the file name
/// and a conventional reason, then exits (1 for IO, 2 for missing input).
fn readInput(allocator: std.mem.Allocator, input: args.Input) ![]u8 {
    switch (input) {
        .file => |path| {
            if (isDirectory(path)) diag.fail("{s}: is a directory", .{path});
            return std.fs.cwd().readFileAlloc(allocator, path, max_input_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => diag.failPath(path, err),
            };
        },
        .stdin => return readStdin(allocator),
        .none => {
            if (cli_input.shouldReadImplicitStdin()) return readStdin(allocator);
            diag.err("no input file (and stdin is a terminal)", .{});
            diag.writeRaw(args.usage_text);
            diag.writeRaw(diag.help_hint);
            std.process.exit(diag.exit_usage);
        },
    }
}

fn readStdin(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.File.stdin().readToEndAlloc(allocator, max_input_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => diag.failPath("stdin", err),
    };
}

test "encoding warning and TUI startup message" {
    const allocator = std.testing.allocator;
    const decoded = try encoding.decode(allocator, "a\nb\xff\n");
    defer decoded.deinit(allocator);
    const warning = (try encodingWarning(allocator, "x.md", decoded)).?;
    defer allocator.free(warning);
    try std.testing.expectEqualStrings("x.md: invalid UTF-8 at line 2, column 2 (1 byte replaced with U+FFFD)", warning);
    const clean = try encoding.decode(allocator, "ok");
    try std.testing.expect(try encodingWarning(allocator, "x.md", clean) == null);

    const both = (try joinWarnings(allocator, "enc", "theme: t")).?;
    defer allocator.free(both);
    try std.testing.expectEqualStrings("enc; theme: t", both);
    const one = (try joinWarnings(allocator, null, "theme: t")).?;
    defer allocator.free(one);
    try std.testing.expectEqualStrings("theme: t", one);
    try std.testing.expect(try joinWarnings(allocator, null, null) == null);
}

test {
    std.testing.refAllDecls(@This());
    _ = export_glyph_sheet;
    _ = export_test;
    _ = cli_input_test;
    _ = diag;
    _ = cli_color;
    _ = cli_themes;
    _ = tui_entry;
    _ = @import("cli/help.zig");
    _ = encoding;
}
