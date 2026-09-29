const std = @import("std");
const sketch_mod = @import("sketch.zig");
const ladder = @import("budget.zig");

pub fn unroutedEdges(s: sketch_mod.Sketch) u32 {
    var n: u32 = 0;
    for (s.edges) |e| if (e.polyline.len < 2 and e.kind != .invisible) {
        n += 1;
    };
    return n;
}

/// The candidates that route every visible edge.
pub fn ciFilter(aa: std.mem.Allocator, candidates: []const ladder.Candidate) ![]const ladder.Candidate {
    var survivors: std.ArrayListUnmanaged(ladder.Candidate) = .empty;
    for (candidates) |cand| {
        if (unroutedEdges(cand.sketch) == 0) try survivors.append(aa, cand);
    }
    return survivors.toOwnedSlice(aa);
}
