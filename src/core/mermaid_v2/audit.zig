//! audit.zig — per-candidate raster audit. Rasterizes a candidate Sketch
//! via raster.zig and returns shipped-defect counts for score.eval:
//! `labels_dropped`, `edge_cells_lost` (`phantom_arms_cleared` excluded —
//! repairs, not defects). score.zig's integrity term only reads
//! Sketch-level validate counts, so raster-introduced defects must be
//! measured here; `raster.rasterize` reads the Sketch as const, so
//! auditing cannot perturb the render, and any raster failure degrades
//! to zero counts so auditing never fails a render.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, sketch, raster,
//! score (for the RasterCounts type consumed by score.eval).

const std = @import("std");
const sketch = @import("sketch.zig");
const raster = @import("raster.zig");
const score = @import("score.zig");

/// Rasterize `s` and collect the shipped-defect counts for score.eval.
/// Failure (OOM included) degrades to zero counts: a candidate that
/// cannot even rasterize will fail identically at entry level if chosen,
/// and the audit must not turn a scoring pass into a render error.
pub fn collect(allocator: std.mem.Allocator, s: sketch.Sketch) score.RasterCounts {
    // The subgraph-border notation is a display preference, not a quality
    // signal: bridge vs cross changes only border-cell painting (report-only
    // counters + glyph), never labels_dropped/labels_displaced/edge_cells_lost.
    // Audit therefore always uses the default `.bridge`, keeping the score
    // raster-blind to the user's notation choice.
    const report = raster.rasterize(allocator, s, .bridge) catch return .{};
    return .{
        .labels_dropped = report.labels_dropped,
        .labels_displaced = report.labels_displaced,
        .edge_cells_lost = report.edge_cells_lost,
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

    const counts = collect(a, s);
    try std.testing.expectEqual(@as(u32, 0), counts.labels_dropped);
    try std.testing.expectEqual(@as(u32, 0), counts.edge_cells_lost);
}
