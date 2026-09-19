const std = @import("std");
const ledger = @import("../base/ledger.zig");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const fan_roles = @import("fan_roles.zig");

const testing = std.testing;

const all4: lattice.Neighbours = .{ .n = true, .e = true, .s = true, .w = true };

const out_members = [_]ledger.RailClaimMember{
    .{ .edge = 0, .endpoints = .{ 5, 6 }, .sites = .{ .{ .node = 5, .side = .south, .offset = 1 }, .{ .node = 6, .side = .north, .offset = 1 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .source },
    .{ .edge = 1, .endpoints = .{ 5, 7 }, .sites = .{ .{ .node = 5, .side = .south, .offset = 1 }, .{ .node = 7, .side = .north, .offset = 1 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .source },
};
const out_claims = [_]ledger.RailClaim{.{ .id = 1, .polarity = .out, .members = &out_members }};
const in_members = [_]ledger.RailClaimMember{
    .{ .edge = 0, .endpoints = .{ 6, 5 }, .sites = .{ .{ .node = 6, .side = .south, .offset = 1 }, .{ .node = 5, .side = .north, .offset = 1 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .target },
    .{ .edge = 1, .endpoints = .{ 7, 5 }, .sites = .{ .{ .node = 7, .side = .south, .offset = 1 }, .{ .node = 5, .side = .north, .offset = 1 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .target },
};
const in_claims = [_]ledger.RailClaim{.{ .id = 1, .polarity = .in, .members = &in_members }};

fn fanCell(edge: u32, role: lattice.EdgeRole, nb: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .edge_segment = .{ .edge = edge, .kind = .solid, .role = role } },
        .neighbours = nb,
    };
}

fn arrowSouth(edge: u32) lattice.Cell {
    return .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = edge } }, .neighbours = .{} };
}

fn arrowNorth(edge: u32) lattice.Cell {
    return .{ .occupant = .{ .arrowhead = .{ .dir = .north, .edge = edge } }, .neighbours = .{} };
}

fn blank(buf: []lattice.Cell) lattice.Lattice {
    for (buf) |*c| c.* = lattice.Cell.empty;
    return .{ .width = 3, .height = 5, .cells = buf, .rail_claims = &out_claims };
}

fn fanSketch(
    nodes: []const sketch.NodePlacement,
    edges: []const sketch.EdgePath,
    rails: []const sketch.Rail,
) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 3, .h = 5 },
        .direction = .TD,
        .nodes = nodes,
        .clusters = &.{},
        .edges = edges,
        .rails = rails,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn pivotAt(y: i32, h: u32) [1]sketch.NodePlacement {
    return .{.{
        .id = 5,
        .rect = .{ .x = 0, .y = y, .w = 3, .h = h },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    }};
}

var member_poly = [_]sketch.Point{ .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 3 } };

fn memberEdge(role: lattice.EdgeRole) [1]sketch.EdgePath {
    return .{.{
        .id = 0,
        .from = 5,
        .to = 6,
        .polyline = member_poly[0..],
        .port_from = .{ .node = 5, .side = .south, .offset = 0 },
        .port_to = .{ .node = 6, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
        .role = role,
    }};
}

test "a second rider stamps the family rail role; a lone rider leaves the dropper" {
    var cell = fanCell(7, .fan_out_dropper, all4);

    fan_roles.markShared(.{}, &cell, 1, 1, 7, .fan_out_dropper);
    try testing.expectEqual(lattice.EdgeRole.fan_out_dropper, cell.occupant.edge_segment.role);

    fan_roles.markShared(.{}, &cell, 1, 1, 8, .fan_out_dropper);
    try testing.expectEqual(lattice.EdgeRole.fan_out_rail, cell.occupant.edge_segment.role);
    try testing.expectEqual(@as(u32, 7), cell.occupant.edge_segment.edge);
}

test "a rider of another family, or of no fan at all, stamps nothing" {
    var mixed = fanCell(7, .fan_out_dropper, all4);
    fan_roles.markShared(.{}, &mixed, 1, 1, 8, .fan_in_dropper);
    try testing.expectEqual(lattice.EdgeRole.fan_out_dropper, mixed.occupant.edge_segment.role);

    var plain = fanCell(7, .fan_out_dropper, all4);
    fan_roles.markShared(.{}, &plain, 1, 1, 8, .forward);
    try testing.expectEqual(lattice.EdgeRole.fan_out_dropper, plain.occupant.edge_segment.role);

    var head = arrowSouth(7);
    fan_roles.markShared(.{}, &head, 1, 1, 8, .fan_out_dropper);
    try testing.expectEqual(std.meta.Tag(lattice.Occupant).arrowhead, std.meta.activeTag(head.occupant));
}

test "a shared run below its pivot keeps N and drops the child's descent" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.at(1, 1).* = .{ .occupant = .{ .node_border = .{ .node = 5, .role = .edge_s } }, .neighbours = .{ .s = true } };
    lat.at(1, 2).* = fanCell(0, .fan_out_rail, all4);
    lat.at(1, 3).* = fanCell(9, .forward, .{ .e = true, .s = true });

    const nodes = pivotAt(0, 2);
    const edges = memberEdge(.fan_out_dropper);
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &edges, &.{}));

    try testing.expectEqual(@as(u4, 0b1011), lat.atConst(1, 2).neighbours.toMask());
}

test "a shared run above its pivot keeps S" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.at(1, 2).* = fanCell(0, .fan_out_rail, all4);
    lat.at(1, 1).* = fanCell(9, .forward, .{ .n = true, .e = true });

    const nodes = pivotAt(4, 1);
    const edges = memberEdge(.fan_out_dropper);
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &edges, &.{}));

    try testing.expectEqual(@as(u4, 0b1110), lat.atConst(1, 2).neighbours.toMask());
}

test "the arm an arrowhead stands on is never the spurious one" {
    var down: [15]lattice.Cell = undefined;
    var lat_down = blank(&down);
    lat_down.at(1, 1).* = .{ .occupant = .{ .node_border = .{ .node = 5, .role = .edge_s } }, .neighbours = .{ .s = true } };
    lat_down.at(1, 2).* = fanCell(0, .fan_out_rail, all4);
    lat_down.at(1, 3).* = arrowSouth(7);

    const nodes_above = pivotAt(0, 2);
    const edges = memberEdge(.fan_out_dropper);
    fan_roles.resolveMasks(&lat_down, fanSketch(&nodes_above, &edges, &.{}));
    try testing.expectEqual(@as(u4, 0b1111), lat_down.atConst(1, 2).neighbours.toMask());

    var up: [15]lattice.Cell = undefined;
    var lat_up = blank(&up);
    lat_up.at(1, 1).* = arrowNorth(7);
    lat_up.at(1, 2).* = fanCell(0, .fan_out_rail, all4);

    const nodes_below = pivotAt(4, 1);
    fan_roles.resolveMasks(&lat_up, fanSketch(&nodes_below, &edges, &.{}));
    try testing.expectEqual(@as(u4, 0b1111), lat_up.atConst(1, 2).neighbours.toMask());
}

test "an arm a stroke answers back is left for nobody to strip" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.at(1, 1).* = .{ .occupant = .{ .node_border = .{ .node = 5, .role = .edge_s } }, .neighbours = .{ .s = true } };
    lat.at(1, 2).* = fanCell(0, .fan_out_rail, all4);
    lat.at(1, 3).* = fanCell(9, .forward, .{ .n = true, .e = true, .s = true });

    const nodes = pivotAt(0, 2);
    const edges = memberEdge(.fan_out_dropper);
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &edges, &.{}));

    try testing.expectEqual(@as(u4, 0b1111), lat.atConst(1, 2).neighbours.toMask());
}

test "an arrowhead facing away grants no reprieve" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.at(1, 1).* = .{ .occupant = .{ .node_border = .{ .node = 5, .role = .edge_s } }, .neighbours = .{ .s = true } };
    lat.at(1, 2).* = fanCell(0, .fan_out_rail, all4);
    lat.at(1, 3).* = arrowNorth(7);

    const nodes = pivotAt(0, 2);
    const edges = memberEdge(.fan_out_dropper);
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &edges, &.{}));

    try testing.expectEqual(@as(u4, 0b1011), lat.atConst(1, 2).neighbours.toMask());
}

test "under LR/RL the vertical is the rail itself, so nothing is stripped" {
    for ([_]sketch.Direction{ .LR, .RL }) |dir| {
        var buf: [15]lattice.Cell = undefined;
        var lat = blank(&buf);
        lat.at(1, 2).* = fanCell(0, .fan_out_rail, all4);

        const nodes = pivotAt(0, 2);
        const edges = memberEdge(.fan_out_dropper);
        var s = fanSketch(&nodes, &edges, &.{});
        s.direction = dir;
        fan_roles.resolveMasks(&lat, s);

        try testing.expectEqual(@as(u4, 0b1111), lat.atConst(1, 2).neighbours.toMask());
    }
}

test "a grid rail keeps the rail-to-rail vertical (┼ over ┼)" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.at(1, 1).* = fanCell(0, .fan_out_rail, all4);
    lat.at(1, 2).* = fanCell(0, .fan_out_rail, all4);

    const nodes = pivotAt(0, 1);
    const edges = memberEdge(.fan_out_dropper);
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &edges, &.{}));

    try testing.expectEqual(@as(u4, 0b1111), lat.atConst(1, 1).neighbours.toMask());
    try testing.expectEqual(@as(u4, 0b1111), lat.atConst(1, 2).neighbours.toMask());
}

test "a fan-IN rail row one cell away reprieves the fan-OUT junction too" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.at(1, 1).* = fanCell(0, .fan_out_rail, all4);
    lat.at(1, 2).* = fanCell(3, .fan_in_rail, all4);

    const nodes = pivotAt(0, 1);
    const edges = memberEdge(.fan_out_dropper);
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &edges, &.{}));

    try testing.expectEqual(@as(u4, 0b1111), lat.atConst(1, 1).neighbours.toMask());
}

test "fan-IN shared runs keep all four arms" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.rail_claims = &in_claims;
    lat.at(1, 2).* = fanCell(0, .fan_in_rail, all4);

    const nodes = pivotAt(0, 2);
    var edges = memberEdge(.fan_in_dropper);
    edges[0].to = 5;
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &edges, &.{}));

    try testing.expectEqual(@as(u4, 0b1111), lat.atConst(1, 2).neighbours.toMask());
}

test "a first-class rail's own geometry is left to the rail rasterizer" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.at(1, 2).* = fanCell(0, .fan_out_rail, all4);

    var stem = [_]sketch.Point{ .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 } };
    var taps = [_]sketch.Tap{.{ .edge = 0, .node = 6, .at = .{ .x = 1, .y = 2 }, .landing = .{ .x = 1, .y = 4 } }};
    var rails = [_]sketch.Rail{.{
        .pivot = 5,
        .stem = &stem,
        .crossbar = .{ .{ .x = 0, .y = 2 }, .{ .x = 2, .y = 2 } },
        .taps = &taps,
        .kind = .solid,
    }};

    const nodes = pivotAt(0, 1);
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &.{}, &rails));

    try testing.expectEqual(@as(u4, 0b1111), lat.atConst(1, 2).neighbours.toMask());
}

test "an unplaceable pivot leaves the mask exactly as the walk wrote it" {
    var buf: [15]lattice.Cell = undefined;

    var no_edge = blank(&buf);
    no_edge.rail_claims = &.{};
    no_edge.at(1, 2).* = fanCell(0, .fan_out_rail, all4);
    const nodes = pivotAt(0, 2);
    fan_roles.resolveMasks(&no_edge, fanSketch(&nodes, &.{}, &.{}));
    try testing.expectEqual(@as(u4, 0b1111), no_edge.atConst(1, 2).neighbours.toMask());

    var buf2: [15]lattice.Cell = undefined;
    var no_node = blank(&buf2);
    no_node.at(1, 2).* = fanCell(0, .fan_out_rail, all4);
    const edges = memberEdge(.fan_out_dropper);
    fan_roles.resolveMasks(&no_node, fanSketch(&.{}, &edges, &.{}));
    try testing.expectEqual(@as(u4, 0b1111), no_node.atConst(1, 2).neighbours.toMask());

    var buf3: [15]lattice.Cell = undefined;
    var straddles = blank(&buf3);
    straddles.at(1, 2).* = fanCell(0, .fan_out_rail, all4);
    const tall = pivotAt(0, 5);
    fan_roles.resolveMasks(&straddles, fanSketch(&tall, &edges, &.{}));
    try testing.expectEqual(@as(u4, 0b1111), straddles.atConst(1, 2).neighbours.toMask());
}

test "a dropper, a lone vertical arm and a bare corner are all out of scope" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.at(0, 2).* = fanCell(0, .fan_out_dropper, all4);
    lat.at(1, 2).* = fanCell(0, .fan_out_rail, .{ .n = true, .e = true, .w = true });
    lat.at(2, 2).* = fanCell(0, .fan_out_rail, .{ .n = true, .s = true });

    const nodes = pivotAt(0, 2);
    const edges = memberEdge(.fan_out_dropper);
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &edges, &.{}));

    try testing.expectEqual(@as(u4, 0b1111), lat.atConst(0, 2).neighbours.toMask());
    try testing.expectEqual(@as(u4, 0b1011), lat.atConst(1, 2).neighbours.toMask());
    try testing.expectEqual(@as(u4, 0b0101), lat.atConst(2, 2).neighbours.toMask());
}

test "resolveMasks on a zero-sized lattice is a no-op" {
    var lat = lattice.Lattice{ .width = 0, .height = 0, .cells = &[_]lattice.Cell{} };
    fan_roles.resolveMasks(&lat, fanSketch(&.{}, &.{}, &.{}));
    try testing.expectEqual(@as(u32, 0), lat.width);
}
