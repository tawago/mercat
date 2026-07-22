//! Raster pipeline orchestrator.
//!
//! Allocates a `Lattice` sized to `Sketch.bbox` and runs clusters →
//! nodes → bus-bars → edges → reconcile → labels in order, returning a
//! `RasterReport` with per-stage counts. Order matters: each stage
//! skips cells already claimed by an earlier one, except labels, which
//! intentionally overwrite node interiors last.
//!
//! Allowed imports: `std`, sibling `raster/*` files, `sketch.zig`,
//! `lattice.zig`. No `paint/` or `parse/` (enforced by `tools/lint_imports.zig`).

const std = @import("std");
const prim = @import("prim");
const sketch = @import("sketch.zig");
const lattice = @import("lattice.zig");
const nodes_r = @import("raster/nodes.zig");
const edges_r = @import("raster/edges.zig");
const busbars_r = @import("raster/busbars.zig");
const clusters_r = @import("raster/clusters.zig");
const labels_r = @import("raster/labels.zig");
const reconcile = @import("raster/reconcile.zig");
const crossings_r = @import("raster/crossings.zig");
const arrow_base_r = @import("raster/arrow_base.zig");

pub const RasterizeError = error{
    OutOfMemory,
    OutOfBounds,
    MalformedPolyline,
    LatticeAllocFailed,
};

pub const RasterReport = struct {
    /// Allocated within the caller-provided allocator. Lifetime is tied
    /// to that allocator (typically an arena owning Sketch + diagnostics).
    lattice: lattice.Lattice,
    nodes_written: u32,
    clusters_written: u32,
    edges_written: u32,
    labels_placed: u32,
    label_diagnostics: []const labels_r.LabelDiagnostic,
    // -- Phase 1 integrity counts (report-only; flow raster → entry →
    //    diagnostics, never back into layout/budget) ------------------------
    /// Edge polyline/arrowhead cells skipped because they collided with
    /// node-owned or label cells (see `raster/edges.zig`).
    edge_cells_lost: u32,
    /// Labels present in the Sketch that could not be placed at all
    /// (see `raster/labels.zig`).
    labels_dropped: u32,
    /// Edge/tap labels the fallback ladder placed away from their primary
    /// anchor (see `raster/labels_edge.zig`) — cheaper than a drop, still
    /// a shipped legibility defect the score prices.
    labels_displaced: u32,
    /// Phantom neighbour-mask arms cleared by the reconcile post-pass
    /// (informational — these are repairs, not shipped defects).
    phantom_arms_cleared: u32,
    /// Half-open split-junction arms re-added by the reciprocity-repair
    /// post-pass (informational — repairs, not shipped defects; EXCLUDED
    /// from audit's RasterCounts, exactly like `phantom_arms_cleared`).
    arms_repaired: u32 = 0,
    /// Crossing/transversal tallies (Amendment C, C1/C2; report-only). Never
    /// consumed by score/audit/selection — see `raster/crossings.zig`.
    crossings: crossings_r.CrossingCounts = .{},
    /// Arrowhead-base painted tally (owner ruling 2026-07-18; report-only).
    /// Counts arrowheads whose base cell does not feed the triangle. Never
    /// consumed by score/audit/selection — see `raster/arrow_base.zig`.
    arrow_base: arrow_base_r.ArrowBaseCounts = .{},
};

/// Allocate a Lattice sized to `s.bbox` and rasterize all four layers.
/// On a zero-sized bbox returns an empty report with a zero-cell
/// lattice and no diagnostics.
pub fn rasterize(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    subgraph_edges: prim.SubgraphEdges,
) RasterizeError!RasterReport {
    const w = s.bbox.w;
    const h = s.bbox.h;

    if (w == 0 or h == 0) {
        return .{
            .lattice = .{ .width = 0, .height = 0, .cells = &[_]lattice.Cell{} },
            .nodes_written = 0,
            .clusters_written = 0,
            .edges_written = 0,
            .labels_placed = 0,
            .label_diagnostics = &.{},
            .edge_cells_lost = 0,
            .labels_dropped = 0,
            .labels_displaced = 0,
            .phantom_arms_cleared = 0,
            .crossings = .{},
        };
    }

    const cells = allocator.alloc(lattice.Cell, @as(usize, w) * @as(usize, h)) catch {
        return error.LatticeAllocFailed;
    };
    for (cells) |*c| c.* = lattice.Cell.empty;

    var lat: lattice.Lattice = .{ .width = w, .height = h, .cells = cells };

    const clusters_n = clusters_r.rasterizeClusters(allocator, &lat, s) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OutOfBounds => return error.OutOfBounds,
    };

    const nodes_n = nodes_r.rasterizeNodes(allocator, &lat, s) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OutOfBounds => return error.OutOfBounds,
        error.OccupiedCell => return error.OutOfBounds,
    };

    // Bus-bars before ordinary edges (Phase 4b slice iv): the fan trunk claims its cells first, so edges OR their bits in afterwards without overwriting trunk kind/role. // guarded-by: raster.zig "bus-bar rasterizes before edges: junction cell keeps trunk kind/role, edge bits fold in"
    const busbar_report = busbars_r.rasterizeBusBars(&lat, s);

    const edge_report = edges_r.rasterizeEdges(allocator, &lat, s, subgraph_edges) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OutOfBounds => return error.OutOfBounds,
        error.MalformedPolyline => return error.MalformedPolyline,
    };

    // Reconcile junction masks (phantom-arm cleanup) after edges, before labels — order is required, not incidental. // guarded-by: raster/reconcile.zig "reconcile is NOT order-independent w.r.t. labels: swapping the pipeline position changes the result"
    const phantom_arms = reconcile.reconcileNeighbours(&lat);

    // Repair half-open split-junctions (clear-then-repair order): clear only
    // removes into-empty arms, repair only adds toward a reciprocating
    // edge_segment, so the two passes never conflict. // guarded-by: raster/reconcile_test.zig "repairReciprocalArms: half-open split-junction corner regains its arm (┘→┤)"
    const arms_repaired = reconcile.repairReciprocalArms(&lat);

    const label_report = labels_r.rasterizeLabels(allocator, &lat, s) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Arrowhead-base weld (owner ruling 2026-07-18): after reconcile and
    // labels, weld the connecting stroke onto arrowhead base cells so each tip
    // is received on its base side. Truthful welds only (own ink / genuine
    // resume gaps); foreign crossings and side-fed corners are left for the
    // validator to report. Then scan the FINAL lattice for any residual.
    _ = arrow_base_r.weld(&lat);
    const arrow_base = arrow_base_r.validate(&lat);

    return .{
        .lattice = lat,
        .nodes_written = nodes_n,
        .clusters_written = clusters_n,
        .edges_written = edge_report.edges_written + busbar_report.taps_written,
        .labels_placed = label_report.placed,
        .label_diagnostics = label_report.diagnostics,
        .edge_cells_lost = edge_report.cells_lost + busbar_report.cells_lost,
        .labels_dropped = label_report.dropped,
        .labels_displaced = label_report.displaced,
        .phantom_arms_cleared = phantom_arms,
        .arms_repaired = arms_repaired,
        .crossings = edge_report.crossings,
        .arrow_base = arrow_base,
    };
}

const testing = std.testing;

test "zero-sized bbox returns empty report" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const r = try rasterize(a, s, .bridge);
    try testing.expectEqual(@as(u32, 0), r.lattice.width);
    try testing.expectEqual(@as(u32, 0), r.lattice.height);
    try testing.expectEqual(@as(u32, 0), r.nodes_written);
    try testing.expectEqual(@as(u32, 0), r.clusters_written);
    try testing.expectEqual(@as(u32, 0), r.edges_written);
    try testing.expectEqual(@as(u32, 0), r.labels_placed);
    try testing.expectEqual(@as(usize, 0), r.label_diagnostics.len);
}

test "two nodes + one edge: borders, interiors, and an edge cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [2]sketch.NodePlacement = undefined;
    nodes_buf[0] = .{
        .id = 1,
        .rect = .{ .x = 0, .y = 0, .w = 3, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
    nodes_buf[1] = .{
        .id = 2,
        .rect = .{ .x = 7, .y = 0, .w = 3, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };

    // Edge from east-mid of node 1 (2,1) to west-mid of node 2 (7,1).
    var poly = [_]sketch.Point{
        .{ .x = 2, .y = 1 },
        .{ .x = 7, .y = 1 },
    };
    var edges_buf: [1]sketch.EdgePath = undefined;
    edges_buf[0] = .{
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
    };

    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 10, .h = 3 },
        .direction = .LR,
        .nodes = nodes_buf[0..],
        .clusters = &.{},
        .edges = edges_buf[0..],
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const r = try rasterize(a, s, .bridge);
    try testing.expectEqual(@as(u32, 2), r.nodes_written);
    try testing.expectEqual(@as(u32, 0), r.clusters_written);
    try testing.expect(r.edges_written >= 1);

    switch (r.lattice.atConst(0, 0).occupant) {
        .node_border => |b| try testing.expectEqual(@as(u32, 1), b.node),
        else => return error.MissingNode1NW,
    }
    switch (r.lattice.atConst(7, 0).occupant) {
        .node_border => |b| try testing.expectEqual(@as(u32, 2), b.node),
        else => return error.MissingNode2NW,
    }
    switch (r.lattice.atConst(1, 1).occupant) {
        .node_interior => |n| try testing.expectEqual(@as(u32, 1), n),
        else => return error.MissingNode1Interior,
    }
    switch (r.lattice.atConst(8, 1).occupant) {
        .node_interior => |n| try testing.expectEqual(@as(u32, 2), n),
        else => return error.MissingNode2Interior,
    }
    // At least one cell strictly between the nodes (column 3..6 row 1)
    // should be an edge_segment.
    var found_edge = false;
    var x: u32 = 3;
    while (x <= 6) : (x += 1) {
        switch (r.lattice.atConst(x, 1).occupant) {
            .edge_segment, .arrowhead => found_edge = true,
            else => {},
        }
    }
    try testing.expect(found_edge);
}

test "single cluster around one node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var clusters_buf: [1]sketch.ClusterFrame = undefined;
    clusters_buf[0] = .{
        .id = 0,
        .rect = .{ .x = 0, .y = 0, .w = 7, .h = 5 },
        .parent_id = null,
        .label = "",
        .depth = 0,
    };

    var nodes_buf: [1]sketch.NodePlacement = undefined;
    nodes_buf[0] = .{
        .id = 5,
        .rect = .{ .x = 2, .y = 1, .w = 3, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = 0,
    };

    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 7, .h = 5 },
        .direction = .TD,
        .nodes = nodes_buf[0..],
        .clusters = clusters_buf[0..],
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const r = try rasterize(a, s, .bridge);
    try testing.expectEqual(@as(u32, 1), r.clusters_written);
    try testing.expectEqual(@as(u32, 1), r.nodes_written);

    switch (r.lattice.atConst(0, 0).occupant) {
        .cluster_border => |c| try testing.expectEqual(@as(u32, 0), c.cluster),
        else => return error.MissingClusterNW,
    }
    switch (r.lattice.atConst(3, 2).occupant) {
        .node_interior => |n| try testing.expectEqual(@as(u32, 5), n),
        else => return error.MissingNodeInterior,
    }
}

test "edge crossing produces a full junction cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two crossing edges meeting at (5,5). No nodes — just verify the
    // edge rasterizer OR-merges neighbour bits at the crossing.
    var poly_h = [_]sketch.Point{
        .{ .x = 0, .y = 5 },
        .{ .x = 10, .y = 5 },
    };
    var poly_v = [_]sketch.Point{
        .{ .x = 5, .y = 0 },
        .{ .x = 5, .y = 10 },
    };
    var edges_buf: [2]sketch.EdgePath = undefined;
    edges_buf[0] = .{
        .id = 0,
        .from = 0,
        .to = 1,
        .polyline = poly_h[0..],
        .port_from = .{ .node = 0, .side = .east, .offset = 0 },
        .port_to = .{ .node = 1, .side = .west, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
        .kind = .solid,
    };
    edges_buf[1] = .{
        .id = 1,
        .from = 2,
        .to = 3,
        .polyline = poly_v[0..],
        .port_from = .{ .node = 2, .side = .south, .offset = 0 },
        .port_to = .{ .node = 3, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
        .kind = .solid,
    };

    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 11, .h = 11 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = edges_buf[0..],
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const r = try rasterize(a, s, .bridge);
    const c = r.lattice.atConst(5, 5).*;
    try testing.expectEqual(@as(u4, 0b1111), c.neighbours.toMask());
}

test "bus-bar rasterizes before edges: junction cell keeps trunk kind/role, edge bits fold in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [4]sketch.NodePlacement = undefined;
    nodes_buf[0] = .{ .id = 0, .rect = .{ .x = 10, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    nodes_buf[1] = .{ .id = 1, .rect = .{ .x = 0, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    nodes_buf[2] = .{ .id = 2, .rect = .{ .x = 10, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    nodes_buf[3] = .{ .id = 3, .rect = .{ .x = 20, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };

    var stem = [_]sketch.Point{ .{ .x = 12, .y = 2 }, .{ .x = 12, .y = 5 } };
    var taps = [_]sketch.Tap{
        .{ .edge = 10, .node = 1, .at = .{ .x = 2, .y = 5 }, .landing = .{ .x = 2, .y = 7 } },
        .{ .edge = 11, .node = 2, .at = .{ .x = 12, .y = 5 }, .landing = .{ .x = 12, .y = 7 } },
        .{ .edge = 12, .node = 3, .at = .{ .x = 22, .y = 5 }, .landing = .{ .x = 22, .y = 7 } },
    };
    var busbars_buf = [_]sketch.BusBar{.{
        .pivot = 0,
        .stem = &stem,
        .rail = .{ .{ .x = 2, .y = 5 }, .{ .x = 22, .y = 5 } },
        .taps = &taps,
        .kind = .solid,
    }};

    // An unrelated `.dotted` edge whose polyline runs straight through a
    // plain rail cell (7,5) that the bus-bar already claims. If edges
    // rasterized before bus-bars, this cell's first-writer-wins `kind`
    // would come out `.dotted` (the crossing edge's), not `.solid` (the
    // trunk's) — see `writeEdgeCell`'s `.edge_segment` branch, which
    // never updates `kind` on a second write.
    var poly = [_]sketch.Point{ .{ .x = 7, .y = 1 }, .{ .x = 7, .y = 9 } };
    var edges_buf = [_]sketch.EdgePath{.{
        .id = 99,
        .from = 90,
        .to = 91,
        .polyline = poly[0..],
        .port_from = .{ .node = 90, .side = .south, .offset = 0 },
        .port_to = .{ .node = 91, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
        .kind = .dotted,
    }};

    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 25, .h = 10 },
        .direction = .TD,
        .nodes = nodes_buf[0..],
        .clusters = &.{},
        .edges = edges_buf[0..],
        .busbars = busbars_buf[0..],
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const r = try rasterize(a, s, .bridge);

    const cell = r.lattice.atConst(7, 5).*;
    switch (cell.occupant) {
        .edge_segment => |seg| {
            // Trunk-owned kind survives the later crossing edge write.
            try testing.expectEqual(lattice.EdgeKind.solid, seg.kind);
            try testing.expectEqual(lattice.EdgeRole.fan_out_trunk, seg.role);
        },
        else => return error.MissingJunctionCell,
    }
    // The crossing edge's vertical bits fold into the rail's existing
    // horizontal bits (OR-merge) rather than replacing them: full 4-way.
    try testing.expectEqual(@as(u4, 0b1111), cell.neighbours.toMask());
}
