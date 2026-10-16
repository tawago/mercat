//! File system helpers for the paths mercat reads and writes.
//!
//! Everything here reports errors instead of trapping, so an over-long path
//! component is `error.NameTooLong`, not a crash.
const std = @import("std");
const builtin = @import("builtin");
const host = @import("host.zig");
const File = std.Io.File;
const Dir = std.Io.Dir;

pub const Kind = enum { missing, directory, regular, symlink, other };

pub const StatError = Dir.StatFileError;

/// What `path` names. A missing path (or one under a non-directory) is
/// `.missing`, not an error. With `follow`, symlinks are resolved first, so
/// a dangling symlink is `.missing`.
pub fn kindOf(path: []const u8, follow: bool) StatError!Kind {
    const st = statPath(path, follow) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .missing,
        else => return err,
    };
    return kindFromStat(st.kind);
}

fn statPath(path: []const u8, follow: bool) StatError!File.Stat {
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len > Dir.max_name_bytes) return error.NameTooLong;
    return Dir.cwd().statFile(host.io(), path, .{ .follow_symlinks = follow });
}

fn kindFromStat(kind: File.Kind) Kind {
    return switch (kind) {
        .directory => .directory,
        .file => .regular,
        .sym_link => .symlink,
        else => .other,
    };
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

pub const WriteError = File.OpenError || File.Writer.Error || File.SetPermissionsError ||
    File.SetLengthError || Dir.RenameError || Dir.ReadLinkError || StatError || std.mem.Allocator.Error;

const max_symlink_hops = 40;

/// The path that writing to `path` really changes: symlinks are followed
/// (relative targets resolve against the link's directory) until a path that
/// is not a symlink, which may not exist yet. Caller frees the result.
pub fn resolveOutputPath(allocator: std.mem.Allocator, path: []const u8) (WriteError || error{SymLinkLoop})![]u8 {
    var current = try allocator.dupe(u8, path);
    errdefer allocator.free(current);
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    var hops: usize = 0;
    while (try kindOf(current, false) == .symlink) : (hops += 1) {
        if (hops == max_symlink_hops) return error.SymLinkLoop;
        const target = link_buf[0..try Dir.cwd().readLink(host.io(), current, &link_buf)];
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
    const st = statPath(final, true) catch |err| switch (err) {
        error.FileNotFound => return writeReplacing(allocator, final, bytes, null),
        else => return err,
    };
    switch (kindFromStat(st.kind)) {
        .directory => return error.IsDir,
        .regular => {
            // Opening for writing checks permission exactly as `>` would.
            const existing = try host.openFile(final, .{ .mode = .write_only });
            defer existing.close(host.io());
            if (st.nlink > 1 or !ownedByUs(existing)) return writeInPlace(existing, bytes);
            return writeReplacing(allocator, final, bytes, .{ .mode = st.permissions.toMode() & 0o7777, .file = existing });
        },
        else => {
            const file = try host.openFile(final, .{ .mode = .write_only });
            defer file.close(host.io());
            try host.writeAll(file, bytes);
        },
    }
}

/// Whether the effective user owns `file`. File.Stat carries no owner.
fn ownedByUs(file: File) bool {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var stx: linux.Statx = undefined;
            const rc = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{ .UID = true }, &stx);
            return linux.errno(rc) == .SUCCESS and stx.uid == linux.geteuid();
        },
        else => {
            var st: std.c.Stat = undefined;
            return std.c.fstat(file.handle, &st) == 0 and st.uid == std.c.geteuid();
        },
    }
}

fn writeInPlace(file: File, bytes: []const u8) WriteError!void {
    try file.setLength(host.io(), 0);
    try host.writeAll(file, bytes);
}

/// An existing regular file being replaced: its mode, and a write-only
/// handle to fall back on when the temporary file cannot be used.
const Existing = struct { mode: std.posix.mode_t, file: File };

fn writeReplacing(allocator: std.mem.Allocator, final: []const u8, bytes: []const u8, existing: ?Existing) (WriteError || error{SymLinkLoop})!void {
    var suffix: [8]u8 = undefined;
    host.io().random(&suffix);
    const name = std.fmt.bytesToHex(suffix, .lower);
    const dir = std.fs.path.dirname(final);
    const temp_path = if (dir) |d|
        try std.fmt.allocPrint(allocator, "{s}/.mercat-tmp-{s}", .{ d, name })
    else
        try std.fmt.allocPrint(allocator, ".mercat-tmp-{s}", .{name});
    defer allocator.free(temp_path);

    const io = host.io();
    const cwd = Dir.cwd();
    {
        const file = cwd.createFile(io, temp_path, .{ .exclusive = true }) catch |err| switch (err) {
            // A writable file in a directory we cannot create in: write in place.
            error.AccessDenied, error.PermissionDenied => {
                const e = existing orelse return err;
                return writeInPlace(e.file, bytes);
            },
            else => return err,
        };
        errdefer cwd.deleteFile(io, temp_path) catch {};
        defer file.close(io);
        if (existing) |e| try file.setPermissions(io, @enumFromInt(e.mode));
        try host.writeAll(file, bytes);
    }
    Dir.rename(cwd, temp_path, cwd, final, io) catch |err| {
        cwd.deleteFile(io, temp_path) catch {};
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
