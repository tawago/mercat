const std = @import("std");
const args = @import("cli/args.zig");
const renderer = @import("cli/renderer.zig");
const pager = @import("cli/pager.zig");
const stdin = @import("cli/stdin.zig");
const config = @import("core/config.zig");
const markdown = @import("core/markdown.zig");
const render_model = @import("core/render_model.zig");
const theme = @import("core/theme.zig");
const plain = @import("export/plain.zig");
// Backend-neutral export document + layout. Not yet
// used by the terminal/plain paths; imported so its unit tests run under the
// main `zig build test` graph (the PNG backend wires it into the output path).
const export_types = @import("export/types.zig");
const export_layout = @import("export/layout.zig");
const export_font = @import("export/font.zig");
const export_png = @import("export/png.zig");
// Glyph-sheet fixture + export verification suite.
// Imported so their tests run under the main `zig build test` graph.
const export_glyph_sheet = @import("export/glyph_sheet.zig");
const export_test = @import("export/export_test.zig");
const terminal = @import("platform/terminal.zig");
const tui = @import("tui/app.zig");

const VERSION = @import("build_options").version;

// Two layers gate log output so it never corrupts the TUI alternate screen:
//
//   1. Level cap. The mermaid_v2 pipeline emits `std.log.debug` diagnostics
//      (validate/raster integrity counts) that the codebase treats as
//      "Debug-only, never affects output" — but the Debug build's default log
//      level is `.debug`, so they spill to stderr. Capping at `.warn` in every
//      build mode drops those.
//   2. Runtime gate. `.warn`-level messages (e.g. "mermaid_v2: diagram
//      clipped: ...") are genuine problems worth printing on the CLI path, but
//      while vaxis owns the alternate screen any stderr write lands on top of
//      the UI and every re-render prints another line. `tui_active` is set for
//      the duration of the TUI event loop; while it is set, `logFn` drops the
//      message. CLI mode leaves the flag clear, so warnings still reach stderr.
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

fn showVersion(allocator: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("mercat ");
    try stdout.writeAll(VERSION);

    // Try to fetch latest version from GitHub API
    if (fetchLatestVersion(allocator)) |latest| {
        defer allocator.free(latest);
        try stdout.writeAll(" (latest: ");
        try stdout.writeAll(latest);
        try stdout.writeAll(")");
    } else |_| {
        // Silently continue if latest version check fails
    }

    try stdout.writeAll("\n");
}

fn fetchLatestVersion(allocator: std.mem.Allocator) ![]u8 {
    // Try using curl if available
    var child = std.process.Child.init(&.{
        "curl",
        "-s",
        "--max-time",
        "2",
        "https://api.github.com/repos/tawago/mercat/releases/latest",
    }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 8192);
    defer allocator.free(stdout);

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        return error.FetchFailed;
    }

    // Parse JSON to find tag_name
    if (std.mem.indexOf(u8, stdout, "\"tag_name\":\"")) |start| {
        const begin = start + 12; // Length of "\"tag_name\":\""
        if (std.mem.indexOf(u8, stdout[begin..], "\"")) |end| {
            const tag = stdout[begin .. begin + end];
            // Return the tag without the 'v' prefix if present
            const version = if (std.mem.startsWith(u8, tag, "v"))
                tag[1..]
            else
                tag;
            return try allocator.dupe(u8, version);
        }
    }

    return error.ParseFailed;
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
            try showVersion(allocator);
            return;
        },
        else => return err,
    };
    defer parsed.deinit(allocator);

    var loaded_config = try config.load(allocator);
    defer loaded_config.deinit(allocator);

    const content = try readInput(allocator, parsed.input);
    defer allocator.free(content);

    const active_theme = parsed.effectiveTheme(loaded_config.display.theme);
    const show_heading_markers = parsed.effectiveHeadingMarkers(loaded_config.display.heading_markers);
    // §5.3: terminal output keeps the terminal-aware resolution; plain/png
    // output resolve explicit -w > configured non-zero width > 120 and never
    // consult the terminal.
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
        // Gate warnings while vaxis owns the alternate screen (see `logFn`); the
        // flag is cleared on return so a later CLI invocation still prints.
        tui_active.store(true, .monotonic);
        defer tui_active.store(false, .monotonic);
        try tui.run(allocator, inputTitle(parsed.input), parsed.input, content, loaded_config.general.editor, active_theme, loaded_config.display.syntax_theme, show_heading_markers, loaded_config.display.frontmatter, parsed.force_layout orelse .auto, loaded_config.mermaid.subgraph_edges);
        return;
    }

    var document = if (isMermaidFile(parsed.input))
        try createMermaidDocument(allocator, content)
    else
        try markdown.parse(allocator, content);
    defer document.deinit(allocator);

    // §6.1: build the render model exactly once, then dispatch on format.
    var rendered = try render_model.renderDocument(allocator, document, .{
        .width = render_width,
        .show_heading_markers = show_heading_markers,
        .frontmatter_style = loaded_config.display.frontmatter,
        .mermaid_box_style = parsed.box_style orelse .standard,
        .mermaid_crossing_heuristic = parsed.crossing_heuristic orelse .median,
        .mermaid_force_layout = parsed.force_layout orelse .auto,
        .mermaid_aspect_ratio = parsed.aspect_ratio orelse 1.0,
        .mermaid_debug = parsed.debug_mermaid,
        // Subgraph-border notation is a config value (owner ruling
        // 2026-07-19); config stores the shared `prim.SubgraphEdges` directly,
        // so it flows through with no enum translation.
        .mermaid_subgraph_edges = loaded_config.mermaid.subgraph_edges,
    });
    defer rendered.deinit(allocator);

    switch (parsed.format) {
        .terminal => {
            const output = try renderer.serialize(
                allocator,
                rendered,
                theme.palette(active_theme, loaded_config.display.syntax_theme),
            );
            defer allocator.free(output);
            try pager.writeOutput(allocator, output, loaded_config.general.pager, parsed.pager);
        },
        .plain => {
            // §20: every export failure class reports the shared context (input
            // path, format, output path, width) plus a failure-specific detail
            // on one stderr line, then exits non-zero.
            const ctx = ExportContext{
                .input_path = inputTitle(parsed.input),
                .format = "plain",
                .output_path = parsed.output_path,
                .width = render_width,
            };
            exportPlain(allocator, rendered, parsed.output_path) catch |err| {
                var buf: [192]u8 = undefined;
                exportFailure(ctx, exportDetail(&buf, err, .{}));
            };
        },
        .png => {
            // §5.2: PNG is binary and always targets a file (parse-time
            // validation guarantees --output is present), so it never writes to
            // an interactive terminal.
            const output_path = parsed.output_path orelse return error.PngRequiresOutput;

            const options = export_layout.Options{
                .palette = theme.palette(active_theme, loaded_config.display.syntax_theme),
                .color_mode = if (parsed.monochrome) .monochrome else .theme,
            };

            const ctx = ExportContext{
                .input_path = inputTitle(parsed.input),
                .format = "png",
                .output_path = output_path,
                .width = render_width,
            };

            var diag: export_png.Diagnostic = .{};
            exportPng(allocator, rendered, options, output_path, &diag) catch |err| {
                var buf: [192]u8 = undefined;
                exportFailure(ctx, exportDetail(&buf, err, diag));
            };
        },
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
        // Encode/write/rename/open failures surface under their Zig error name.
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
    // One embedded JetBrains Mono face at the export pixel height; the layout
    // and painter both read metrics/glyphs from it. A font-init failure is
    // remapped to a typed error so the §20 diagnostic can name it.
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

fn readInput(allocator: std.mem.Allocator, input: args.Input) ![]u8 {
    return switch (input) {
        .stdin => std.fs.File.stdin().readToEndAlloc(allocator, std.math.maxInt(usize)),
        .file => |path| blk: {
            const cwd = std.fs.cwd();
            break :blk try cwd.readFileAlloc(allocator, path, std.math.maxInt(usize));
        },
        .none => if (stdin.shouldReadImplicitStdin())
            std.fs.File.stdin().readToEndAlloc(allocator, std.math.maxInt(usize))
        else
            error.MissingInput,
    };
}

fn isMermaidFile(input: args.Input) bool {
    return switch (input) {
        .file => |path| std.mem.endsWith(u8, path, ".mmd"),
        else => false,
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
    // Explicitly pull the imported files' `test` blocks into this test binary.
    // `refAllDecls` references decls but does not, on its own, collect tests
    // from imported files; `_ = @import(...)` does.
    _ = export_glyph_sheet;
    _ = export_test;
}
