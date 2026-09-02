const std = @import("std");
const args = @import("cli/args.zig");
const renderer = @import("cli/renderer.zig");
const pager = @import("cli/pager.zig");
const cli_input = @import("cli/input.zig");
const config = @import("core/config.zig");
const markdown = @import("core/markdown/parser.zig");

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
const theme_color = @import("core/theme/color.zig");
const theme_resolve = @import("core/theme/resolve.zig");
const theme_dump = @import("core/theme/dump.zig");

const VERSION = @import("build_options").version;

pub const std_options: std.Options = .{
    .log_level = .warn,
    .logFn = logFn,
};

/// Set while the TUI owns the terminal (see the `tui.run` call site). Atomic so
/// the flag is well-defined regardless of which thread a log call originates on;
/// the TUI runs single-threaded today, so contention is not a concern.
var tui_active = std.atomic.Value(bool).init(false);

/// Custom log sink: swallow messages while the TUI owns the alternate screen,
/// otherwise fall through to the default stderr logger. The level cap in
/// `std_options` has already filtered out `.debug`/`.info` before we get here.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args_: anytype,
) void {
    if (tui_active.load(.monotonic)) return;
    std.log.defaultLog(level, scope, format, args_);
}

fn showVersion() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("mercat ");
    try stdout.writeAll(VERSION);
    try stdout.writeAll("\n");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const parsed = args.parse(allocator, argv) catch |err| switch (err) {
        error.ShowHelp => {
            try std.fs.File.stdout().writeAll(args.help_text);
            return;
        },
        error.ShowVersion => {
            try showVersion();
            return;
        },
        else => return err,
    };
    defer parsed.deinit(allocator);

    theme_color.initTruecolor(allocator);

    var loaded_config = try config.load(allocator);
    defer loaded_config.deinit(allocator);

    if (parsed.dump_theme) |name| {
        try runDumpTheme(allocator, name);
        return;
    }

    const raw_content = readInput(allocator, parsed.input) catch |err| switch (err) {
        error.MissingInput => {
            std.fs.File.stderr().writeAll(args.usage_text) catch {};
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(raw_content);
    const content = cli_input.stripBom(raw_content);

    var diag = theme_resolve.Diagnostics.init(allocator);
    defer diag.deinit();

    var registry = theme_resolve.Registry.init(allocator);
    defer registry.deinit();

    registry.useThemeDir();

    const theme_name = parsed.effectiveTheme(loaded_config.display.theme);

    const inline_overrides = loaded_config.raw_theme.view();

    var resolved = try registry.resolve(theme_name, loaded_config.display.syntax_theme, inline_overrides, &diag);
    const show_heading_markers = parsed.effectiveHeadingMarkers(loaded_config.display.heading_markers);
    const frontmatter_style = parsed.effectiveFrontmatter(loaded_config.display.frontmatter);
    const render_width = switch (parsed.format) {
        .terminal => blk: {
            const configured = parsed.effectiveWidth(loaded_config.display.width);
            break :blk if (configured == 0) terminal.stdoutWidth() else configured;
        },
        .plain, .png => parsed.nonTerminalWidth(loaded_config.display.width),
    };
    if (parsed.mode == .tui) {
        if (!terminal.stdinIsTty() or !terminal.stdoutIsTty() or !terminal.hasControllingTty()) {
            try std.fs.File.stderr().writeAll("TUI mode requires an interactive terminal with /dev/tty available.\n");
            return;
        }
        tui_active.store(true, .monotonic);
        defer tui_active.store(false, .monotonic);
        const theme_warning = try themeWarning(allocator, &diag);
        defer if (theme_warning) |w| allocator.free(w);
        try tui.run(allocator, inputTitle(parsed.input), parsed.input, content, loaded_config.general.editor, &resolved, theme_warning, show_heading_markers, frontmatter_style, parsed.force_layout orelse .auto, loaded_config.mermaid.subgraph_edges);
        return;
    }

    try runCli(allocator, parsed, &loaded_config, &resolved, &diag, content, .{
        .width = render_width,
        .show_heading_markers = show_heading_markers,
        .frontmatter_style = frontmatter_style,
    });
}

/// Per-invocation display settings already folded from CLI flags + config,
/// passed to the CLI render path as one bundle.
const CliDisplay = struct {
    width: usize,
    show_heading_markers: bool,
    frontmatter_style: config.FrontmatterStyle,
};

/// The non-TUI path: parse the input, build the render model once, then
/// serialize per output format (§6.1).
fn runCli(
    allocator: std.mem.Allocator,
    parsed: args.Parsed,
    loaded_config: *const config.Config,
    resolved: *theme_resolve.ResolvedTheme,
    diag: *const theme_resolve.Diagnostics,
    content: []const u8,
    display: CliDisplay,
) !void {
    var document = if (cli_input.isMermaidSource(parsed.input.filePath(), content))
        try createMermaidDocument(allocator, content)
    else
        try markdown.parse(allocator, content);
    defer document.deinit(allocator);

    var rendered = try render_model.renderDocument(allocator, document, .{
        .width = display.width,
        .show_heading_markers = display.show_heading_markers,
        .decor = &resolved.decor,
        .frontmatter_style = display.frontmatter_style,
        .for_export = parsed.format != .terminal,
        .mermaid_box_style = parsed.box_style orelse .standard,
        .mermaid_crossing_heuristic = parsed.crossing_heuristic orelse .median,
        .mermaid_force_layout = parsed.force_layout orelse .auto,
        .mermaid_aspect_ratio = parsed.aspect_ratio orelse 1.0,
        .mermaid_debug = parsed.debug_mermaid,
        .mermaid_subgraph_edges = loaded_config.mermaid.subgraph_edges,
    });
    defer rendered.deinit(allocator);

    emitCliDiagnostics(diag);

    const ctx = ExportContext{
        .input_path = inputTitle(parsed.input),
        .format = @tagName(parsed.format),
        .output_path = parsed.output_path,
        .width = display.width,
    };

    switch (parsed.format) {
        .terminal => {
            const canvas: ?renderer.Canvas = if (resolved.canvasBg()) |bg|
                .{ .bg = bg, .width = display.width }
            else
                null;
            const output = try renderer.serialize(
                allocator,
                rendered,
                resolved.styles,
                canvas,
            );
            defer allocator.free(output);
            try pager.writeOutput(allocator, output, loaded_config.general.pager, parsed.pager);
        },
        .plain => {
            exportPlain(allocator, rendered, parsed.output_path) catch |err| {
                var buf: [192]u8 = undefined;
                exportFailure(ctx, exportDetail(&buf, err, .{}));
            };
        },
        .png => {
            const output_path = parsed.output_path orelse return error.PngRequiresOutput;

            const options = export_layout.Options{
                .palette = resolved.styles,
                .color_mode = if (parsed.monochrome) .monochrome else .theme,
                .canvas_bg = resolved.canvasBg(),
            };

            var png_diag: export_png.Diagnostic = .{};
            exportPng(allocator, rendered, options, output_path, &png_diag) catch |err| {
                var buf: [192]u8 = undefined;
                exportFailure(ctx, exportDetail(&buf, err, png_diag));
            };
        },
    }
}

/// Resolve `name` (preset or user theme file) and write it to stdout as
/// round-trippable TOML. Unknown names report `unknown_theme` and exit non-zero.
fn runDumpTheme(allocator: std.mem.Allocator, name: []const u8) !void {
    var diag = theme_resolve.Diagnostics.init(allocator);
    defer diag.deinit();
    var registry = theme_resolve.Registry.init(allocator);
    defer registry.deinit();
    registry.useThemeDir();

    const folded = registry.mergedSpec(name, &diag);
    if (folded) |f| {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try theme_dump.write(buf.writer(allocator), name, &f);
        try std.fs.File.stdout().writeAll(buf.items);
    }
    emitCliDiagnostics(&diag);
    if (folded == null) std.process.exit(1);
}

/// Build a one-line theme-warning summary for the TUI status bar, or null when
/// resolution produced no diagnostics. Owned by the caller.
fn themeWarning(allocator: std.mem.Allocator, diag: *const theme_resolve.Diagnostics) !?[]u8 {
    const n = diag.count();
    if (n == 0) return null;
    const first = diag.list.items[0].detail;
    return if (n == 1)
        try std.fmt.allocPrint(allocator, "theme: {s}", .{first})
    else
        try std.fmt.allocPrint(allocator, "theme: {s} (+{d} more)", .{ first, n - 1 });
}

/// Emit each theme diagnostic as a dim ANSI comment line on stderr. stderr is
/// a distinct channel from the rendered stdout, so pipes/redirects stay
/// byte-clean while the warnings still reach the user's terminal — interactive
/// and piped invocations alike.
fn emitCliDiagnostics(diag: *const theme_resolve.Diagnostics) void {
    if (diag.count() == 0) return;
    const stderr = std.fs.File.stderr();
    var buf: [512]u8 = undefined;
    for (diag.list.items) |d| {
        const line = std.fmt.bufPrint(&buf, "\x1b[2m# mercat: {s}\x1b[0m\n", .{d.detail}) catch continue;
        stderr.writeAll(line) catch {};
    }
}

/// Shared §20 diagnostic context printed on every export failure.
const ExportContext = struct {
    input_path: []const u8,
    format: []const u8,
    output_path: ?[]const u8,
    width: usize,
};

/// Print one §20 diagnostic line to stderr and exit non-zero. The common
/// context (input path, output format/path, width) is always shown; `detail`
/// carries the failure-specific fields (missing glyph + row/col, pixel
/// overflow, font-init, encode/write, ...) built by `exportDetail`.
fn exportFailure(ctx: ExportContext, detail: []const u8) noreturn {
    const out = ctx.output_path orelse "<stdout>";
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "mercat: export failed: {s} (input={s}, format={s}, output={s}, width={d})\n",
        .{ detail, ctx.input_path, ctx.format, out, ctx.width },
    ) catch "mercat: export failed\n";
    std.fs.File.stderr().writeAll(msg) catch {};
    std.process.exit(1);
}

/// Map an export error (plus, for `MissingGlyph`, the PNG diagnostic) to the
/// §20 failure-specific detail string. `buf` backs the one case that formats
/// dynamic fields; every other case returns a static string.
fn exportDetail(buf: []u8, err: anyerror, diag: export_png.Diagnostic) []const u8 {
    return switch (err) {
        error.MissingGlyph => std.fmt.bufPrint(
            buf,
            "no glyph for U+{X:0>4} at row {d}, column {d}",
            .{ diag.missing_codepoint, diag.row, diag.column },
        ) catch "missing glyph",
        error.FontInitFailed => "failed to initialize the embedded export font",
        error.PixelOverflow => "pixel dimensions overflow the u32 surface limit",
        error.ColumnOverflow => "rendered column count overflows",
        error.InvalidUtf8 => "invalid UTF-8 in rendered text",
        error.InvalidTabInRendered => "tab scalar in rendered text",
        error.InvalidControlScalar, error.InvalidPlainByte => "control scalar in rendered text",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}

fn exportPlain(allocator: std.mem.Allocator, rendered: render_model.Rendered, output_path: ?[]const u8) !void {
    const output = try plain.serialize(allocator, rendered);
    defer allocator.free(output);
    try writePlainOutput(output, output_path);
}

fn exportPng(
    allocator: std.mem.Allocator,
    rendered: render_model.Rendered,
    options: export_layout.Options,
    output_path: []const u8,
    diag: *export_png.Diagnostic,
) !void {
    const face = export_font.Font.init(options.font_pixel_height) catch return error.FontInitFailed;

    var doc = try export_layout.build(allocator, rendered, &face, options);
    defer doc.deinit(allocator);

    const result = try export_png.writeFile(allocator, doc, &face, options.color_mode, output_path, diag);
    result.deinit(allocator);
}

fn writePlainOutput(output: []const u8, output_path: ?[]const u8) !void {
    if (output_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(output);
    } else {
        try std.fs.File.stdout().writeAll(output);
    }
}

fn inputTitle(input: args.Input) []const u8 {
    return switch (input) {
        .file => |path| path,
        .stdin, .none => "stdin",
    };
}

/// Upper bound on input size (size only — content/extension are not checked
/// here). Sources are text; anything past this is almost certainly a mistyped
/// path (or `mercat < /dev/zero`) and is better refused than swallowed into
/// memory.
const max_input_bytes = 256 * 1024 * 1024;

fn readInput(allocator: std.mem.Allocator, input: args.Input) ![]u8 {
    return switch (input) {
        .stdin => std.fs.File.stdin().readToEndAlloc(allocator, max_input_bytes),
        .file => |path| blk: {
            const cwd = std.fs.cwd();
            break :blk try cwd.readFileAlloc(allocator, path, max_input_bytes);
        },
        .none => if (cli_input.shouldReadImplicitStdin())
            std.fs.File.stdin().readToEndAlloc(allocator, max_input_bytes)
        else
            error.MissingInput,
    };
}

fn createMermaidDocument(allocator: std.mem.Allocator, content: []const u8) !markdown.Document {
    const language = try allocator.dupe(u8, "mermaid");
    errdefer allocator.free(language);
    const code = try allocator.dupe(u8, content);
    errdefer allocator.free(code);

    const blocks = try allocator.alloc(markdown.Block, 1);
    blocks[0] = .{ .fenced_code = .{ .language = language, .code = code } };

    return .{ .blocks = blocks };
}

test {
    std.testing.refAllDecls(@This());
    _ = export_glyph_sheet;
    _ = export_test;
    _ = cli_input_test;
}
