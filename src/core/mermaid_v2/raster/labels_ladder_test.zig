//! Unit tests for the labels_edge.zig three-pass ladder (the RELOCATION
//! LAW's relocate-before-reroute plus the ISOLATION LAW's label-region
//! isolation). Split out of
//! labels_test.zig for the mermaid_v2 500-line cap.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels = @import("labels.zig");

const testing = std.testing;

fn makeLattice(alloc: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try alloc.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn cellChar(lat: lattice.Lattice, x: u32, y: u32) u21 {
    return switch (lat.atConst(x, y).occupant) {
        .label_char => |c| c,
        else => 0,
    };
}

fn emptySketch(bw: u32, bh: u32, dir: sketch.Direction) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = bw, .h = bh },
        .direction = dir,
        .nodes = &[_]sketch.NodePlacement{},
        .clusters = &[_]sketch.ClusterFrame{},
        .edges = &[_]sketch.EdgePath{},
        .diagnostics = &[_]sketch.Diagnostic{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn makeEdge(id: u32, poly: []const sketch.Point, label: ?[]const u8) sketch.EdgePath {
    return .{
        .id = id,
        .from = 0,
        .to = 1,
        .polyline = poly,
        .port_from = .{ .node = 0, .side = .east, .offset = 0 },
        .port_to = .{ .node = 1, .side = .west, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = label,
        .kind = .solid,
    };
}

fn stampEdgeCell(lat: *lattice.Lattice, x: u32, y: u32, edge_id: u32) void {
    lat.at(x, y).* = .{
        .occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = .solid } },
        .neighbours = .{ .w = true, .e = true },
    };
}

test "own-edge ink beside the anchor does not displace the label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "xy")};
    var s = emptySketch(12, 6, .LR);
    s.edges = &edges;

    var x: u32 = 1;
    while (x <= 5) : (x += 1) stampEdgeCell(&lat, x, 3, 42);

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(u32, 0), report.displaced);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 3, 2));
}

test "isolation rejects a foreign-ink neighbour in every one of the 8 directions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const dirs = [8][2]i32{
        .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
        .{ -1, 0 },  .{ 1, 0 },  .{ -1, 1 },
        .{ 0, 1 },   .{ 1, 1 },
    };
    for (dirs) |d| {
        var lat = try makeLattice(alloc, 12, 7);
        const poly = [_]sketch.Point{ .{ .x = 5, .y = 1 }, .{ .x = 5, .y = 5 } };
        const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
        var s = emptySketch(12, 7, .TD);
        s.edges = &edges;

        stampEdgeCell(&lat, @intCast(7 + d[0]), @intCast(3 + d[1]), 9);

        const report = try labels.rasterizeLabels(alloc, &lat, s, null);
        try testing.expectEqual(@as(u32, 1), report.placed);
        try testing.expectEqual(@as(u32, 1), report.displaced);
        try testing.expectEqual(@as(u21, 0), cellChar(lat, 7, 3));
    }
}

test "the own_adjacent pass beats the primary anchor: the label relocates to sit by its own edge's ink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 14, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 9, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(14, 6, .LR);
    s.edges = &edges;

    stampEdgeCell(&lat, 9, 3, 42);

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(u32, 1), report.displaced);

    try testing.expectEqual(@as(u21, 0), cellChar(lat, 5, 2));
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 7, 2));
}

test "the own_nearest pass walks the label toward its own edge's ink when own_adjacent positions are blocked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 16, 4);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 13, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(16, 4, .LR);
    s.edges = &edges;

    stampEdgeCell(&lat, 13, 3, 42);
    lat.at(12, 1).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };
    lat.at(13, 1).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(u32, 1), report.displaced);

    try testing.expectEqual(@as(u21, 0), cellChar(lat, 7, 2));
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 9, 2));
}

test "allow_solid waives only the node/cluster margin, never the foreign-edge margin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const poly = [_]sketch.Point{ .{ .x = 1, .y = 2 }, .{ .x = 9, .y = 2 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(12, 5, .LR);
    s.edges = &edges;

    var lat = try makeLattice(alloc, 12, 5);
    var x: u32 = 0;
    while (x < 12) : (x += 1) {
        lat.at(x, 0).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };
        lat.at(x, 4).* = .{ .occupant = .{ .node_border = .{ .node = 2, .role = .edge_n } }, .neighbours = .{} };
    }
    const solid_report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), solid_report.placed);
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 5, 1));

    var lat2 = try makeLattice(alloc, 12, 5);
    x = 0;
    while (x < 12) : (x += 1) {
        stampEdgeCell(&lat2, x, 0, 9);
        stampEdgeCell(&lat2, x, 4, 9);
    }
    const edge_report = try labels.rasterizeLabels(alloc, &lat2, s, null);
    try testing.expectEqual(@as(u32, 0), edge_report.placed);
    try testing.expectEqual(@as(u32, 1), edge_report.dropped);
}

test "edge-label placement is deterministic: identical lattices place identically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 9, .y = 3 } };
    const edges = [_]sketch.EdgePath{ makeEdge(42, &poly, "ab"), makeEdge(7, &poly, "cd") };
    var s = emptySketch(14, 6, .LR);
    s.edges = &edges;

    var grids: [2]lattice.Lattice = undefined;
    for (&grids) |*g| {
        g.* = try makeLattice(alloc, 14, 6);
        stampEdgeCell(g, 9, 3, 42);
        _ = try labels.rasterizeLabels(alloc, g, s, null);
    }
    for (grids[0].cells, grids[1].cells) |c0, c1| {
        try testing.expect(std.meta.eql(c0.occupant, c1.occupant));
    }
}
