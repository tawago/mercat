const std = @import("std");
const process = @import("process.zig");

/// Editors probed on $PATH, in order, when neither the config nor the
/// environment names one.
pub const fallback_editors = [_][]const u8{ "nvim", "vim", "vi", "nano" };

pub const Source = enum { config, visual, editor, path };

/// An editor command line (program plus arguments), owned by the caller.
pub const Resolved = struct {
    command: []u8,
    source: Source,

    pub fn deinit(self: Resolved, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
    }
};

/// Inputs for `resolve`, split out so tests can supply a fake environment.
pub const Env = struct {
    visual: ?[]const u8 = null,
    editor: ?[]const u8 = null,
    path: ?[]const u8 = null,

    pub fn fromProcess() Env {
        return .{
            .visual = std.posix.getenv("VISUAL"),
            .editor = std.posix.getenv("EDITOR"),
            .path = std.posix.getenv("PATH"),
        };
    }
};

/// Picks the editor command: config `general.editor` (if non-empty), then
/// $VISUAL, then $EDITOR, then the first of `fallback_editors` found on $PATH.
/// Returns null when nothing is configured and no fallback is installed.
pub fn resolve(allocator: std.mem.Allocator, configured: []const u8, env: Env) !?Resolved {
    const candidates = [_]struct { value: ?[]const u8, source: Source }{
        .{ .value = configured, .source = .config },
        .{ .value = env.visual, .source = .visual },
        .{ .value = env.editor, .source = .editor },
    };
    for (candidates) |candidate| {
        const value = candidate.value orelse continue;
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) continue;
        return .{ .command = try allocator.dupe(u8, trimmed), .source = candidate.source };
    }
    for (fallback_editors) |name| {
        if (findInPath(env.path, name)) {
            return .{ .command = try allocator.dupe(u8, name), .source = .path };
        }
    }
    return null;
}

/// True when `program` is an executable reachable as given: a path containing
/// '/' is checked directly; a bare name is searched in the ':'-separated `path_env`.
pub fn programExists(path_env: ?[]const u8, program: []const u8) bool {
    if (program.len == 0) return false;
    if (std.mem.indexOfScalar(u8, program, '/') != null) return isExecutable(program);
    return findInPath(path_env, program);
}

fn findInPath(path_env: ?[]const u8, name: []const u8) bool {
    const path = path_env orelse return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var dirs = std.mem.tokenizeScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (isExecutable(full)) return true;
    }
    return false;
}

fn isExecutable(path: []const u8) bool {
    std.posix.access(path, std.posix.X_OK) catch return false;
    return @import("fs.zig").isNonDirectory(path);
}

/// The program name of an editor command (its first word), for messages.
pub fn programName(allocator: std.mem.Allocator, editor_command: []const u8) ![]u8 {
    var command = process.splitCommand(allocator, editor_command) catch return allocator.dupe(u8, editor_command);
    defer command.deinit(allocator);
    if (command.argv.len == 0) return allocator.dupe(u8, editor_command);
    return allocator.dupe(u8, command.argv[0]);
}

pub const OpenError = error{
    /// The command is empty or has an unterminated quote.
    InvalidEditorCommand,
    /// The program could not be found or executed.
    EditorNotFound,
    /// The editor ran but exited non-zero or was killed by a signal.
    EditorFailed,
} || std.mem.Allocator.Error;

/// Runs `editor_command` (which may carry arguments, e.g. "code --wait") with
/// `file_path` appended, inheriting the terminal, and waits for it to exit.
pub fn openFile(allocator: std.mem.Allocator, editor_command: []const u8, file_path: []const u8) OpenError!void {
    return openFileNotify(allocator, editor_command, file_path, null);
}

/// Like `openFile`, but calls `on_spawn` with the editor's pid once it runs.
pub fn openFileNotify(
    allocator: std.mem.Allocator,
    editor_command: []const u8,
    file_path: []const u8,
    on_spawn: ?*const fn (std.process.Child.Id) void,
) OpenError!void {
    var command = process.splitCommand(allocator, editor_command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEditorCommand,
    };
    defer command.deinit(allocator);
    if (command.argv.len == 0) return error.InvalidEditorCommand;

    const argv = try allocator.alloc([]const u8, command.argv.len + 1);
    defer allocator.free(argv);
    for (command.argv, 0..) |part, index| argv[index] = part;
    argv[command.argv.len] = file_path;

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EditorNotFound,
    };
    if (on_spawn) |notify| notify(child.id);
    // An exec failure (missing program, no permission) is only reported by
    // wait(), through the child's error pipe.
    const term = child.wait() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.AccessDenied, error.InvalidExe, error.NotDir, error.IsDir => return error.EditorNotFound,
        else => return error.EditorFailed,
    };
    switch (term) {
        .Exited => |code| if (code != 0) return error.EditorFailed,
        else => return error.EditorFailed,
    }
}

test "editor command splits and appends path" {
    const allocator = std.testing.allocator;
    var command = try process.splitCommand(allocator, "nvim -u NONE");
    defer command.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), command.argv.len);
    try std.testing.expectEqualStrings("nvim", command.argv[0]);
}

test {
    _ = @import("editor_test.zig");
}
