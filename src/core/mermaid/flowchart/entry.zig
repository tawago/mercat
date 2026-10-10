const std = @import("std");
const prim = @import("prim");
const select = @import("select.zig");
const raster = @import("raster.zig");
const sketch = @import("sketch.zig");
const paint = @import("paint.zig");

pub const parse = @import("parse.zig").parse;

pub const sem_graph = @import("sem_graph.zig");

pub const NodeId = sem_graph.NodeId;
pub const EdgeId = sem_graph.EdgeId;
pub const ClusterId = sem_graph.ClusterId;

pub const layoutFlowchart = @import("layout.zig").layout;
pub const validateSketch = @import("layout/validate.zig").validate;

pub const RenderResult = struct {
    output: []const u8,
    width: u32,
    height: u32,
    is_fallback: bool,
    fallback_reason: ?[]const u8 = null,
};

pub const RenderOptions = struct {
    max_width: u32 = 120,
    subgraph_edges: prim.SubgraphEdges = .bridge,
};

pub fn render(allocator: std.mem.Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    return renderFlowchart(allocator, source, options);
}

pub fn renderFlowchart(allocator: std.mem.Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const graph = parse(aa, source) catch |err| {
        std.log.warn("mermaid parse failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 pipeline error: parse");
    };
    if (graph.skipped_lines > 0) {
        std.log.warn("mermaid parse: skipped {d} unparseable non-edge line(s); rendering the rest", .{graph.skipped_lines});
    }

    const branch_result = select.resolvePermits(aa, graph) catch |err| {
        std.log.warn("mermaid branch plan failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 pipeline error: branch plan");
    };
    const bundle_permits = branch_result.plan;

    const chosen = select.choose(aa, graph, &bundle_permits, options.max_width, options.subgraph_edges) catch |err| {
        std.log.warn("mermaid/entry: ladder failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 ladder error");
    };
    const sketch_val = chosen.cand.sketch;
    const raster_report = chosen.report;

    var warnings: std.Io.Writer.Allocating = .init(aa);
    writeOmissions(&warnings.writer, graph, sketch_val, raster_report.label_plan) catch {};
    var lines = std.mem.tokenizeScalar(u8, warnings.written(), '\n');
    while (lines.next()) |line| std.log.warn("{s}", .{line});

    const budget = sketch_val.budget.max_width;
    const true_width = raster_report.lattice.width;
    const painted = paint.paint(allocator, raster_report.lattice, budget) catch |err| {
        std.log.warn("mermaid paint failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 paint error");
    };

    if (true_width > budget) {
        std.log.warn("mermaid: diagram clipped: true width {d} > budget {d}", .{ true_width, budget });
    }

    return .{
        .output = painted,
        .width = @min(true_width, budget),
        .height = raster_report.lattice.height,
        .is_fallback = false,
        .fallback_reason = null,
    };
}

pub fn writeOmissions(w: *std.Io.Writer, graph: sem_graph.SemGraph, s: sketch.Sketch, plan: raster.LabelPlan) std.Io.Writer.Error!void {
    for (s.edges) |e| if (!e.routed()) {
        const ends = declaredEnds(graph, e.origin);
        try w.print("mermaid: edge {d} ({s} -> {s}) could not be routed without illegal ink and is not drawn\n", .{ e.origin, ends[0], ends[1] });
    };
    for (plan.edges) |el| {
        const why = switch (el.omitted orelse continue) {
            .unrouted_host => continue,
            .no_room => "has no room",
        };
        const ends = declaredEnds(graph, el.origin);
        const text = if (graph.edgeById(el.origin)) |d| d.label orelse "" else "";
        try w.print("mermaid: label \"{s}\" on edge {d} ({s} -> {s}) {s} and is not drawn\n", .{ text, el.origin, ends[0], ends[1], why });
    }
}

fn declaredEnds(graph: sem_graph.SemGraph, origin: EdgeId) [2][]const u8 {
    const d = graph.edgeById(origin) orelse return .{ "?", "?" };
    return .{ nodeRawId(graph, d.from), nodeRawId(graph, d.to) };
}

fn nodeRawId(graph: sem_graph.SemGraph, id: sem_graph.NodeId) []const u8 {
    for (graph.nodes) |n| if (n.id == id) return n.raw_id;
    return "?";
}

fn fallback(source: []const u8, reason: []const u8) RenderResult {
    return .{
        .output = source,
        .width = 0,
        .height = 0,
        .is_fallback = true,
        .fallback_reason = reason,
    };
}

test {
    _ = @import("layout/sugiyama.zig");
    _ = @import("layout/crossing.zig");
    _ = @import("layout/validate.zig");
    _ = @import("layout/mirror.zig");
    _ = @import("layout.zig");
    _ = @import("raster.zig");
    _ = @import("paint.zig");
    _ = @import("budget.zig");
    _ = @import("score.zig");
    _ = @import("select.zig");
    _ = @import("motif.zig");
    _ = @import("recurse.zig");
    _ = @import("cluster/split.zig");
    _ = @import("cluster/split_test.zig");
    _ = @import("cluster/stitch_test.zig");
    _ = @import("cluster/bridges.zig");
    _ = @import("cluster/bridge_plan_test.zig");
    _ = @import("cluster/bridge_rails_test.zig");
    _ = @import("cluster/entry_inset_test.zig");
    _ = @import("cluster/bridge_bundle_sets.zig");
    _ = @import("base/ledger.zig");
    _ = @import("base/ledger_test.zig");
    _ = @import("base/bundle.zig");
    _ = @import("base/sharing_test.zig");
    _ = @import("base/rail_closure.zig");
    _ = @import("base/rail_closure_test.zig");
    _ = @import("layout/fan_rail_licence.zig");
    _ = @import("ledger/permits.zig");
    _ = @import("ledger/permits_test.zig");
    _ = @import("realized_production_test.zig");
    _ = @import("render_evidence_test.zig");
    _ = @import("layout/ports.zig");
    _ = @import("layout/ports_test.zig");
    _ = @import("layout/port_plan_test.zig");
    _ = @import("layout/bundle_commit_test.zig");
    _ = @import("layout/route_clearance_test.zig");
    _ = @import("select_test.zig");
    _ = @import("sketch_ports_test.zig");
    _ = @import("sketch_clearance_test.zig");
    _ = @import("junction_licence_test.zig");
    _ = @import("grapheme_width_test.zig");
    _ = @import("candidates.zig");
    _ = @import("candidates_test.zig");
    _ = @import("entry_test.zig");
    _ = @import("layout/sketch_props_test.zig");
}
