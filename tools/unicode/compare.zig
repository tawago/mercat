const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) return error.Usage;

    try compare(allocator, args[1], args[2]);
}

pub fn compare(allocator: std.mem.Allocator, expected_path: []const u8, actual_path: []const u8) !void {
    var expected_dir = try std.fs.cwd().openDir(expected_path, .{ .iterate = true });
    defer expected_dir.close();
    var actual_dir = try std.fs.cwd().openDir(actual_path, .{ .iterate = true });
    defer actual_dir.close();

    try compareOneWay(allocator, expected_dir, actual_dir, expected_path, actual_path);
    try compareOneWay(allocator, actual_dir, expected_dir, actual_path, expected_path);
}

fn compareOneWay(
    allocator: std.mem.Allocator,
    from: std.fs.Dir,
    to: std.fs.Dir,
    from_name: []const u8,
    to_name: []const u8,
) !void {
    var iterator = from.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        const a = try from.readFileAlloc(allocator, entry.name, 16 * 1024 * 1024);
        defer allocator.free(a);
        const b = to.readFileAlloc(allocator, entry.name, 16 * 1024 * 1024) catch |err| {
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
