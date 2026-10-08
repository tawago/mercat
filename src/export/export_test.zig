const std = @import("std");
const build_options = @import("build_options");

const testing = std.testing;

const mercat_exe_path = build_options.mercat_exe_path;

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

fn requireBinary() !void {
    std.fs.cwd().access(mercat_exe_path, .{}) catch return error.SkipZigTest;
}

fn runMercat(allocator: std.mem.Allocator, extra_args: []const []const u8) !Run {
    return runMercatWithEnv(allocator, extra_args, &.{});
}

const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

const steering_env_names = [_][]const u8{
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

test "plain output defaults to 120 columns off a terminal and -w bounds it" {
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
    const w60 = try runMercat(allocator, &.{ "--format", "plain", "-w", "60", in_path });
    defer w60.deinit(allocator);
    try testing.expect(w60.exited_zero);

    try testing.expectEqualSlices(u8, w120.stdout, def.stdout);
    try testing.expect(!std.mem.eql(u8, w60.stdout, def.stdout));
    try testing.expect(maxLineBytes(def.stdout) <= 120);
    try testing.expect(maxLineBytes(def.stdout) > 60);
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
