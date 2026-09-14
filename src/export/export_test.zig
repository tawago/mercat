//! Export verification suite that must observe real process behavior:
//! separate-process PNG determinism and end-to-end CLI behavior
//! (§8.3). These tests spawn the installed `mercat` binary rather than calling
//! library functions, so they cover argument dispatch, width resolution, input
//! selection, atomic file replacement, and the no-pager-for-file-output rule
//! exactly as a user would hit them.
//!
//! The absolute path to the freshly installed binary is injected by `build.zig`
//! as `build_options.mercat_exe_path`; `zig build test` depends on the install step
//! so the binary exists when these run. When the binary is absent (e.g. a
//! module compiled outside the normal build graph) every test skips rather than
//! failing.

const std = @import("std");
const build_options = @import("build_options");

const testing = std.testing;

const mercat_exe_path = build_options.mercat_exe_path;

/// Result of one `mercat` invocation.
const Run = struct {
    exited_zero: bool,
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Skip the whole test when the built binary is not present.
fn requireBinary() !void {
    std.fs.cwd().access(mercat_exe_path, .{}) catch return error.SkipZigTest;
}

/// Run `mercat <extra_args...>` with no stdin. Returns captured stdout/stderr and
/// the exit status. `argv0` is prepended automatically.
fn runMercat(allocator: std.mem.Allocator, extra_args: []const []const u8) !Run {
    return runMercatWithEnv(allocator, extra_args, &.{});
}

const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

const steering_env_names = [_][]const u8{
    "MERCAT_FORCE_RUNG",
    "MERCAT_SCORE_OFF",
    "MERCAT_SCORE_SHADOW",
    "MERCAT_INTEGRITY",
    "MERCAT_WIDTH",
    "MERCAT_THEME",
    "MERCAT_SYNTAX_THEME",
    "MERCAT_FRONTMATTER",
    "MERCAT_SUBGRAPH_EDGES",
};

fn childEnv(allocator: std.mem.Allocator, config_home: []const u8, overrides: []const EnvVar) !std.process.EnvMap {
    var env = try std.process.getEnvMap(allocator);
    errdefer env.deinit();
    for (steering_env_names) |name| env.remove(name);
    try env.put("HOME", config_home);
    try env.put("XDG_CONFIG_HOME", config_home);
    for (overrides) |item| try env.put(item.name, item.value);
    return env;
}

/// A child environment rooted in a fresh temporary config home.
const ChildEnv = struct {
    tmp: testing.TmpDir,
    env: std.process.EnvMap,

    fn init(allocator: std.mem.Allocator, overrides: []const EnvVar) !ChildEnv {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const config_home = try tmp.dir.realpathAlloc(allocator, ".");
        defer allocator.free(config_home);
        return .{ .tmp = tmp, .env = try childEnv(allocator, config_home, overrides) };
    }

    fn deinit(self: *ChildEnv) void {
        self.env.deinit();
        self.tmp.cleanup();
    }
};

fn runMercatWithEnv(allocator: std.mem.Allocator, extra_args: []const []const u8, overrides: []const EnvVar) !Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, mercat_exe_path);
    for (extra_args) |a| try argv.append(allocator, a);

    var child_env = try ChildEnv.init(allocator, overrides);
    defer child_env.deinit();

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .env_map = &child_env.env,
        .max_output_bytes = 16 * 1024 * 1024,
    });
    return .{
        .exited_zero = result.term == .Exited and result.term.Exited == 0,
        .exit_code = if (result.term == .Exited) result.term.Exited else 255,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// Run `mercat <extra_args...>` feeding `stdin_bytes` on stdin (for the `-` path).
fn runMercatStdin(allocator: std.mem.Allocator, extra_args: []const []const u8, stdin_bytes: []const u8) !Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, mercat_exe_path);
    for (extra_args) |a| try argv.append(allocator, a);

    var child_env = try ChildEnv.init(allocator, &.{});
    defer child_env.deinit();

    var child = std.process.Child.init(argv.items, allocator);
    child.env_map = &child_env.env;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    try child.stdin.?.writeAll(stdin_bytes);
    child.stdin.?.close();
    child.stdin = null;

    const out = try child.stdout.?.readToEndAlloc(allocator, 16 * 1024 * 1024);
    errdefer allocator.free(out);
    const err = try child.stderr.?.readToEndAlloc(allocator, 16 * 1024 * 1024);
    errdefer allocator.free(err);
    const term = try child.wait();
    return .{
        .exited_zero = term == .Exited and term.Exited == 0,
        .exit_code = if (term == .Exited) term.Exited else 255,
        .stdout = out,
        .stderr = err,
    };
}

/// Absolute path inside a tmp dir.
fn tmpPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, name });
}

fn writeTmpFile(tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8) !void {
    const f = try tmp.dir.createFile(name, .{});
    defer f.close();
    try f.writeAll(bytes);
}

/// Widest line by byte length (fixtures here are ASCII, so bytes == columns).
fn maxLineBytes(text: []const u8) usize {
    var it = std.mem.splitScalar(u8, text, '\n');
    var m: usize = 0;
    while (it.next()) |line| m = @max(m, line.len);
    return m;
}

const wide_markdown =
    "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod " ++
    "tempor incididunt ut labore et dolore magna aliqua ut enim ad minim " ++
    "veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea " ++
    "commodo consequat duis aute irure dolor in reprehenderit in voluptate\n";

const sample_mermaid = "flowchart TD\n  A[Start] --> B[Middle]\n  B --> C[End]\n";

test "two separate-process PNG exports are byte-identical" {
    try requireBinary();
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(&tmp, "in.mmd", sample_mermaid);
    const in_path = try tmpPath(allocator, &tmp, "in.mmd");
    defer allocator.free(in_path);
    const out_a = try tmpPath(allocator, &tmp, "a.png");
    defer allocator.free(out_a);
    const out_b = try tmpPath(allocator, &tmp, "b.png");
    defer allocator.free(out_b);

    const r1 = try runMercat(allocator, &.{ "--format", "png", "--monochrome", "-w", "90", "-o", out_a, in_path });
    defer r1.deinit(allocator);
    try testing.expect(r1.exited_zero);
    const r2 = try runMercat(allocator, &.{ "--format", "png", "--monochrome", "-w", "90", "-o", out_b, in_path });
    defer r2.deinit(allocator);
    try testing.expect(r2.exited_zero);

    const bytes_a = try tmp.dir.readFileAlloc(allocator, "a.png", 16 * 1024 * 1024);
    defer allocator.free(bytes_a);
    const bytes_b = try tmp.dir.readFileAlloc(allocator, "b.png", 16 * 1024 * 1024);
    defer allocator.free(bytes_b);
    try testing.expect(bytes_a.len > 0);
    try testing.expectEqualSlices(u8, bytes_a, bytes_b);
    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", bytes_a[0..8]);
}

test "non-terminal plain output defaults to 120 columns" {
    try requireBinary();
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(&tmp, "wide.md", wide_markdown);
    const in_path = try tmpPath(allocator, &tmp, "wide.md");
    defer allocator.free(in_path);

    const def = try runMercat(allocator, &.{ "--format", "plain", in_path });
    defer def.deinit(allocator);
    try testing.expect(def.exited_zero);
    const w120 = try runMercat(allocator, &.{ "--format", "plain", "-w", "120", in_path });
    defer w120.deinit(allocator);
    const w90 = try runMercat(allocator, &.{ "--format", "plain", "-w", "90", in_path });
    defer w90.deinit(allocator);

    try testing.expectEqualSlices(u8, w120.stdout, def.stdout);
    try testing.expect(!std.mem.eql(u8, w90.stdout, def.stdout));
    try testing.expect(maxLineBytes(def.stdout) <= 120);
    try testing.expect(maxLineBytes(def.stdout) > 90);
}

test "explicit 60/90/120 widths bound the output width" {
    try requireBinary();
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(&tmp, "wide.md", wide_markdown);
    const in_path = try tmpPath(allocator, &tmp, "wide.md");
    defer allocator.free(in_path);

    inline for (.{ "60", "90", "120" }) |w| {
        const r = try runMercat(allocator, &.{ "--format", "plain", "-w", w, in_path });
        defer r.deinit(allocator);
        try testing.expect(r.exited_zero);
        try testing.expect(maxLineBytes(r.stdout) <= comptime std.fmt.parseInt(usize, w, 10) catch unreachable);
    }

    const w60 = try runMercat(allocator, &.{ "--format", "plain", "-w", "60", in_path });
    defer w60.deinit(allocator);
    const w120 = try runMercat(allocator, &.{ "--format", "plain", "-w", "120", in_path });
    defer w120.deinit(allocator);
    try testing.expect(!std.mem.eql(u8, w60.stdout, w120.stdout));
    try testing.expect(maxLineBytes(w60.stdout) <= 60);
}

test "renders a .mmd flowchart to plain text with box-drawing" {
    try requireBinary();
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(&tmp, "g.mmd", sample_mermaid);
    const in_path = try tmpPath(allocator, &tmp, "g.mmd");
    defer allocator.free(in_path);

    const r = try runMercat(allocator, &.{ "--format", "plain", "-w", "80", in_path });
    defer r.deinit(allocator);
    try testing.expect(r.exited_zero);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Start") != null);
    const has_box = std.mem.indexOf(u8, r.stdout, "\u{2500}") != null or
        std.mem.indexOf(u8, r.stdout, "\u{2502}") != null;
    try testing.expect(has_box);
    try testing.expect(std.mem.indexOfScalar(u8, r.stdout, 0x1b) == null);
}

test "renders a Markdown file to plain text" {
    try requireBinary();
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(&tmp, "doc.md", "# Heading One\n\nSome body text.\n");
    const in_path = try tmpPath(allocator, &tmp, "doc.md");
    defer allocator.free(in_path);

    const r = try runMercat(allocator, &.{ "--format", "plain", "-w", "80", in_path });
    defer r.deinit(allocator);
    try testing.expect(r.exited_zero);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Heading One") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Some body text.") != null);
}

test "reads Markdown from stdin via -" {
    try requireBinary();
    const allocator = testing.allocator;

    const r = try runMercatStdin(allocator, &.{ "--format", "plain", "-w", "80", "-" }, "# Piped Title\n\nhello world\n");
    defer r.deinit(allocator);
    try testing.expect(r.exited_zero);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Piped Title") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "hello world") != null);
}

test "plain file output writes the file and emits nothing to stdout (no pager)" {
    try requireBinary();
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(&tmp, "doc.md", "# Title\n\nbody\n");
    const in_path = try tmpPath(allocator, &tmp, "doc.md");
    defer allocator.free(in_path);
    const out_path = try tmpPath(allocator, &tmp, "out.txt");
    defer allocator.free(out_path);

    const r = try runMercat(allocator, &.{ "--format", "plain", "-w", "80", "-o", out_path, in_path });
    defer r.deinit(allocator);
    try testing.expect(r.exited_zero);
    try testing.expectEqual(@as(usize, 0), r.stdout.len);

    const written = try tmp.dir.readFileAlloc(allocator, "out.txt", 16 * 1024 * 1024);
    defer allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "Title") != null);
}

test "png file output emits nothing to stdout and re-export replaces the file atomically" {
    try requireBinary();
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTmpFile(&tmp, "g.mmd", sample_mermaid);
    const in_path = try tmpPath(allocator, &tmp, "g.mmd");
    defer allocator.free(in_path);
    const out_path = try tmpPath(allocator, &tmp, "diagram.png");
    defer allocator.free(out_path);

    const first = try runMercat(allocator, &.{ "--format", "png", "--monochrome", "-w", "90", "-o", out_path, in_path });
    defer first.deinit(allocator);
    try testing.expect(first.exited_zero);
    try testing.expectEqual(@as(usize, 0), first.stdout.len);
    const bytes1 = try tmp.dir.readFileAlloc(allocator, "diagram.png", 16 * 1024 * 1024);
    defer allocator.free(bytes1);
    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", bytes1[0..8]);

    const second = try runMercat(allocator, &.{ "--format", "png", "--monochrome", "-w", "90", "-o", out_path, in_path });
    defer second.deinit(allocator);
    try testing.expect(second.exited_zero);
    const bytes2 = try tmp.dir.readFileAlloc(allocator, "diagram.png", 16 * 1024 * 1024);
    defer allocator.free(bytes2);
    try testing.expectEqualSlices(u8, bytes1, bytes2);

    var it = tmp.dir.iterate();
    while (try it.next()) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, ".mercat-tmp-") == null);
    }
}

test "png export of an uncovered glyph fails without leaving a file" {
    try requireBinary();
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTmpFile(&tmp, "emoji.md", "# Oops \u{1F4A9}\n");
    const in_path = try tmpPath(allocator, &tmp, "emoji.md");
    defer allocator.free(in_path);
    const out_path = try tmpPath(allocator, &tmp, "should_not_exist.png");
    defer allocator.free(out_path);

    const r = try runMercat(allocator, &.{ "--format", "png", "-w", "80", "-o", out_path, in_path });
    defer r.deinit(allocator);
    try testing.expect(!r.exited_zero);
    try testing.expectError(error.FileNotFound, tmp.dir.access("should_not_exist.png", .{}));
    var it = tmp.dir.iterate();
    while (try it.next()) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, ".mercat-tmp-") == null);
    }
}

test "invalid format/output combinations exit non-zero end-to-end" {
    try requireBinary();
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(&tmp, "doc.md", "# Title\n");
    const in_path = try tmpPath(allocator, &tmp, "doc.md");
    defer allocator.free(in_path);
    const out_path = try tmpPath(allocator, &tmp, "out");
    defer allocator.free(out_path);

    {
        const r = try runMercat(allocator, &.{ "--format", "png", in_path });
        defer r.deinit(allocator);
        try testing.expect(!r.exited_zero);
    }
    {
        const r = try runMercat(allocator, &.{ "-o", out_path, in_path });
        defer r.deinit(allocator);
        try testing.expect(!r.exited_zero);
    }
    {
        const r = try runMercat(allocator, &.{ "--format", "png", "-o", out_path, "-p", in_path });
        defer r.deinit(allocator);
        try testing.expect(!r.exited_zero);
    }
    {
        const r = try runMercat(allocator, &.{ "--format", "svg", in_path });
        defer r.deinit(allocator);
        try testing.expect(!r.exited_zero);
    }
}

test "valid format/output combinations succeed end-to-end" {
    try requireBinary();
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(&tmp, "doc.md", "# Title\n\nbody\n");
    const in_path = try tmpPath(allocator, &tmp, "doc.md");
    defer allocator.free(in_path);
    const txt_path = try tmpPath(allocator, &tmp, "out.txt");
    defer allocator.free(txt_path);

    {
        const r = try runMercat(allocator, &.{ "--format", "plain", "-w", "80", in_path });
        defer r.deinit(allocator);
        try testing.expect(r.exited_zero);
        try testing.expect(r.stdout.len > 0);
    }
    {
        const r = try runMercat(allocator, &.{ "--format", "plain", "-w", "80", "-o", txt_path, in_path });
        defer r.deinit(allocator);
        try testing.expect(r.exited_zero);
    }
    {
        const r = try runMercat(allocator, &.{ "--monochrome", in_path });
        defer r.deinit(allocator);
        try testing.expect(r.exited_zero);
        try testing.expect(r.stdout.len > 0);
    }
}
