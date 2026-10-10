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
    stamp(lat, x, y, edge_id, .forward, .alone, .{ .w = true, .e = true });
}

fn stamp(lat: *lattice.Lattice, x: u32, y: u32, edge_id: u32, role: lattice.EdgeRole, cohabit: lattice.Cohabit, mask: lattice.Neighbours) void {
    lat.at(x, y).* = .{
        .occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = .solid, .role = role, .cohabit = cohabit } },
        .neighbours = mask,
    };
}

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

    // Ink on the owner's own routed geometry is own even when the cell names another rider.
    const poly = [_]sketch.Point{ .{ .x = 2, .y = 2 }, .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 3 } };
    const routed: ink.Owner = .{ .edge_id = 42, .polyline = &poly, .seg_a = poly[0], .seg_b = poly[1] };
    stampEdge(&lat, 4, 2, 7);
    try testing.expectEqual(ink.InkClass.own, ink.classifyAt(&lat, routed, 4, 2));
    stampEdge(&lat, 1, 3, 7);
    try testing.expectEqual(ink.InkClass.foreign_edge, ink.classifyAt(&lat, routed, 1, 3));
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

    // The ring is checked in all 8 directions around a one-cell span.
    const dirs = [8][2]i32{ .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } };
    for (dirs) |d| {
        var ring = try makeLattice(arena.allocator(), 10, 5);
        try testing.expect(ink.spanIsolated(&ring, idOwner(42), 5, 2, 1, false));
        stampEdge(&ring, @intCast(5 + d[0]), @intCast(2 + d[1]), 9);
        try testing.expect(!ink.spanIsolated(&ring, idOwner(42), 5, 2, 1, false));
    }
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

test "relationAt: own ink reads by its cohabitation, foreign ink by its line, boxes by the host's ends" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lat = try makeLattice(arena.allocator(), 8, 4);
    const H: lattice.Neighbours = .{ .e = true, .w = true };
    const V: lattice.Neighbours = .{ .n = true, .s = true };

    stamp(&lat, 0, 1, 9, .forward, .alone, H);
    stamp(&lat, 1, 1, 9, .forward, .crossed, H);
    stamp(&lat, 2, 1, 9, .forward, .joined, H);
    stamp(&lat, 3, 1, 9, .fan_out_rail, .alone, H);
    stamp(&lat, 4, 1, 8, .forward, .alone, V);
    stamp(&lat, 5, 1, 8, .forward, .alone, H);
    stamp(&lat, 6, 2, 8, .forward, .alone, V);
    lat.at(7, 1).* = .{ .occupant = .{ .arrowhead = .{ .dir = .east, .edge = 9 } }, .neighbours = .{ .w = true } };
    lat.at(0, 0).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };
    lat.at(1, 0).* = .{ .occupant = .{ .node_interior = 5 }, .neighbours = .{} };
    lat.at(2, 0).* = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } }, .neighbours = .{} };
    lat.at(3, 0).* = .{ .occupant = .{ .label_char = 'Q' }, .neighbours = .{} };

    const h: ink.Host = .{ .edge = 9, .ends = .{ 1, 2 }, .axis = .horizontal, .lo = .{ .x = 0, .y = 1 }, .hi = .{ .x = 7, .y = 1 } };
    try testing.expectEqual(ink.Relation.private, ink.relationAt(&lat, h, 0, 1));
    try testing.expectEqual(ink.Relation.piercing, ink.relationAt(&lat, h, 1, 1));
    try testing.expectEqual(ink.Relation.joined, ink.relationAt(&lat, h, 2, 1));
    try testing.expectEqual(ink.Relation.rail_interior, ink.relationAt(&lat, h, 3, 1));
    try testing.expectEqual(ink.Relation.piercing, ink.relationAt(&lat, h, 4, 1));
    try testing.expectEqual(ink.Relation.foreign_run, ink.relationAt(&lat, h, 5, 1));
    try testing.expectEqual(ink.Relation.foreign_run, ink.relationAt(&lat, h, 6, 2));
    try testing.expectEqual(ink.Relation.decoration, ink.relationAt(&lat, h, 7, 1));
    try testing.expectEqual(ink.Relation.own_box, ink.relationAt(&lat, h, 0, 0));
    try testing.expectEqual(ink.Relation.foreign_box, ink.relationAt(&lat, h, 1, 0));
    try testing.expectEqual(ink.Relation.frame, ink.relationAt(&lat, h, 2, 0));
    try testing.expectEqual(ink.Relation.label, ink.relationAt(&lat, h, 3, 0));
    try testing.expectEqual(ink.Relation.none, ink.relationAt(&lat, h, 4, 0));
    try testing.expectEqual(ink.Relation.none, ink.relationAt(&lat, h, -1, 1));
}
