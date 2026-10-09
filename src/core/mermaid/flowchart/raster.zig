const std = @import("std");
const prim = @import("prim");
const sketch = @import("sketch.zig");
const lattice = @import("lattice.zig");
const nodes_r = @import("raster/nodes.zig");
const edges_r = @import("raster/edges.zig");
const rails_r = @import("raster/rails.zig");
const clusters_r = @import("raster/clusters.zig");
const labels_r = @import("raster/labels.zig");
const reconcile = @import("raster/reconcile.zig");
const crossings_r = @import("raster/crossings.zig");
const arrow_base_r = @import("raster/arrow_base.zig");

pub const RasterizeError = error{
    OutOfMemory,
    LatticeAllocFailed,
};

pub const RasterReport = struct {
    lattice: lattice.Lattice,
    edge_cells_lost: u32 = 0,
    labels_dropped: u32 = 0,
    labels_displaced: u32 = 0,
    label_plan: labels_r.LabelPlan = .{},
    crossings: crossings_r.CrossingCounts = .{},
    arrow_base: arrow_base_r.ArrowBaseCounts = .{},
};

pub fn rasterize(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    subgraph_edges: prim.SubgraphEdges,
) RasterizeError!RasterReport {
    const w = s.bbox.w;
    const h = s.bbox.h;

    if (w == 0 or h == 0) {
        return .{ .lattice = .{ .width = 0, .height = 0, .cells = &[_]lattice.Cell{} } };
    }

    const cells = allocator.alloc(lattice.Cell, @as(usize, w) * @as(usize, h)) catch {
        return error.LatticeAllocFailed;
    };
    for (cells) |*c| c.* = lattice.Cell.empty;

    var lat: lattice.Lattice = .{
        .width = w,
        .height = h,
        .cells = cells,
    };

    _ = try clusters_r.rasterizeClusters(allocator, &lat, s);
    _ = nodes_r.rasterizeNodes(&lat, s);
    const rail_cells_lost = rails_r.rasterizeRails(&lat, s);
    const edge_report = edges_r.rasterizeEdges(&lat, s, subgraph_edges);
    reconcile.reconcileNeighbours(&lat);
    const label_plan = try labels_r.rasterizeLabels(allocator, &lat, s);

    return .{
        .lattice = lat,
        .edge_cells_lost = edge_report.cells_lost + rail_cells_lost,
        .labels_dropped = label_plan.dropped(),
        .labels_displaced = label_plan.displaced(),
        .label_plan = label_plan,
        .crossings = edge_report.crossings,
        .arrow_base = arrow_base_r.validate(&lat),
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
}

test "foreign perpendicular crossing reads as a transversal, not a junction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        c.neighbours.toMask(),
    );
}

test "a rail rasterizes before edges: its cell keeps rail kind/role, foreign bits refused" {
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
    var rails_buf = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &stem,
        .crossbar = .{ .{ .x = 2, .y = 5 }, .{ .x = 22, .y = 5 } },
        .taps = &taps,
        .kind = .solid,
    }};

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
        .rails = rails_buf[0..],
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const r = try rasterize(a, s, .bridge);

    const cell = r.lattice.atConst(7, 5).*;
    switch (cell.occupant) {
        .edge_segment => |seg| {
            try testing.expectEqual(lattice.EdgeKind.solid, seg.kind);
            try testing.expectEqual(lattice.EdgeRole.fan_out_rail, seg.role);
        },
        else => return error.MissingJunctionCell,
    }
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
}
