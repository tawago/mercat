const std = @import("std");
const lattice = @import("../lattice.zig");
const ink = @import("labels_ink.zig");

const testing = std.testing;

fn makeLattice(alloc: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try alloc.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn stamp(lat: *lattice.Lattice, x: u32, y: u32, edge_id: u32, role: lattice.EdgeRole, cohabit: lattice.Cohabit, mask: lattice.Neighbours) void {
    lat.at(x, y).* = .{
        .occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = .solid, .role = role, .cohabit = cohabit } },
        .neighbours = mask,
    };
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
