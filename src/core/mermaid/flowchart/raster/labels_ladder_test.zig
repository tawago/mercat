const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels = @import("labels.zig");

const testing = std.testing;

const H: lattice.Neighbours = .{ .e = true, .w = true };
const V: lattice.Neighbours = .{ .n = true, .s = true };

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

fn labelCells(lat: lattice.Lattice) u32 {
    var n: u32 = 0;
    for (lat.cells) |c| n += @intFromBool(c.occupant == .label_char);
    return n;
}

fn emptySketch(bw: u32, bh: u32) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = bw, .h = bh },
        .direction = .LR,
        .nodes = &[_]sketch.NodePlacement{},
        .clusters = &[_]sketch.ClusterFrame{},
        .edges = &[_]sketch.EdgePath{},
        .diagnostics = &[_]sketch.Diagnostic{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn makeEdge(id: u32, poly: []const sketch.Point, label: []const u8) sketch.EdgePath {
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

fn put(lat: *lattice.Lattice, x: u32, y: u32, edge: u32, mask: lattice.Neighbours) void {
    lat.at(x, y).* = .{ .occupant = .{ .edge_segment = .{ .edge = edge, .kind = .solid } }, .neighbours = mask };
}

fn row(lat: *lattice.Lattice, y: u32, x0: u32, x1: u32, edge: u32) void {
    var x = x0;
    while (x <= x1) : (x += 1) put(lat, x, y, edge, H);
}

fn col(lat: *lattice.Lattice, x: u32, y0: u32, y1: u32, edge: u32) void {
    var y = y0;
    while (y <= y1) : (y += 1) put(lat, x, y, edge, V);
}

const short_h = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 4, .y = 3 } };

fn shortHorizontal(lat: *lattice.Lattice) void {
    put(lat, 1, 3, 42, .{ .e = true });
    put(lat, 2, 3, 42, H);
    put(lat, 3, 3, 42, H);
    put(lat, 4, 3, 42, .{ .w = true });
}

fn render(alloc: std.mem.Allocator, lat: *lattice.Lattice, poly: []const sketch.Point, label: []const u8) !labels.LabelPlan {
    const edges = try alloc.dupe(sketch.EdgePath, &.{makeEdge(42, poly, label)});
    var s = emptySketch(lat.width, lat.height);
    s.edges = edges;
    return labels.rasterizeLabels(alloc, lat, s);
}

test "beside: a foreign run alongside as close as the own run refuses the place; one strictly farther does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tied = try makeLattice(alloc, 8, 7);
    shortHorizontal(&tied);
    row(&tied, 1, 0, 7, 9);
    row(&tied, 5, 0, 7, 9);
    const refused = try render(alloc, &tied, &short_h, "x");
    try testing.expectEqual(labels.Omission.no_faithful_place, refused.edges[0].omitted.?);
    try testing.expectEqual(@as(u32, 0), labelCells(tied));

    var far = try makeLattice(alloc, 8, 7);
    shortHorizontal(&far);
    row(&far, 0, 0, 7, 9);
    const placed = try render(alloc, &far, &short_h, "x");
    try testing.expectEqual(labels.Form.beside_run, placed.edges[0].form.?);
    try testing.expectEqual(@as(u21, 'x'), cellChar(far, 2, 2));
}

test "beside a vertical run: a parallel foreign run at the own distance past the label's far end refuses that side" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const poly = [_]sketch.Point{ .{ .x = 3, .y = 1 }, .{ .x = 3, .y = 3 } };

    var tied = try makeLattice(alloc, 12, 5);
    put(&tied, 3, 1, 42, .{ .s = true });
    put(&tied, 3, 2, 42, V);
    put(&tied, 3, 3, 42, .{ .n = true });
    col(&tied, 8, 0, 4, 9);
    _ = try render(alloc, &tied, &poly, "ab");
    try testing.expectEqual(@as(u21, 0), cellChar(tied, 5, 2));
    try testing.expectEqual(@as(u21, 'a'), cellChar(tied, 0, 2));

    var far = try makeLattice(alloc, 12, 5);
    put(&far, 3, 1, 42, .{ .s = true });
    put(&far, 3, 2, 42, V);
    put(&far, 3, 3, 42, .{ .n = true });
    col(&far, 9, 0, 4, 9);
    _ = try render(alloc, &far, &poly, "ab");
    try testing.expectEqual(@as(u21, 'a'), cellChar(far, 5, 2));
}

test "beside: the nearest own run sets the own distance, not only the host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const poly = [_]sketch.Point{ .{ .x = 4, .y = 1 }, .{ .x = 8, .y = 1 }, .{ .x = 8, .y = 7 } };

    var lat = try makeLattice(alloc, 9, 9);
    put(&lat, 4, 1, 42, .{ .e = true });
    row(&lat, 1, 5, 7, 42);
    put(&lat, 8, 1, 42, .{ .w = true, .s = true });
    col(&lat, 8, 2, 6, 42);
    put(&lat, 8, 7, 42, .{ .n = true });
    col(&lat, 2, 0, 8, 9);

    const plan = try render(alloc, &lat, &poly, "abc");
    try testing.expectEqual(labels.Form.beside_run, plan.edges[0].form.?);
    try testing.expectEqual(@as(u21, 'a'), cellChar(lat, 4, 2));
}

test "beside: shared ink or rail interior across from the label refuses it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var joined = try makeLattice(alloc, 8, 7);
    shortHorizontal(&joined);
    joined.at(2, 3).occupant.edge_segment.cohabit = .joined;
    joined.at(3, 3).occupant.edge_segment.cohabit = .joined;
    const a = try render(alloc, &joined, &short_h, "x");
    try testing.expectEqual(labels.Omission.no_faithful_place, a.edges[0].omitted.?);

    var foreign = try makeLattice(alloc, 8, 7);
    shortHorizontal(&foreign);
    put(&foreign, 2, 3, 9, H);
    put(&foreign, 3, 3, 9, H);
    const b = try render(alloc, &foreign, &short_h, "x");
    try testing.expectEqual(labels.Omission.no_faithful_place, b.edges[0].omitted.?);

    var rail = try makeLattice(alloc, 8, 7);
    shortHorizontal(&rail);
    rail.at(2, 3).occupant.edge_segment.role = .fan_out_rail;
    rail.at(3, 3).occupant.edge_segment.role = .fan_out_rail;
    const c = try render(alloc, &rail, &short_h, "x");
    try testing.expectEqual(labels.Omission.no_faithful_place, c.edges[0].omitted.?);
    try testing.expectEqual(@as(u32, 0), labelCells(rail));
}

test "beside: a label whose only nearby own ink is an arrowhead is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const poly = [_]sketch.Point{ .{ .x = 3, .y = 0 }, .{ .x = 3, .y = 2 } };

    var lat = try makeLattice(alloc, 12, 4);
    lat.at(3, 0).* = .{ .occupant = .{ .node_border = .{ .node = 0, .role = .edge_s } }, .neighbours = .{} };
    lat.at(3, 1).* = .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 42 } }, .neighbours = .{ .n = true } };
    lat.at(3, 2).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_n } }, .neighbours = .{} };

    const plan = try render(alloc, &lat, &poly, "ab");
    try testing.expectEqual(@as(?labels.Form, null), plan.edges[0].form);
    try testing.expectEqual(labels.Omission.no_faithful_place, plan.edges[0].omitted.?);
    try testing.expectEqual(@as(u32, 0), labelCells(lat));
}

test "beside: touching a foreign box refuses the place, touching an own end box does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var foreign = try makeLattice(alloc, 8, 7);
    shortHorizontal(&foreign);
    foreign.at(2, 1).* = .{ .occupant = .{ .node_border = .{ .node = 7, .role = .edge_s } }, .neighbours = .{} };
    _ = try render(alloc, &foreign, &short_h, "x");
    try testing.expectEqual(@as(u21, 0), cellChar(foreign, 2, 2));
    try testing.expectEqual(@as(u21, 'x'), cellChar(foreign, 3, 2));

    var own = try makeLattice(alloc, 8, 7);
    shortHorizontal(&own);
    own.at(2, 1).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };
    _ = try render(alloc, &own, &short_h, "x");
    try testing.expectEqual(@as(u21, 'x'), cellChar(own, 2, 2));
}

test "beside: corners, heads and runs that meet the label end-on or diagonally do not pull it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 8, 7);
    shortHorizontal(&lat);
    put(&lat, 2, 0, 9, V);
    put(&lat, 2, 1, 9, .{ .n = true });
    put(&lat, 1, 1, 8, .{ .s = true, .w = true });
    lat.at(3, 2).* = .{ .occupant = .{ .arrowhead = .{ .dir = .east, .edge = 8 } }, .neighbours = .{ .w = true } };
    put(&lat, 0, 2, 7, H);
    put(&lat, 1, 2, 7, .{ .w = true });

    const plan = try render(alloc, &lat, &short_h, "x");
    try testing.expectEqual(labels.Form.beside_run, plan.edges[0].form.?);
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 2, 2));
}
