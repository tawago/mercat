const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;

    try compare(init.io, init.gpa, args[1], args[2]);
}

pub fn compare(io: std.Io, allocator: std.mem.Allocator, expected_path: []const u8, actual_path: []const u8) !void {
    var expected_dir = try std.Io.Dir.cwd().openDir(io, expected_path, .{ .iterate = true });
    defer expected_dir.close(io);
    var actual_dir = try std.Io.Dir.cwd().openDir(io, actual_path, .{ .iterate = true });
    defer actual_dir.close(io);

    try compareOneWay(io, allocator, expected_dir, actual_dir, expected_path, actual_path);
    try compareOneWay(io, allocator, actual_dir, expected_dir, actual_path, expected_path);
}

fn compareOneWay(
    io: std.Io,
    allocator: std.mem.Allocator,
    from: std.Io.Dir,
    to: std.Io.Dir,
    from_name: []const u8,
    to_name: []const u8,
) !void {
    var iterator = from.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const a = try from.readFileAlloc(io, entry.name, allocator, .limited(16 * 1024 * 1024 + 1));
        defer allocator.free(a);
        const b = to.readFileAlloc(io, entry.name, allocator, .limited(16 * 1024 * 1024 + 1)) catch |err| {
            std.debug.print("unicode-check: {s}/{s} has no peer in {s}: {s}\n", .{ from_name, entry.name, to_name, @errorName(err) });
            return error.GeneratedDataMismatch;
        };
        defer allocator.free(b);
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("unicode-check: {s}/{s} differs from {s}/{s}\n", .{ from_name, entry.name, to_name, entry.name });
            return error.GeneratedDataMismatch;
        }
    }
}
