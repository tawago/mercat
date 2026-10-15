//! The process's I/O implementation and environment, set once by main.
//! Tests read the ones std.testing provides.
const std = @import("std");
const builtin = @import("builtin");

var main_io: ?std.Io = null;
var main_environ: ?std.process.Environ = null;
var main_environ_map: ?*std.process.Environ.Map = null;
var test_environ_map: ?std.process.Environ.Map = null;

pub fn init(process_io: std.Io, process_environ: std.process.Environ, environ_map: *std.process.Environ.Map) void {
    main_io = process_io;
    main_environ = process_environ;
    main_environ_map = environ_map;
}

pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    return main_io.?;
}

pub fn environ() std.process.Environ {
    if (builtin.is_test) return std.testing.environ;
    return main_environ.?;
}

pub fn environMap() *std.process.Environ.Map {
    if (builtin.is_test) {
        if (test_environ_map == null) test_environ_map = std.testing.environ.createMap(std.heap.page_allocator) catch @panic("OOM");
        return &test_environ_map.?;
    }
    return main_environ_map.?;
}

/// Wall-clock milliseconds since the epoch.
pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(io(), .real).toMilliseconds();
}

/// The value of an environment variable, or null when unset.
pub fn getenv(key: []const u8) ?[:0]const u8 {
    return environ().getPosix(key);
}

/// Reads `file` to its end; more than `max_bytes` is error.StreamTooLong.
/// A failed read reports the underlying error, not error.ReadFailed.
pub fn readToEnd(file: std.Io.File, gpa: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io(), &buf);
    return reader.interface.allocRemaining(gpa, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };
}

pub fn openFile(path: []const u8, flags: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
    return std.Io.Dir.cwd().openFile(io(), path, flags);
}

/// Writes all of `bytes` to `file`, reporting the underlying error
/// (error.BrokenPipe, …) rather than error.WriteFailed.
pub fn writeAll(file: std.Io.File, bytes: []const u8) std.Io.File.Writer.Error!void {
    var writer = file.writerStreaming(io(), &.{});
    writer.interface.writeAll(bytes) catch return writer.err.?;
}
