//! Unit tests for raster/labels_ink.zig — ink ownership classification,
//! ISOLATION LAW span isolation, and nearest-ink distance measurement.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ink = @import("labels_ink.zig");

const testing = std.testing;

fn makeLattice(alloc: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try alloc.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn stampEdge(lat: *lattice.Lattice, x: u32, y: u32, edge_id: u32) void {
    lat.at(x, y).* = .{
        .occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = .solid } },
        .neighbours = .{ .w = true, .e = true },
    };
}

/// Owner with a degenerate far-away segment and no polyline: ownership
/// then rests purely on cell ids.
fn idOwner(edge_id: u32) ink.Owner {
    const far: sketch.Point = .{ .x = -100, .y = -100 };
    return .{ .edge_id = edge_id, .polyline = &.{}, .seg_a = far, .seg_b = far };
}

test "classifyAt: cell edge ids resolve own vs foreign; solids and labels classify apart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lat = try makeLattice(arena.allocator(), 8, 4);

    stampEdge(&lat, 1, 1, 42);
    stampEdge(&lat, 2, 1, 7);
    lat.at(3, 1).* = .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 42 } }, .neighbours = .{} };
    lat.at(4, 1).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_n } }, .neighbours = .{} };
    lat.at(5, 1).* = .{ .occupant = .{ .label_char = 'Q' }, .neighbours = .{} };

    try testing.expectEqual(ink.InkClass.own, ink.classifyAt(&lat, idOwner(42), 1, 1));
    try testing.expectEqual(ink.InkClass.foreign_edge, ink.classifyAt(&lat, idOwner(42), 2, 1));
    try testing.expectEqual(ink.InkClass.own, ink.classifyAt(&lat, idOwner(42), 3, 1));
    try testing.expectEqual(ink.InkClass.foreign_solid, ink.classifyAt(&lat, idOwner(42), 4, 1));
    try testing.expectEqual(ink.InkClass.none, ink.classifyAt(&lat, idOwner(42), 5, 1));
    try testing.expectEqual(ink.InkClass.none, ink.classifyAt(&lat, idOwner(42), 0, 0));
    try testing.expectEqual(ink.InkClass.none, ink.classifyAt(&lat, idOwner(42), -1, 2));
}

test "classifyAt: an aux record never confers ink ownership (placement is aux-blind)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lat = try makeLattice(arena.allocator(), 8, 4);

    stampEdge(&lat, 4, 2, 7);
    const records = [_]lattice.Aux{
        .{ .cell = lat.cellIndex(4, 2), .value = 42, .kind = .carrier, .detail = @intFromEnum(lattice.CarrierKind.suppressed) },
    };
    lat.aux = &records;
    try testing.expectEqual(ink.InkClass.foreign_edge, ink.classifyAt(&lat, idOwner(42), 4, 2));
}

test "spanIsolated: foreign ink inside the margin rejects, own ink is exempt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lat = try makeLattice(arena.allocator(), 10, 5);

    stampEdge(&lat, 3, 3, 42);
    stampEdge(&lat, 4, 3, 42);
    stampEdge(&lat, 5, 3, 42);
    try testing.expect(ink.spanIsolated(&lat, idOwner(42), 3, 2, 3, false));

    stampEdge(&lat, 6, 1, 7);
    try testing.expect(!ink.spanIsolated(&lat, idOwner(42), 3, 2, 3, false));
    try testing.expect(!ink.spanIsolated(&lat, idOwner(7), 3, 2, 3, false));
}

test "spanIsolated: same-row label runs need two blank cells, other rows are free" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lat = try makeLattice(arena.allocator(), 12, 5);

    lat.at(2, 2).* = .{ .occupant = .{ .label_char = 'Q' }, .neighbours = .{} };
    try testing.expect(!ink.spanIsolated(&lat, idOwner(42), 3, 2, 2, false));
    try testing.expect(!ink.spanIsolated(&lat, idOwner(42), 4, 2, 2, false));
    try testing.expect(ink.spanIsolated(&lat, idOwner(42), 5, 2, 2, false));
    try testing.expect(ink.spanIsolated(&lat, idOwner(42), 2, 3, 2, false));
}

test "inkDistances: nearest own and nearest foreign edge measured in Chebyshev rings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lat = try makeLattice(arena.allocator(), 12, 8);

    stampEdge(&lat, 7, 4, 42);
    stampEdge(&lat, 1, 3, 7);
    lat.at(4, 1).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };

    const d = ink.inkDistances(&lat, idOwner(42), 4, 3, 2, 4);
    try testing.expectEqual(@as(?u32, 2), d.own);
    try testing.expectEqual(@as(?u32, 3), d.foreign_edge);

    const near = ink.inkDistances(&lat, idOwner(42), 4, 3, 2, 1);
    try testing.expectEqual(@as(?u32, null), near.own);
    try testing.expectEqual(@as(?u32, null), near.foreign_edge);
}

test "ink on the owner's own routed geometry counts as own even when the cell names another rider" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lat = try makeLattice(arena.allocator(), 10, 5);

    stampEdge(&lat, 4, 2, 7);
    const poly = [_]sketch.Point{ .{ .x = 2, .y = 2 }, .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 4 } };
    const owner: ink.Owner = .{ .edge_id = 42, .polyline = &poly, .seg_a = poly[0], .seg_b = poly[1] };

    try testing.expectEqual(ink.InkClass.own, ink.classifyAt(&lat, owner, 4, 2));
    stampEdge(&lat, 1, 4, 7);
    try testing.expectEqual(ink.InkClass.foreign_edge, ink.classifyAt(&lat, owner, 1, 4));
}
