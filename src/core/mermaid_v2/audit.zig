//! audit.zig — per-candidate raster audit. Rasterizes a candidate Sketch
//! via raster.zig and returns shipped-defect counts for score.eval:
//! `labels_dropped`, `edge_cells_lost` (`phantom_arms_cleared` excluded —
//! repairs, not defects). score.zig's integrity term only reads
//! Sketch-level validate counts, so raster-introduced defects must be
//! measured here; `raster.rasterize` reads the Sketch as const, so
//! auditing cannot perturb the render, and any raster failure poisons the
//! candidate's violation tier instead of failing the render.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, sketch, raster,
//! score (for the RasterCounts type consumed by score.eval).

const std = @import("std");
const prim = @import("prim");
const sketch = @import("sketch.zig");
const raster = @import("raster.zig");
const score = @import("score.zig");

/// Rasterize `s` and collect the shipped-defect counts for score.eval.
/// Failure (OOM included) sets `raster_failed`, which dominates the
/// violation tier: a candidate that cannot even rasterize must not win
/// with tv=0 and then fail entry.zig's final re-raster.
pub fn collect(allocator: std.mem.Allocator, s: sketch.Sketch, subgraph_edges: prim.SubgraphEdges) score.RasterCounts {
    const report = raster.rasterize(allocator, s, subgraph_edges) catch return .{ .raster_failed = 1 };
    return .{
        .labels_dropped = report.labels_dropped,
        .labels_displaced = report.labels_displaced,
        .edge_cells_lost = report.edge_cells_lost,
        .heads_lost = report.edge_heads_lost,
        .foreign_junction = report.crossings.foreign_junction_violation,
        .arrowhead_transit = report.crossings.arrowhead_transit_violation,
        .arrow_base = report.arrow_base.violations,
        .tip_not_port = report.arrow_base.tip_not_port,
        .arm_into_head = report.arrow_base.lateral_arms,
    };
}

test "collect returns zero counts for a clean two-node sketch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf = [_]sketch.NodePlacement{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 8, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    var poly = [_]sketch.Point{ .{ .x = 4, .y = 1 }, .{ .x = 8, .y = 1 } };
    var edges_buf = [_]sketch.EdgePath{.{
        .id = 0,
        .from = 1,
        .to = 2,
        .polyline = poly[0..],
        .port_from = .{ .node = 1, .side = .east, .offset = 1 },
        .port_to = .{ .node = 2, .side = .west, .offset = 1 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
    }};
    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 13, .h = 3 },
        .direction = .LR,
        .nodes = nodes_buf[0..],
        .clusters = &.{},
        .edges = edges_buf[0..],
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const counts = collect(a, s, .bridge);
    try std.testing.expectEqual(@as(u32, 0), counts.labels_dropped);
    try std.testing.expectEqual(@as(u32, 0), counts.edge_cells_lost);
}
