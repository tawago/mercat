const std = @import("std");
const testing = std.testing;
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const raster = @import("../raster.zig");
const colour = @import("colour.zig");
const labels_write = @import("labels_write.zig");
const rails_test = @import("rails_test.zig");

const Rgb = prim.Rgb;
const red: Rgb = .{ .r = 0xff, .g = 0, .b = 0 };
const green: Rgb = .{ .r = 0, .g = 0xff, .b = 0 };
const blue: Rgb = .{ .r = 0, .g = 0, .b = 0xff };
const orange: Rgb = .{ .r = 0xff, .g = 0x88, .b = 0 };

fn cellAt(lat: lattice.Lattice, x: u32, y: u32) lattice.Cell {
    return lat.atConst(x, y).*;
}

fn wears(lat: lattice.Lattice, x: u32, y: u32) ?Rgb {
    return lat.colourOf(cellAt(lat, x, y).colour);
}

fn edge(id: u32, poly: []const sketch.Point, arrow_to: sketch.ArrowKind) sketch.EdgePath {
    return .{
        .id = id,
        .from = 0,
        .to = 0,
        .polyline = poly,
        .port_from = .{ .node = 0, .side = .south, .offset = 0 },
        .port_to = .{ .node = 0, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = arrow_to,
        .label = null,
        .kind = .solid,
        .origin = id,
    };
}

const Scene = struct {
    nodes: [3]sketch.NodePlacement,
    p0: [4]sketch.Point = .{ .{ .x = 3, .y = 2 }, .{ .x = 3, .y = 5 }, .{ .x = 6, .y = 5 }, .{ .x = 6, .y = 8 } },
    p1: [2]sketch.Point = .{ .{ .x = 13, .y = 3 }, .{ .x = 13, .y = 8 } },
    p2: [2]sketch.Point = .{ .{ .x = 9, .y = 6 }, .{ .x = 18, .y = 6 } },
    edges: [3]sketch.EdgePath = undefined,

    fn sketchOf(self: *Scene, edge_colours: []const ?Rgb) sketch.Sketch {
        self.edges = .{ edge(0, &self.p0, .filled), edge(1, &self.p1, .none), edge(2, &self.p2, .none) };
        return .{
            .bbox = .{ .x = 0, .y = 0, .w = 20, .h = 11 },
            .direction = .TD,
            .nodes = &self.nodes,
            .clusters = &.{},
            .edges = &self.edges,
            .edge_colours = edge_colours,
            .diagnostics = &.{},
            .budget = .{ .max_width = 80, .rung = 0 },
        };
    }
};

fn scene(outlines: [2]?Rgb) Scene {
    const lines_a = [_][]const u8{"Ab"};
    return .{ .nodes = .{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 7, .h = 3 }, .shape = .rect, .lines = &lines_a, .cluster_id = null, .outline = outlines[0] },
        .{ .id = 1, .rect = .{ .x = 10, .y = 0, .w = 7, .h = 3 }, .shape = .subroutine, .lines = &.{}, .cluster_id = null, .outline = outlines[1] },
        .{ .id = 2, .rect = .{ .x = 3, .y = 8, .w = 7, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    } };
}

test "a node wears its outline on its border, its port, its inner wall and its label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = scene(.{ red, green });
    const lat = (try raster.rasterize(arena.allocator(), sc.sketchOf(&.{ blue, orange, null }), .bridge)).lattice;

    try testing.expectEqual(@as(?Rgb, red), wears(lat, 0, 0));
    try testing.expect(cellAt(lat, 3, 2).neighbours.s);
    try testing.expectEqual(@as(?Rgb, red), wears(lat, 3, 2));
    try testing.expect(cellAt(lat, 2, 1).occupant == .label_char);
    try testing.expectEqual(@as(?Rgb, red), wears(lat, 2, 1));
    try testing.expectEqual(@as(?Rgb, green), wears(lat, 11, 1));
    try testing.expectEqual(@as(?Rgb, null), wears(lat, 3, 8));
}

test "an edge wears its colour from departure to arrival, head and port gap included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = scene(.{ red, green });
    const lat = (try raster.rasterize(arena.allocator(), sc.sketchOf(&.{ blue, orange, null }), .bridge)).lattice;

    try testing.expectEqual(@as(?Rgb, blue), wears(lat, 3, 3));
    try testing.expectEqual(@as(?Rgb, blue), wears(lat, 3, 5));
    try testing.expect(cellAt(lat, 6, 7).occupant == .arrowhead);
    try testing.expectEqual(@as(?Rgb, blue), wears(lat, 6, 7));
    try testing.expect(cellAt(lat, 13, 3).occupant == .edge_segment);
    try testing.expectEqual(@as(?Rgb, orange), wears(lat, 13, 3));
    try testing.expectEqual(@as(?Rgb, orange), wears(lat, 13, 4));
    try testing.expectEqual(@as(?Rgb, null), wears(lat, 10, 6));
}

test "a crossing keeps a colour only when both edges wear it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = scene(.{ null, null });
    const mixed = (try raster.rasterize(arena.allocator(), sc.sketchOf(&.{ null, orange, null }), .bridge)).lattice;
    try testing.expectEqual(@as(?Rgb, null), wears(mixed, 13, 6));
    const differ = (try raster.rasterize(arena.allocator(), sc.sketchOf(&.{ null, orange, blue }), .bridge)).lattice;
    try testing.expectEqual(@as(?Rgb, null), wears(differ, 13, 6));
    const same = (try raster.rasterize(arena.allocator(), sc.sketchOf(&.{ null, orange, orange }), .bridge)).lattice;
    try testing.expectEqual(@as(?Rgb, orange), wears(same, 13, 6));
}

test "colour changes no occupant, neighbour, stroke or shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var plain_scene = scene(.{ null, null });
    const plain = (try raster.rasterize(arena.allocator(), plain_scene.sketchOf(&.{}), .bridge)).lattice;
    var sc = scene(.{ red, green });
    const coloured = (try raster.rasterize(arena.allocator(), sc.sketchOf(&.{ blue, orange, red }), .bridge)).lattice;
    for (plain.cells, coloured.cells) |p, c| {
        try testing.expectEqual(@as(u8, 0), p.colour);
        var stripped = c;
        stripped.colour = 0;
        try testing.expectEqualDeep(p, stripped);
    }
}

test "a rail's shared cells wear its taps' colour only when they agree; arms and droppers keep their own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nodes: [4]sketch.NodePlacement = undefined;
    var taps: [3]sketch.Tap = undefined;
    var stem: [2]sketch.Point = undefined;
    var rails: [1]sketch.Rail = undefined;
    var s = rails_test.fanSketch(&nodes, &taps, &stem, &rails);
    for (&taps, 0..) |*t, i| t.origin = @intCast(i);
    rails[0].pivot_arrow = .filled;

    s.edge_colours = &.{ red, red, red };
    const agree = (try raster.rasterize(a, s, .bridge)).lattice;
    try testing.expectEqual(@as(?Rgb, red), wears(agree, 5, 5));
    try testing.expectEqual(@as(?Rgb, red), wears(agree, 12, 4));
    try testing.expect(cellAt(agree, 12, 3).occupant == .arrowhead);
    try testing.expectEqual(@as(?Rgb, red), wears(agree, 12, 3));
    try testing.expectEqual(@as(?Rgb, red), wears(agree, 2, 6));

    s.edge_colours = &.{ red, blue, red };
    const mixed = (try raster.rasterize(a, s, .bridge)).lattice;
    try testing.expectEqual(@as(?Rgb, null), wears(mixed, 12, 5));
    try testing.expectEqual(@as(?Rgb, null), wears(mixed, 12, 4));
    try testing.expectEqual(@as(?Rgb, null), wears(mixed, 12, 3));
    try testing.expectEqual(@as(?Rgb, red), wears(mixed, 5, 5));
    try testing.expectEqual(@as(?Rgb, red), wears(mixed, 2, 5));
    try testing.expectEqual(@as(?Rgb, red), wears(mixed, 17, 5));
    try testing.expectEqual(@as(?Rgb, red), wears(mixed, 22, 5));
    try testing.expectEqual(@as(?Rgb, red), wears(mixed, 2, 6));
    try testing.expectEqual(@as(?Rgb, blue), wears(mixed, 12, 6));

    s.edge_colours = &.{ red, null, null };
    const lone = (try raster.rasterize(a, s, .bridge)).lattice;
    try testing.expectEqual(@as(?Rgb, red), wears(lone, 2, 5));
    try testing.expectEqual(@as(?Rgb, red), wears(lone, 7, 5));
    try testing.expectEqual(@as(?Rgb, null), wears(lone, 12, 5));
    try testing.expectEqual(@as(?Rgb, null), wears(lone, 17, 5));
}

test "a label keeps a node interior's colour and clears any other" {
    var cells = [_]lattice.Cell{ lattice.Cell.empty, lattice.Cell.empty };
    cells[0] = .{ .occupant = .{ .node_interior = 0 }, .neighbours = .{}, .colour = 1 };
    cells[1] = .{ .occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid } }, .neighbours = .{}, .colour = 1 };
    var lat: lattice.Lattice = .{ .width = 2, .height = 1, .cells = &cells, .palette = &.{red} };
    labels_write.writeGlyph(&lat, 0, 0, 'a');
    labels_write.writeGlyph(&lat, 1, 0, 'b');
    try testing.expectEqual(@as(u8, 1), cells[0].colour);
    try testing.expectEqual(@as(u8, 0), cells[1].colour);
}

test "the palette holds each colour once and caps at 255" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var many: [300]?Rgb = undefined;
    for (&many, 0..) |*c, i| c.* = .{ .r = @intCast(i % 256), .g = @intCast(i / 256), .b = 0 };
    many[1] = many[0];
    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .edge_colours = &many,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
    const p = try colour.palette(a, s);
    try testing.expectEqual(@as(usize, 255), p.len);
    const lat: lattice.Lattice = .{ .width = 0, .height = 0, .cells = &.{}, .palette = p };
    try testing.expectEqual(@as(u8, 0), colour.index(&lat, many[299]));
    try testing.expectEqual(@as(u8, 1), colour.index(&lat, many[1]));
}
