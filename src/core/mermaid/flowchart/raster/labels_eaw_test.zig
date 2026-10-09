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

fn fillNodeInterior(lat: *lattice.Lattice, rect: sketch.Rect, nid: u32) void {
    var y: i32 = rect.y + 1;
    while (y < rect.bottom() - 1) : (y += 1) {
        var x: i32 = rect.x + 1;
        while (x < rect.right() - 1) : (x += 1) {
            lat.at(@intCast(x), @intCast(y)).* = .{
                .occupant = .{ .node_interior = nid },
                .neighbours = .{},
            };
        }
    }
}

fn cellChar(lat: lattice.Lattice, x: u32, y: u32) u21 {
    return switch (lat.atConst(x, y).occupant) {
        .label_char => |c| c,
        else => 0,
    };
}

fn isCont(lat: lattice.Lattice, x: u32, y: u32) bool {
    return switch (lat.atConst(x, y).occupant) {
        .label_cont => true,
        else => false,
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

test "a wide node glyph whose second cell is not this node's interior is refused whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 5);
    const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = 8, .h = 3 };
    fillNodeInterior(&lat, rect, 1);
    lat.at(2, 1).* = .{ .occupant = .{ .node_interior = 9 }, .neighbours = .{} };

    const nodes = [_]sketch.NodePlacement{.{
        .id = 1,
        .rect = rect,
        .shape = .rect,
        .lines = &.{"日本語"},
        .cluster_id = null,
    }};
    var s = emptySketch(12, 5, .TD);
    s.nodes = &nodes;

    _ = try labels.rasterizeLabels(alloc, &lat, s);

    try testing.expectEqual(@as(u21, 0), cellChar(lat, 1, 1));
    try testing.expect(!isCont(lat, 1, 1));
    try testing.expectEqual(@as(u21, '本'), cellChar(lat, 3, 1));
    try testing.expect(isCont(lat, 4, 1));
}

test "wide cluster title advances by span and still closes the band" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 14, 6);
    var x: u32 = 0;
    while (x < 12) : (x += 1) {
        lat.at(x, 0).* = .{
            .occupant = .{ .cluster_border = .{ .cluster = 3, .role = .edge_n } },
            .neighbours = .{},
        };
    }

    const clusters = [_]sketch.ClusterFrame{.{
        .id = 3,
        .rect = .{ .x = 0, .y = 0, .w = 12, .h = 4 },
        .parent_id = null,
        .label = "日本",
        .depth = 0,
    }};
    var s = emptySketch(14, 6, .TD);
    s.clusters = &clusters;

    const plan = try labels.rasterizeLabels(alloc, &lat, s);
    try testing.expectEqual(@as(u32, 0), plan.dropped());

    try testing.expectEqual(@as(u21, ' '), cellChar(lat, 2, 0));
    try testing.expectEqual(@as(u21, '日'), cellChar(lat, 3, 0));
    try testing.expect(isCont(lat, 4, 0));
    try testing.expectEqual(@as(u21, '本'), cellChar(lat, 5, 0));
    try testing.expect(isCont(lat, 6, 0));
    try testing.expectEqual(@as(u21, ' '), cellChar(lat, 7, 0));
}

test "edge-label probe reserves display cells: a wide label no longer overwrites the ink beside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 8, 4);
    lat.at(4, 2).* = .{
        .occupant = .{ .edge_segment = .{ .edge = 77, .kind = .solid } },
        .neighbours = .{ .n = true, .s = true },
    };

    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "日本")};
    var s = emptySketch(8, 4, .LR);
    s.edges = &edges;

    const plan = try labels.rasterizeLabels(alloc, &lat, s);
    try testing.expectEqual(@as(u32, 1), plan.dropped());

    try testing.expect(switch (lat.atConst(4, 2).occupant) {
        .edge_segment => |seg| seg.edge == 77,
        else => false,
    });
}

test "an edge label paints a wide scalar and an interned flag each as head + continuation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 9, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "\u{1F1EF}\u{1F1F5} 日")};
    var s = emptySketch(12, 6, .LR);
    s.edges = &edges;

    const plan = try labels.rasterizeLabels(alloc, &lat, s);
    try testing.expectEqual(@as(u32, 0), plan.dropped());

    var found = false;
    var x: u32 = 0;
    while (x + 4 < lat.width) : (x += 1) {
        if (glyphAt(lat, x, 2)) |glyph| {
            try testing.expectEqualStrings("\u{1F1EF}\u{1F1F5}", glyph.bytes);
            try testing.expect(isCont(lat, x + 1, 2));
            try testing.expectEqual(@as(u21, ' '), cellChar(lat, x + 2, 2));
            try testing.expectEqual(@as(u21, '日'), cellChar(lat, x + 3, 2));
            try testing.expect(isCont(lat, x + 4, 2));
            found = true;
        }
    }
    try testing.expect(found);
}

test "blank-flank rule treats a continuation as a label neighbour" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const poly = [_]sketch.Point{ .{ .x = 3, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(5, &poly, "ab")};
    var s = emptySketch(8, 4, .LR);
    s.edges = &edges;

    var lat = try makeLattice(alloc, 8, 4);
    lat.at(2, 2).* = .{ .occupant = .{ .label_char = '日' }, .neighbours = .{} };
    lat.at(3, 2).* = .{ .occupant = .label_cont, .neighbours = .{} };

    const plan = try labels.rasterizeLabels(alloc, &lat, s);
    try testing.expectEqual(@as(u32, 1), plan.dropped());

    var free_lat = try makeLattice(alloc, 8, 4);
    free_lat.at(2, 2).* = .{ .occupant = .{ .label_char = '日' }, .neighbours = .{} };

    const free_plan = try labels.rasterizeLabels(alloc, &free_lat, s);
    try testing.expectEqual(@as(u32, 0), free_plan.dropped());
}

fn glyphAt(lat: lattice.Lattice, x: u32, y: u32) ?lattice.Glyph {
    return lat.glyphOf(cellChar(lat, x, y));
}

fn nodeSketch(rect: sketch.Rect, lines: []const []const u8) struct { nodes: [1]sketch.NodePlacement } {
    return .{ .nodes = .{.{
        .id = 1,
        .rect = rect,
        .shape = .rect,
        .lines = lines,
        .cluster_id = null,
    }} };
}

test "node labels: a wide scalar writes head + continuation; an interned grapheme writes a reference, narrow or wide" {
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const Want = union(enum) { char: u21, cont, not_cont, ref: struct { bytes: []const u8, width: u8 } };
    const Row = struct { line: []const u8, rect_w: u32, want: []const Want };
    const rows = [_]Row{
        .{ .line = "日本語", .rect_w = 8, .want = &.{ .{ .char = '日' }, .cont, .{ .char = '本' }, .cont, .{ .char = '語' }, .cont } },
        .{ .line = "cafe\u{0301}", .rect_w = 6, .want = &.{ .{ .char = 'c' }, .{ .char = 'a' }, .{ .char = 'f' }, .{ .ref = .{ .bytes = "e\u{0301}", .width = 1 } }, .not_cont } },
        .{ .line = family ++ " x", .rect_w = 6, .want = &.{ .{ .ref = .{ .bytes = family, .width = 2 } }, .cont, .{ .char = ' ' }, .{ .char = 'x' } } },
    };
    for (rows, 0..) |r, ri| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var lat = try makeLattice(alloc, 12, 5);
        const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = r.rect_w, .h = 3 };
        fillNodeInterior(&lat, rect, 1);
        const fixture = nodeSketch(rect, &.{r.line});
        var s = emptySketch(12, 5, .TD);
        s.nodes = &fixture.nodes;

        const plan = try labels.rasterizeLabels(alloc, &lat, s);
        try testing.expectEqual(@as(u32, 0), plan.dropped());
        if (ri == 0) try testing.expectEqual(@as(usize, 0), lat.glyphs.len);
        for (r.want, 1..) |w, x| switch (w) {
            .char => |c| try testing.expectEqual(c, cellChar(lat, @intCast(x), 1)),
            .cont => try testing.expect(isCont(lat, @intCast(x), 1)),
            .not_cont => try testing.expect(!isCont(lat, @intCast(x), 1)),
            .ref => |g| {
                try testing.expect(lattice.isGlyphRef(cellChar(lat, @intCast(x), 1)));
                const glyph = glyphAt(lat, @intCast(x), 1).?;
                try testing.expectEqualStrings(g.bytes, glyph.bytes);
                try testing.expectEqual(g.width, glyph.width);
            },
        };
    }
}
