const std = @import("std");
const editor = @import("editor.zig");

fn makeExecutable(dir: std.fs.Dir, name: []const u8, body: []const u8) !void {
    const file = try dir.createFile(name, .{ .mode = 0o755 });
    defer file.close();
    try file.writeAll(body);
}

fn tmpPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return tmp.dir.realpathAlloc(allocator, ".");
}

test "resolve prefers config, then VISUAL, then EDITOR" {
    const allocator = std.testing.allocator;
    const env: editor.Env = .{ .visual = "code --wait", .editor = "nano", .path = "" };

    const from_config = (try editor.resolve(allocator, "hx", env)).?;
    defer from_config.deinit(allocator);
    try std.testing.expectEqualStrings("hx", from_config.command);
    try std.testing.expectEqual(editor.Source.config, from_config.source);

    const from_visual = (try editor.resolve(allocator, "", env)).?;
    defer from_visual.deinit(allocator);
    try std.testing.expectEqualStrings("code --wait", from_visual.command);
    try std.testing.expectEqual(editor.Source.visual, from_visual.source);

    const from_editor = (try editor.resolve(allocator, "  ", .{ .visual = "", .editor = "nano", .path = "" })).?;
    defer from_editor.deinit(allocator);
    try std.testing.expectEqualStrings("nano", from_editor.command);
    try std.testing.expectEqual(editor.Source.editor, from_editor.source);

    // Nothing configured and nothing installed: no editor, not a guessed "vi".
    try std.testing.expect((try editor.resolve(allocator, "", .{ .path = "/nonexistent-dir" })) == null);
    try std.testing.expect((try editor.resolve(allocator, "", .{})) == null);
}

test "resolve falls back to the first known editor on PATH" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeExecutable(tmp.dir, "vi", "#!/bin/sh\n");
    try makeExecutable(tmp.dir, "nano", "#!/bin/sh\n");
    // Present but not executable: must be skipped.
    const plain = try tmp.dir.createFile("vim", .{ .mode = 0o644 });
    plain.close();

    const dir_path = try tmpPath(allocator, tmp);
    defer allocator.free(dir_path);
    const path_env = try std.fmt.allocPrint(allocator, "/nonexistent-dir:{s}", .{dir_path});
    defer allocator.free(path_env);

    const resolved = (try editor.resolve(allocator, "", .{ .path = path_env })).?;
    defer resolved.deinit(allocator);
    try std.testing.expectEqualStrings("vi", resolved.command);
    try std.testing.expectEqual(editor.Source.path, resolved.source);
}

test "programExists checks bare names on PATH and explicit paths directly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeExecutable(tmp.dir, "myedit", "#!/bin/sh\n");
    const dir_path = try tmpPath(allocator, tmp);
    defer allocator.free(dir_path);
    const full = try std.fmt.allocPrint(allocator, "{s}/myedit", .{dir_path});
    defer allocator.free(full);

    try std.testing.expect(editor.programExists(dir_path, "myedit"));
    try std.testing.expect(!editor.programExists(dir_path, "nosuchedit"));
    try std.testing.expect(editor.programExists(null, full));
    try std.testing.expect(!editor.programExists(null, "myedit"));
    try std.testing.expect(!editor.programExists(dir_path, ""));
}

test "openFile appends the path to a command with arguments" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeExecutable(tmp.dir, "fake-editor", "#!/bin/sh\nprintf '%s|' \"$@\" > \"$(dirname \"$0\")/args.txt\"\n");
    const dir_path = try tmpPath(allocator, tmp);
    defer allocator.free(dir_path);
    const command = try std.fmt.allocPrint(allocator, "'{s}/fake-editor' --wait -n", .{dir_path});
    defer allocator.free(command);

    try editor.openFile(allocator, command, "doc.md");

    const recorded = try tmp.dir.readFileAlloc(allocator, "args.txt", 1024);
    defer allocator.free(recorded);
    try std.testing.expectEqualStrings("--wait|-n|doc.md|", recorded);
}

test "openFile reports a missing program, a failing editor and a bad command" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeExecutable(tmp.dir, "failing-editor", "#!/bin/sh\nexit 3\n");
    const dir_path = try tmpPath(allocator, tmp);
    defer allocator.free(dir_path);
    const failing = try std.fmt.allocPrint(allocator, "{s}/failing-editor", .{dir_path});
    defer allocator.free(failing);

    try std.testing.expectError(error.EditorNotFound, editor.openFile(allocator, "/nonexistent-dir/nosuchedit", "doc.md"));
    try std.testing.expectError(error.EditorFailed, editor.openFile(allocator, failing, "doc.md"));
    try std.testing.expectError(error.InvalidEditorCommand, editor.openFile(allocator, "   ", "doc.md"));
    try std.testing.expectError(error.InvalidEditorCommand, editor.openFile(allocator, "vim 'oops", "doc.md"));
}
