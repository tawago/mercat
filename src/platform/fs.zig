//! File system helpers for the paths mercat reads and writes.
//!
//! Everything here reports errors instead of trapping: `std.fs.Dir.statFile`
//! treats an over-long path component as unreachable on Linux, so input and
//! output paths are examined with `posix.fstatat`, which returns
//! `error.NameTooLong`.
const std = @import("std");
const posix = std.posix;

pub const Kind = enum { missing, directory, regular, symlink, other };

pub const StatError = posix.FStatAtError;

/// What `path` names. A missing path (or one under a non-directory) is
/// `.missing`, not an error. With `follow`, symlinks are resolved first, so
/// a dangling symlink is `.missing`.
pub fn kindOf(path: []const u8, follow: bool) StatError!Kind {
    const flags: u32 = if (follow) 0 else posix.AT.SYMLINK_NOFOLLOW;
    const st = posix.fstatat(std.fs.cwd().fd, path, flags) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    return kindFromMode(st.mode);
}

fn kindFromMode(mode: posix.mode_t) Kind {
    if (posix.S.ISDIR(mode)) return .directory;
    if (posix.S.ISREG(mode)) return .regular;
    if (posix.S.ISLNK(mode)) return .symlink;
    return .other;
}

/// Whether `path` names a directory (following symlinks); false on any error.
pub fn isDirectory(path: []const u8) bool {
    return (kindOf(path, true) catch return false) == .directory;
}

/// Whether `path` exists and is not a directory; false on any error.
pub fn isNonDirectory(path: []const u8) bool {
    return switch (kindOf(path, true) catch return false) {
        .missing, .directory => false,
        else => true,
    };
}

pub const WriteError = std.fs.File.OpenError || std.fs.File.WriteError || std.fs.File.ChmodError ||
    std.fs.File.SetEndPosError ||
    posix.RenameError || posix.ReadLinkError || StatError || std.mem.Allocator.Error;

const max_symlink_hops = 40;

/// The path that writing to `path` really changes: symlinks are followed
/// (relative targets resolve against the link's directory) until a path that
/// is not a symlink, which may not exist yet. Caller frees the result.
pub fn resolveOutputPath(allocator: std.mem.Allocator, path: []const u8) (WriteError || error{SymLinkLoop})![]u8 {
    var current = try allocator.dupe(u8, path);
    errdefer allocator.free(current);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var hops: usize = 0;
    while (try kindOf(current, false) == .symlink) : (hops += 1) {
        if (hops == max_symlink_hops) return error.SymLinkLoop;
        const target = try posix.readlink(current, &link_buf);
        const next = if (std.fs.path.isAbsolute(target) or std.fs.path.dirname(current) == null)
            try allocator.dupe(u8, target)
        else
            try std.fs.path.join(allocator, &.{ std.fs.path.dirname(current).?, target });
        allocator.free(current);
        current = next;
    }
    return current;
}

/// Writes `bytes` to the output file `path` the way a shell redirection
/// would, but without ever leaving a half-written regular file:
///
/// - symlinks are written through, never replaced (a dangling one creates
///   its target);
/// - a new file, or an existing regular file that we own with a single
///   link, is written to a temporary file in the target's own directory and
///   renamed over it, keeping the old mode;
/// - an existing regular file must be writable, as for `>`
///   (`error.AccessDenied` otherwise). One owned by another user or with
///   other hard links is truncated and written in place instead, so its
///   owner, group and inode survive (a rename would also fail on another
///   user's file in a sticky directory such as /tmp); so is one whose
///   directory we cannot create a temporary file in;
/// - an existing fifo, character device or socket is opened and written
///   directly, with no rename;
/// - a directory is `error.IsDir`.
pub fn writeOutput(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) (WriteError || error{SymLinkLoop})!void {
    const final = try resolveOutputPath(allocator, path);
    defer allocator.free(final);
    const cwd = std.fs.cwd();
    const st = posix.fstatat(cwd.fd, final, 0) catch |err| switch (err) {
        error.FileNotFound => return writeReplacing(allocator, final, bytes, null),
        else => return err,
    };
    switch (kindFromMode(st.mode)) {
        .directory => return error.IsDir,
        .regular => {
            // Opening for writing checks permission exactly as `>` would.
            const existing = try cwd.openFile(final, .{ .mode = .write_only });
            defer existing.close();
            if (st.nlink > 1 or st.uid != posix.geteuid()) return writeInPlace(existing, bytes);
            return writeReplacing(allocator, final, bytes, .{ .mode = st.mode & 0o7777, .file = existing });
        },
        else => {
            const file = try cwd.openFile(final, .{ .mode = .write_only });
            defer file.close();
            try file.writeAll(bytes);
        },
    }
}

fn writeInPlace(file: std.fs.File, bytes: []const u8) WriteError!void {
    try file.setEndPos(0);
    try file.writeAll(bytes);
}

/// An existing regular file being replaced: its mode, and a write-only
/// handle to fall back on when the temporary file cannot be used.
const Existing = struct { mode: posix.mode_t, file: std.fs.File };

fn writeReplacing(allocator: std.mem.Allocator, final: []const u8, bytes: []const u8, existing: ?Existing) (WriteError || error{SymLinkLoop})!void {
    var suffix: [8]u8 = undefined;
    std.crypto.random.bytes(&suffix);
    const name = std.fmt.bytesToHex(suffix, .lower);
    const dir = std.fs.path.dirname(final);
    const temp_path = if (dir) |d|
        try std.fmt.allocPrint(allocator, "{s}/.mercat-tmp-{s}", .{ d, name })
    else
        try std.fmt.allocPrint(allocator, ".mercat-tmp-{s}", .{name});
    defer allocator.free(temp_path);

    const cwd = std.fs.cwd();
    {
        const file = cwd.createFile(temp_path, .{ .exclusive = true }) catch |err| switch (err) {
            // A writable file in a directory we cannot create in: write in place.
            error.AccessDenied, error.PermissionDenied => {
                const e = existing orelse return err;
                return writeInPlace(e.file, bytes);
            },
            else => return err,
        };
        errdefer cwd.deleteFile(temp_path) catch {};
        defer file.close();
        if (existing) |e| try file.chmod(e.mode);
        try file.writeAll(bytes);
    }
    cwd.rename(temp_path, final) catch |err| {
        cwd.deleteFile(temp_path) catch {};
        switch (err) {
            // Not allowed to replace the entry (a sticky directory, say), but
            // the file itself is writable: write in place.
            error.AccessDenied, error.PermissionDenied => {
                const e = existing orelse return err;
                return writeInPlace(e.file, bytes);
            },
            else => return err,
        }
    };
}

test {
    _ = @import("fs_test.zig");
}
