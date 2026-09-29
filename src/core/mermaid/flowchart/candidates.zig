//! The layout candidates of one flowchart, in selection order, each one drawable and scorable
//! alone. It calls the selection stages as they are and holds no state of its own.

const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");
const permits = @import("ledger/permits.zig");
const sem_graph = @import("sem_graph.zig");
const ladder = @import("budget.zig");
const select = @import("select.zig");
const select_filter = @import("select_filter.zig");
const audit = @import("audit.zig");
const score = @import("score.zig");
const raster = @import("raster.zig");
const paint = @import("paint.zig");

pub const Candidate = ladder.Candidate;

/// What the audit counts and the score says about one candidate.
pub const Evaluation = struct {
    counts: score.RasterCounts,
    score: score.Score,
};

/// One candidate rasterized and painted.
pub const Drawn = struct {
    text: []const u8,
    true_width: u32,
    height: u32,
    budget_width: u32,
};

/// Every layout the selection weighs for this graph and width, in the order it weighs them.
pub fn list(aa: std.mem.Allocator, graph: sem_graph.SemGraph, max_width: u32) ![]const Candidate {
    const built = try permits.build(aa, graph, .joined);
    if (!built.report.bundle_permits_skipped_clustered) {
        const validation = try permits.validate(aa, graph, built.plan);
        if (!validation.valid()) return error.InvalidBundlePermits;
    }
    const plan = try aa.create(ledger.BundlePermits);
    plan.* = built.plan;
    return select.enumerateAll(aa, graph, plan, max_width);
}

/// Whether every visible edge of the candidate is routed; only such candidates are scored.
pub fn routes(c: Candidate) bool {
    return select_filter.unroutedEdges(c.sketch) == 0;
}

/// The index the selection picks: the lowest-scored routed candidate, or the first raw
/// rung that fits when none routes.
pub fn choose(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    candidates: []const Candidate,
    subgraph_edges: prim.SubgraphEdges,
) !usize {
    const routed = try select_filter.ciFilter(aa, candidates);
    const kept = try aa.alloc(usize, routed.len);
    var n: usize = 0;
    for (candidates, 0..) |c, i| if (routes(c)) {
        kept[n] = i;
        n += 1;
    };
    std.debug.assert(n == routed.len);
    if (routed.len == 0) {
        const fit = ladder.firstFit(candidates);
        for (candidates, 0..) |c, i| if (c.rung == fit.rung and c.transform == fit.transform) return i;
        unreachable;
    }
    return kept[try select.argmin(aa, routed, graph.direction, subgraph_edges)];
}

/// The audit counts and the score of `candidates[index]`; its tie-break index is its place in the full list.
pub fn evaluate(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    candidates: []const Candidate,
    index: usize,
    subgraph_edges: prim.SubgraphEdges,
) !Evaluation {
    const sketch = candidates[index].sketch;
    const counts = try audit.collect(aa, sketch, subgraph_edges);
    return .{
        .counts = counts,
        .score = try score.eval(aa, sketch, graph.direction, @intCast(index), counts),
    };
}

/// The candidate rasterized and painted as the render does it.
pub fn draw(aa: std.mem.Allocator, c: Candidate, subgraph_edges: prim.SubgraphEdges) !Drawn {
    const report = try raster.rasterize(aa, c.sketch, subgraph_edges);
    const budget_width = c.sketch.budget.max_width;
    return .{
        .text = try paint.paint(aa, report.lattice, budget_width),
        .true_width = report.lattice.width,
        .height = report.lattice.height,
        .budget_width = budget_width,
    };
}
