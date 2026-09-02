//! Unit tests for raster/rails.zig — junction bits must come out of
//! tap geometry deterministically (the point of Phase 4b slice iv).

const std = @import("std");
const testing = std.testing;
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const nodes_r = @import("nodes.zig");
const rails_r = @import("rails.zig");
const raster = @import("../raster.zig");

/// Allocate a lattice sized to the sketch bbox, rasterize nodes (so the
/// pivot border exists for the stem-exit merge), then rails.
const Raster = struct { lattice: lattice.Lattice, report: rails_r.Report };
fn rasterizeForTest(a: std.mem.Allocator, s: sketch.Sketch) !Raster {
    const cells = try a.alloc(lattice.Cell, @as(usize, s.bbox.w) * @as(usize, s.bbox.h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    var lat: lattice.Lattice = .{ .width = s.bbox.w, .height = s.bbox.h, .cells = cells };
    _ = try nodes_r.rasterizeNodes(a, &lat, s);
    const report = rails_r.rasterizeRails(&lat, s, null);
    return .{ .lattice = lat, .report = report };
}

/// Standard single-row fan: pivot over three peers (left / center /
/// right). The center tap drops straight through the junction.
pub fn fanSketch(
    nodes: []sketch.NodePlacement,
    taps: []sketch.Tap,
    stem: []sketch.Point,
    rails: []sketch.Rail,
) sketch.Sketch {
    nodes[0] = .{ .id = 0, .rect = .{ .x = 10, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    nodes[1] = .{ .id = 1, .rect = .{ .x = 0, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    nodes[2] = .{ .id = 2, .rect = .{ .x = 10, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    nodes[3] = .{ .id = 3, .rect = .{ .x = 20, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    stem[0] = .{ .x = 12, .y = 2 };
    stem[1] = .{ .x = 12, .y = 5 };
    taps[0] = .{ .edge = 0, .node = 1, .at = .{ .x = 2, .y = 5 }, .landing = .{ .x = 2, .y = 7 } };
    taps[1] = .{ .edge = 1, .node = 2, .at = .{ .x = 12, .y = 5 }, .landing = .{ .x = 12, .y = 7 } };
    taps[2] = .{ .edge = 2, .node = 3, .at = .{ .x = 22, .y = 5 }, .landing = .{ .x = 22, .y = 7 } };
    rails[0] = .{
        .pivot = 0,
        .stem = stem,
        .crossbar = .{ .{ .x = 2, .y = 5 }, .{ .x = 22, .y = 5 } },
        .taps = taps,
        .kind = .solid,
    };
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 25, .h = 10 },
        .direction = .TD,
        .nodes = nodes,
        .clusters = &.{},
        .edges = &.{},
        .rails = rails,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

test "rail junction bits are explicit: corner, tee, cross" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes: [4]sketch.NodePlacement = undefined;
    var taps: [3]sketch.Tap = undefined;
    var stem: [2]sketch.Point = undefined;
    var rails: [1]sketch.Rail = undefined;
    const s = fanSketch(&nodes, &taps, &stem, &rails);

    const r = try rasterizeForTest(a, s);

    try testing.expectEqual(@as(u4, 0b0110), r.lattice.atConst(2, 5).neighbours.toMask());
    try testing.expectEqual(@as(u4, 0b1111), r.lattice.atConst(12, 5).neighbours.toMask());
    try testing.expectEqual(@as(u4, 0b1100), r.lattice.atConst(22, 5).neighbours.toMask());
    try testing.expectEqual(@as(u4, 0b1010), r.lattice.atConst(7, 5).neighbours.toMask());
    const stem_cell = r.lattice.atConst(12, 4).*;
    try testing.expectEqual(@as(u4, 0b0101), stem_cell.neighbours.toMask());
    switch (stem_cell.occupant) {
        .edge_segment => |seg| try testing.expectEqual(lattice.EdgeRole.fan_out_rail, seg.role),
        else => return error.MissingStemCell,
    }
    inline for (.{ 2, 12, 22 }) |x| {
        switch (r.lattice.atConst(x, 6).occupant) {
            .arrowhead => |ah| try testing.expectEqual(lattice.Dir4.south, ah.dir),
            else => return error.MissingArrowhead,
        }
    }
    try testing.expect(r.lattice.atConst(12, 2).neighbours.s);
    try testing.expectEqual(@as(u32, 3), r.report.taps_written);
    try testing.expectEqual(@as(u32, 0), r.report.cells_lost);
}

/// Every record of `kind` filed at (x, y), by ascending `value`. The table
/// is sorted by (cell, kind, value), so a scan of the whole slice is both
/// the simplest and the order-faithful way to ask.
pub fn recordsAt(
    a: std.mem.Allocator,
    lat: lattice.Lattice,
    kind: lattice.AuxKind,
    x: u32,
    y: u32,
) ![]const lattice.Aux {
    var out: std.ArrayListUnmanaged(lattice.Aux) = .empty;
    const idx = lat.cellIndex(x, y);
    for (lat.aux) |rec| {
        if (rec.kind == kind and rec.cell == idx) try out.append(a, rec);
    }
    return out.items;
}

test "a rail files its members on the shared run and a tap at each branch cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes: [4]sketch.NodePlacement = undefined;
    var taps: [3]sketch.Tap = undefined;
    var stem: [2]sketch.Point = undefined;
    var rails: [1]sketch.Rail = undefined;
    const s = fanSketch(&nodes, &taps, &stem, &rails);

    const r = try raster.rasterize(a, s, .bridge);
    const lat = r.lattice;

    for ([_]struct { x: u32, edge: u32 }{
        .{ .x = 2, .edge = 0 },
        .{ .x = 12, .edge = 1 },
        .{ .x = 22, .edge = 2 },
    }) |want| {
        const at_branch = try recordsAt(a, lat, .tap, want.x, 5);
        try testing.expectEqual(@as(usize, 1), at_branch.len);
        try testing.expectEqual(want.edge, at_branch[0].value);
        try testing.expectEqual(@intFromEnum(lattice.RailPolarity.out), at_branch[0].detail);
    }
    var taps_filed: u32 = 0;
    for (lat.aux) |rec| {
        if (rec.kind == .tap) taps_filed += 1;
    }
    try testing.expectEqual(@as(u32, 3), taps_filed);

    const on_stem = try recordsAt(a, lat, .rail_member, 12, 4);
    try testing.expectEqual(@as(usize, 2), on_stem.len);
    try testing.expectEqual(@as(u32, 1), on_stem[0].value);
    try testing.expectEqual(@as(u32, 2), on_stem[1].value);

    const at_junction = try recordsAt(a, lat, .rail_member, 12, 5);
    try testing.expectEqual(@as(usize, 2), at_junction.len);

    const east = try recordsAt(a, lat, .rail_member, 17, 5);
    try testing.expectEqual(@as(usize, 1), east.len);
    try testing.expectEqual(@as(u32, 2), east[0].value);

    const west = try recordsAt(a, lat, .rail_member, 7, 5);
    try testing.expectEqual(@as(usize, 0), west.len);

    for (lat.aux) |rec| {
        if (rec.kind != .rail_member) continue;
        switch (lat.cells[rec.cell].occupant) {
            .edge_segment => |seg| try testing.expect(seg.edge != rec.value),
            .arrowhead => |head| try testing.expect(head.edge != rec.value),
            else => {},
        }
    }
}

test "a rail without center tap yields a clean ┴ junction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes: [3]sketch.NodePlacement = undefined;
    nodes[0] = .{ .id = 0, .rect = .{ .x = 10, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    nodes[1] = .{ .id = 1, .rect = .{ .x = 0, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    nodes[2] = .{ .id = 2, .rect = .{ .x = 20, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    var stem = [_]sketch.Point{ .{ .x = 12, .y = 2 }, .{ .x = 12, .y = 5 } };
    var taps = [_]sketch.Tap{
        .{ .edge = 0, .node = 1, .at = .{ .x = 2, .y = 5 }, .landing = .{ .x = 2, .y = 7 } },
        .{ .edge = 1, .node = 2, .at = .{ .x = 22, .y = 5 }, .landing = .{ .x = 22, .y = 7 } },
    };
    var rails = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &stem,
        .crossbar = .{ .{ .x = 2, .y = 5 }, .{ .x = 22, .y = 5 } },
        .taps = &taps,
        .kind = .solid,
    }};
    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 25, .h = 10 },
        .direction = .TD,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &.{},
        .rails = &rails,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const r = try rasterizeForTest(a, s);
    try testing.expectEqual(@as(u4, 0b1011), r.lattice.atConst(12, 5).neighbours.toMask());
}

test "V-D-TRUNK-10: fan-IN rail stamps one pivot arrow off the shared run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes = [_]sketch.NodePlacement{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 20, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 0, .rect = .{ .x = 10, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    var stem = [_]sketch.Point{ .{ .x = 12, .y = 7 }, .{ .x = 12, .y = 4 } };
    var taps = [_]sketch.Tap{
        .{ .edge = 10, .node = 1, .at = .{ .x = 2, .y = 4 }, .landing = .{ .x = 2, .y = 2 }, .arrow = .none },
        .{ .edge = 11, .node = 2, .at = .{ .x = 22, .y = 4 }, .landing = .{ .x = 22, .y = 2 }, .arrow = .none },
    };
    var rails = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &stem,
        .crossbar = .{ .{ .x = 2, .y = 4 }, .{ .x = 22, .y = 4 } },
        .taps = &taps,
        .kind = .solid,
        .role = .fan_in_dropper,
        .pivot_arrow = .filled,
    }};
    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 25, .h = 10 },
        .direction = .TD,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &.{},
        .rails = &rails,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const r = try rasterizeForTest(a, s);
    var arrows: u32 = 0;
    for (r.lattice.cells) |cell| switch (cell.occupant) {
        .arrowhead => arrows += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), arrows);
    switch (r.lattice.atConst(12, 6).occupant) {
        .arrowhead => |ah| try testing.expectEqual(lattice.Dir4.south, ah.dir),
        else => return error.MissingPivotArrow,
    }
    switch (r.lattice.atConst(12, 4).occupant) {
        .edge_segment => |seg| try testing.expectEqual(lattice.EdgeRole.fan_in_rail, seg.role),
        else => return error.MissingSharedRun,
    }
    switch (r.lattice.atConst(2, 3).occupant) {
        .edge_segment => |seg| try testing.expectEqual(lattice.EdgeRole.fan_in_dropper, seg.role),
        else => return error.MissingRiserTap,
    }
    try testing.expectEqual(@as(u32, 0), r.report.cells_lost);
}

test "a rail plus separated edges is byte and report invariant under edge write order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nodes: [4]sketch.NodePlacement = undefined;
    var taps: [3]sketch.Tap = undefined;
    var stem: [2]sketch.Point = undefined;
    var rails: [1]sketch.Rail = undefined;
    var base = fanSketch(&nodes, &taps, &stem, &rails);
    base.bbox.h = 12;
    const p0 = [_]sketch.Point{ .{ .x = 0, .y = 10 }, .{ .x = 24, .y = 10 } };
    const p1 = [_]sketch.Point{ .{ .x = 0, .y = 11 }, .{ .x = 24, .y = 11 } };
    const e0: sketch.EdgePath = .{
        .id = 10,
        .from = 1,
        .to = 3,
        .polyline = &p0,
        .port_from = .{ .node = 1, .side = .south, .offset = 1 },
        .port_to = .{ .node = 3, .side = .south, .offset = 1 },
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
        .kind = .dotted,
    };
    const e1: sketch.EdgePath = .{
        .id = 11,
        .from = 3,
        .to = 1,
        .polyline = &p1,
        .port_from = .{ .node = 3, .side = .south, .offset = 3 },
        .port_to = .{ .node = 1, .side = .south, .offset = 3 },
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
        .kind = .thick,
    };
    const forward = [_]sketch.EdgePath{ e0, e1 };
    const reverse = [_]sketch.EdgePath{ e1, e0 };
    var first_sketch = base;
    first_sketch.edges = &forward;
    var second_sketch = base;
    second_sketch.edges = &reverse;
    const first = try raster.rasterize(a, first_sketch, .bridge);
    const second = try raster.rasterize(a, second_sketch, .bridge);

    try testing.expectEqualSlices(lattice.Cell, first.lattice.cells, second.lattice.cells);
    try testing.expectEqual(first.nodes_written, second.nodes_written);
    try testing.expectEqual(first.clusters_written, second.clusters_written);
    try testing.expectEqual(first.edges_written, second.edges_written);
    try testing.expectEqual(first.labels_placed, second.labels_placed);
    try testing.expectEqual(first.edge_cells_lost, second.edge_cells_lost);
    try testing.expectEqual(first.labels_dropped, second.labels_dropped);
    try testing.expectEqual(first.labels_displaced, second.labels_displaced);
    try testing.expectEqual(first.phantom_arms_cleared, second.phantom_arms_cleared);
}

test "a tap head facing the landing leaves the member border pristine; an undecorated tap tees it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plain = (lattice.Neighbours{ .e = true, .w = true }).toMask();
    const teed = (lattice.Neighbours{ .e = true, .w = true, .n = true }).toMask();

    {
        var nodes: [4]sketch.NodePlacement = undefined;
        var taps: [3]sketch.Tap = undefined;
        var stem: [2]sketch.Point = undefined;
        var rails: [1]sketch.Rail = undefined;
        const s = fanSketch(&nodes, &taps, &stem, &rails);
        const r = try rasterizeForTest(a, s);
        inline for (.{ 2, 12, 22 }) |x| {
            try testing.expectEqual(plain, r.lattice.atConst(x, 7).neighbours.toMask());
        }
    }
    {
        var nodes: [4]sketch.NodePlacement = undefined;
        var taps: [3]sketch.Tap = undefined;
        var stem: [2]sketch.Point = undefined;
        var rails: [1]sketch.Rail = undefined;
        const s = fanSketch(&nodes, &taps, &stem, &rails);
        for (&taps) |*t| t.arrow = .none;
        const r = try rasterizeForTest(a, s);
        inline for (.{ 2, 12, 22 }) |x| {
            try testing.expectEqual(teed, r.lattice.atConst(x, 7).neighbours.toMask());
        }
    }
    {
        var nodes: [4]sketch.NodePlacement = undefined;
        var taps: [3]sketch.Tap = undefined;
        var stem: [2]sketch.Point = undefined;
        var rails: [1]sketch.Rail = undefined;
        const s = fanSketch(&nodes, &taps, &stem, &rails);
        for (nodes[1..]) |*n| n.rect.y = 6;
        for (&taps) |*t| t.landing.y = 6;
        const r = try rasterizeForTest(a, s);
        inline for (.{ 2, 12, 22 }) |x| {
            try testing.expectEqual(teed, r.lattice.atConst(x, 6).neighbours.toMask());
        }
    }
}

test "a pivot head facing the border leaves it pristine; a detached one tees" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plain = (lattice.Neighbours{ .e = true, .w = true }).toMask();
    const teed = (lattice.Neighbours{ .e = true, .w = true, .s = true }).toMask();

    inline for (.{ true, false }) |decorated| {
        var nodes: [4]sketch.NodePlacement = undefined;
        var taps: [3]sketch.Tap = undefined;
        var stem: [2]sketch.Point = undefined;
        var rails: [1]sketch.Rail = undefined;
        const s = fanSketch(&nodes, &taps, &stem, &rails);
        rails[0].role = .fan_in_dropper;
        rails[0].pivot_arrow = if (decorated) .filled else .none;
        for (&taps) |*t| t.arrow = .none;
        const r = try rasterizeForTest(a, s);
        try testing.expectEqual(
            if (decorated) plain else teed,
            r.lattice.atConst(12, 2).neighbours.toMask(),
        );
    }
    {
        var nodes: [4]sketch.NodePlacement = undefined;
        var taps: [3]sketch.Tap = undefined;
        var stem: [2]sketch.Point = undefined;
        var rails: [1]sketch.Rail = undefined;
        const s = fanSketch(&nodes, &taps, &stem, &rails);
        rails[0].role = .fan_in_dropper;
        rails[0].pivot_arrow = .filled;
        stem[0] = .{ .x = 12, .y = 3 };
        for (&taps) |*t| t.arrow = .none;
        const r = try rasterizeForTest(a, s);
        try testing.expectEqual(teed, r.lattice.atConst(12, 2).neighbours.toMask());
    }
}

test {
    _ = @import("rails_test2.zig");
}
