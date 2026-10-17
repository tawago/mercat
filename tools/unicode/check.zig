const std = @import("std");
const generator = @import("generate.zig");
const comparer = @import("compare.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;

    try generator.generate(init.io, init.gpa, args[1]);
    try comparer.compare(init.io, init.gpa, "src/lib/unicode/generated", args[1]);
}
