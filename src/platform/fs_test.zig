const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs.zig");

const testing = std.testing;

const Scratch = struct {
    tmp: testing.TmpDir,
    root: []u8,

    fn init() !Scratch {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
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
        return self.tmp.dir.readFileAlloc(testing.allocator, name, 1024);
    }

    fn expectNoTemp(self: *Scratch) !void {
        var it = self.tmp.dir.iterate();
        while (try it.next()) |entry| try testing.expect(std.mem.indexOf(u8, entry.name, ".mercat-tmp-") == null);
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

    const file = try s.tmp.dir.openFile("out.txt", .{});
    try file.chmod(0o640);
    file.close();
    try fs.writeOutput(testing.allocator, out, "second");
    try expectContent(&s, "out.txt", "second");
    const st = try s.tmp.dir.statFile("out.txt");
    try testing.expectEqual(@as(std.fs.File.Mode, 0o640), st.mode & 0o7777);
    try s.expectNoTemp();
}

test "writeOutput writes through a symlink instead of replacing it" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.tmp.dir.makeDir("sub");
    try s.tmp.dir.writeFile(.{ .sub_path = "sub/target.txt", .data = "old" });
    // A relative target resolves against the link's own directory.
    try s.tmp.dir.symLink("sub/target.txt", "link.txt", .{});
    try s.tmp.dir.symLink("link.txt", "link2.txt", .{});
    const link = try s.path("link2.txt");
    defer testing.allocator.free(link);

    try fs.writeOutput(testing.allocator, link, "new");
    try expectContent(&s, "sub/target.txt", "new");
    try testing.expectEqual(fs.Kind.symlink, try fs.kindOf(link, false));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("link.txt", try s.tmp.dir.readLink("link2.txt", &buf));
    try s.expectNoTemp();
}

test "writeOutput through a dangling symlink creates its target" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.tmp.dir.symLink("made.txt", "dangling.txt", .{});
    const link = try s.path("dangling.txt");
    defer testing.allocator.free(link);

    try fs.writeOutput(testing.allocator, link, "hello");
    try expectContent(&s, "made.txt", "hello");
    try testing.expectEqual(fs.Kind.symlink, try fs.kindOf(link, false));
}

test "writeOutput refuses directories and symlink loops" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.tmp.dir.makeDir("d");
    try s.tmp.dir.symLink("loop-b", "loop-a", .{});
    try s.tmp.dir.symLink("loop-a", "loop-b", .{});
    const dir = try s.path("d");
    defer testing.allocator.free(dir);
    const loop = try s.path("loop-a");
    defer testing.allocator.free(loop);

    try testing.expectError(error.IsDir, fs.writeOutput(testing.allocator, dir, "x"));
    try testing.expectError(error.SymLinkLoop, fs.writeOutput(testing.allocator, loop, "x"));
    try s.expectNoTemp();
}

fn drainFifo(path: []const u8, out: *[64]u8, len: *usize) void {
    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();
    len.* = file.readAll(out) catch 0;
}

test "writeOutput writes into an existing fifo without replacing it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var s = try Scratch.init();
    defer s.deinit();
    const rc = std.os.linux.mknodat(s.tmp.dir.fd, "pipe", std.os.linux.S.IFIFO | 0o600, 0);
    if (std.os.linux.E.init(rc) != .SUCCESS) return error.SkipZigTest;
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
    const long = "a" ** 300 ++ ".md";
    try testing.expectError(error.NameTooLong, fs.kindOf(long, true));
    try testing.expect(!fs.isDirectory(long));
    try testing.expect(!fs.isNonDirectory(long));
    try testing.expectError(error.NameTooLong, fs.writeOutput(testing.allocator, long, "x"));
    try testing.expectEqual(fs.Kind.missing, try fs.kindOf("no-such-dir/no-such-file", true));
}
