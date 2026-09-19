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

/// @guarded-by: select_test.zig "a candidate with an unrouted visible edge is filtered out before scoring"
pub fn ciFilter(aa: std.mem.Allocator, candidates: []const ladder.Candidate) []const ladder.Candidate {
    var any = false;
    for (candidates) |cand| if (unroutedEdges(cand.sketch) != 0) {
        any = true;
        break;
    };
    if (!any) return candidates;

    var survivors: std.ArrayListUnmanaged(ladder.Candidate) = .empty;
    for (candidates) |cand| {
        if (unroutedEdges(cand.sketch) != 0) continue;
        survivors.append(aa, cand) catch return candidates;
    }
    return survivors.toOwnedSlice(aa) catch candidates;
}
