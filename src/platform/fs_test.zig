const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs.zig");

const testing = std.testing;

const Scratch = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !Scratch {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Scratch) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn path(self: *Scratch, name: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ self.root, name });
    }

    fn read(self: *Scratch, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, name, testing.allocator, .limited(1024));
    }

    fn expectNoTemp(self: *Scratch) !void {
        var it = self.tmp.dir.iterate();
        while (try it.next(std.testing.io)) |entry| try testing.expect(std.mem.indexOf(u8, entry.name, ".mercat-tmp-") == null);
    }
};

fn expectContent(s: *Scratch, name: []const u8, want: []const u8) !void {
    const got = try s.read(name);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "writeOutput creates and replaces a regular file, keeping its mode" {
    var s = try Scratch.init();
    defer s.deinit();
    const out = try s.path("out.txt");
    defer testing.allocator.free(out);

    try fs.writeOutput(testing.allocator, out, "first");
    try expectContent(&s, "out.txt", "first");

    const file = try s.tmp.dir.openFile(std.testing.io, "out.txt", .{});
    try file.setPermissions(std.testing.io, @enumFromInt(0o640));
    file.close(std.testing.io);
    try fs.writeOutput(testing.allocator, out, "second");
    try expectContent(&s, "out.txt", "second");
    const st = try s.tmp.dir.statFile(std.testing.io, "out.txt", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o640), st.permissions.toMode() & 0o7777);
    try s.expectNoTemp();
}

test "writeOutput writes through a symlink instead of replacing it" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.tmp.dir.createDir(std.testing.io, "sub", .default_dir);
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/target.txt", .data = "old" });
    // A relative target resolves against the link's own directory.
    try s.tmp.dir.symLink(std.testing.io, "sub/target.txt", "link.txt", .{});
    try s.tmp.dir.symLink(std.testing.io, "link.txt", "link2.txt", .{});
    const link = try s.path("link2.txt");
    defer testing.allocator.free(link);

    try fs.writeOutput(testing.allocator, link, "new");
    try expectContent(&s, "sub/target.txt", "new");
    try testing.expectEqual(fs.Kind.symlink, try fs.kindOf(link, false));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("link.txt", buf[0..try s.tmp.dir.readLink(std.testing.io, "link2.txt", &buf)]);
    try s.expectNoTemp();
}

test "writeOutput through a dangling symlink creates its target" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.tmp.dir.symLink(std.testing.io, "made.txt", "dangling.txt", .{});
    const link = try s.path("dangling.txt");
    defer testing.allocator.free(link);

    try fs.writeOutput(testing.allocator, link, "hello");
    try expectContent(&s, "made.txt", "hello");
    try testing.expectEqual(fs.Kind.symlink, try fs.kindOf(link, false));
}

test "writeOutput refuses directories and symlink loops" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.tmp.dir.createDir(std.testing.io, "d", .default_dir);
    try s.tmp.dir.symLink(std.testing.io, "loop-b", "loop-a", .{});
    try s.tmp.dir.symLink(std.testing.io, "loop-a", "loop-b", .{});
    const dir = try s.path("d");
    defer testing.allocator.free(dir);
    const loop = try s.path("loop-a");
    defer testing.allocator.free(loop);

    try testing.expectError(error.IsDir, fs.writeOutput(testing.allocator, dir, "x"));
    try testing.expectError(error.SymLinkLoop, fs.writeOutput(testing.allocator, loop, "x"));
    try s.expectNoTemp();
}

fn drainFifo(path: []const u8, out: *[64]u8, len: *usize) void {
    const file = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch return;
    defer file.close(std.testing.io);
    var reader = file.readerStreaming(std.testing.io, &.{});
    len.* = reader.interface.readSliceShort(out) catch 0;
}

test "writeOutput writes into an existing fifo without replacing it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var s = try Scratch.init();
    defer s.deinit();
    const rc = std.os.linux.mknodat(s.tmp.dir.handle, "pipe", std.os.linux.S.IFIFO | 0o600, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    const pipe = try s.path("pipe");
    defer testing.allocator.free(pipe);

    var got: [64]u8 = undefined;
    var len: usize = 0;
    const reader = try std.Thread.spawn(.{}, drainFifo, .{ pipe, &got, &len });
    try fs.writeOutput(testing.allocator, pipe, "through the pipe");
    reader.join();
    try testing.expectEqualStrings("through the pipe", got[0..len]);
    try testing.expectEqual(fs.Kind.other, try fs.kindOf(pipe, false));
    try s.expectNoTemp();
}

test "over-long path components are errors, not traps" {
    const long = @as([300]u8, @splat('a')) ++ ".md";
    try testing.expectError(error.NameTooLong, fs.kindOf(long, true));
    try testing.expect(!fs.isDirectory(long));
    try testing.expect(!fs.isNonDirectory(long));
    try testing.expectError(error.NameTooLong, fs.writeOutput(testing.allocator, long, "x"));
    try testing.expectEqual(fs.Kind.missing, try fs.kindOf("no-such-dir/no-such-file", true));
}

test "writeOutput refuses a regular file it cannot write, as > does" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var s = try Scratch.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ro.txt", .data = "RO" });
    const file = try s.tmp.dir.openFile(std.testing.io, "ro.txt", .{});
    try file.setPermissions(std.testing.io, @enumFromInt(0o444));
    file.close(std.testing.io);
    const ro = try s.path("ro.txt");
    defer testing.allocator.free(ro);

    try testing.expectError(error.AccessDenied, fs.writeOutput(testing.allocator, ro, "new"));
    try expectContent(&s, "ro.txt", "RO");
    try s.expectNoTemp();
}

test "writeOutput keeps the inode of a file with other hard links" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var s = try Scratch.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "own.txt", .data = "x" });
    const rc = std.os.linux.linkat(s.tmp.dir.handle, "own.txt", s.tmp.dir.handle, "hard.txt", 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    const before = try s.tmp.dir.statFile(std.testing.io, "own.txt", .{});
    const own = try s.path("own.txt");
    defer testing.allocator.free(own);

    try fs.writeOutput(testing.allocator, own, "rendered");
    try expectContent(&s, "own.txt", "rendered");
    try expectContent(&s, "hard.txt", "rendered");
    try testing.expectEqual(before.inode, (try s.tmp.dir.statFile(std.testing.io, "own.txt", .{})).inode);
    try s.expectNoTemp();
}

test "writeOutput keeps the owner of another user's file" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var s = try Scratch.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "theirs.txt", .data = "x" });
    const file = try s.tmp.dir.openFile(std.testing.io, "theirs.txt", .{});
    try file.setOwner(std.testing.io, 65534, 65534);
    file.close(std.testing.io);
    const theirs = try s.path("theirs.txt");
    defer testing.allocator.free(theirs);

    try fs.writeOutput(testing.allocator, theirs, "rendered");
    try expectContent(&s, "theirs.txt", "rendered");
    var stx: std.os.linux.Statx = undefined;
    const st_rc = std.os.linux.statx(s.tmp.dir.handle, "theirs.txt", 0, .{ .UID = true, .GID = true }, &stx);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(st_rc));
    try testing.expectEqual(@as(std.posix.uid_t, 65534), stx.uid);
    try testing.expectEqual(@as(std.posix.gid_t, 65534), stx.gid);
    try s.expectNoTemp();
}
