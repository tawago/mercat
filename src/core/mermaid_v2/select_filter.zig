//! select_filter.zig — the pre-raster CI safety filter, split out of
//! select.zig for the 500-line cap. A candidate that laid no ink for a
//! visible edge could win the fit tier by dropping a relation, so it is not
//! a candidate: the filter runs BEFORE scoring and is score-blind (it reads
//! the candidate's own polylines, never a score, a magnitude or a rung).
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, base/*, sketch,
//! budget.

const std = @import("std");
const sketch_mod = @import("sketch.zig");
const ladder = @import("budget.zig");

/// Visible edges of `s` with no polyline at all: declared relations the
/// router laid no ink for (routing.zig `unrouted`).
pub fn unroutedEdges(s: sketch_mod.Sketch) u32 {
    var n: u32 = 0;
    for (s.edges) |e| if (e.polyline.len < 2 and e.kind != .invisible) {
        n += 1;
    };
    return n;
}

/// The candidates that drew every visible edge, in their original order.
/// No rung carve-out: the truncate rung is excluded like any other. The
/// identity when nothing is excluded; an allocation failure degrades to the
/// identity too. A filter that empties the set leaves the caller its ladder
/// incumbent.
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
