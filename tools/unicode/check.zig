const std = @import("std");
const generator = @import("generate.zig");
const comparer = @import("compare.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.Usage;

    try generator.generate(allocator, args[1]);
    try comparer.compare(allocator, "src/lib/unicode/generated", args[1]);
}
