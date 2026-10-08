const std = @import("std");
const rail_star = @import("../base/rail_star.zig");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const fan_roles = @import("fan_roles.zig");

const testing = std.testing;

const all4: lattice.Neighbours = .{ .n = true, .e = true, .s = true, .w = true };

const out_members = [_]rail_star.RailClaimMember{
    .{ .edge = 0, .endpoints = .{ 5, 6 }, .sites = .{ .{ .node = 5, .side = .south, .offset = 1 }, .{ .node = 6, .side = .north, .offset = 1 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .source },
    .{ .edge = 1, .endpoints = .{ 5, 7 }, .sites = .{ .{ .node = 5, .side = .south, .offset = 1 }, .{ .node = 7, .side = .north, .offset = 1 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .source },
};
const out_claims = [_]rail_star.RailClaim{.{ .id = 1, .polarity = .out, .members = &out_members }};
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
    return .{ .width = 3, .height = 5, .cells = buf };
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
        .sharing = .{ .claims = &out_claims },
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

    fan_roles.markShared(&cell, 7, .fan_out_dropper);
    try testing.expectEqual(lattice.EdgeRole.fan_out_dropper, cell.occupant.edge_segment.role);

    fan_roles.markShared(&cell, 8, .fan_out_dropper);
    try testing.expectEqual(lattice.EdgeRole.fan_out_rail, cell.occupant.edge_segment.role);
    try testing.expectEqual(@as(u32, 7), cell.occupant.edge_segment.edge);
}

test "a rider of another family, or of no fan at all, stamps nothing" {
    var mixed = fanCell(7, .fan_out_dropper, all4);
    fan_roles.markShared(&mixed, 8, .fan_in_dropper);
    try testing.expectEqual(lattice.EdgeRole.fan_out_dropper, mixed.occupant.edge_segment.role);

    var plain = fanCell(7, .fan_out_dropper, all4);
    fan_roles.markShared(&plain, 8, .forward);
    try testing.expectEqual(lattice.EdgeRole.fan_out_dropper, plain.occupant.edge_segment.role);

    var head = arrowSouth(7);
    fan_roles.markShared(&head, 8, .fan_out_dropper);
    try testing.expectEqual(std.meta.Tag(lattice.Occupant).arrowhead, std.meta.activeTag(head.occupant));
}

const Put = struct { x: u32, y: u32, cell: lattice.Cell };
const border_s: lattice.Cell = .{ .occupant = .{ .node_border = .{ .node = 5, .role = .edge_s } }, .neighbours = .{ .s = true } };
const rail_stem = [_]sketch.Point{ .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 } };
const rail_taps = [_]sketch.Tap{.{ .edge = 0, .node = 6, .at = .{ .x = 1, .y = 2 }, .landing = .{ .x = 1, .y = 4 } }};
const own_rail = [_]sketch.Rail{.{ .pivot = 5, .stem = &rail_stem, .crossbar = .{ .{ .x = 0, .y = 2 }, .{ .x = 2, .y = 2 } }, .taps = &rail_taps, .kind = .solid }};

/// One resolveMasks scenario on the 3x5 lattice: the cells the walk wrote, the
/// pivot placement and sketch tweaks, and the mask expected at `at`.
const Case = struct {
    puts: []const Put,
    pivot: ?[2]u32 = .{ 0, 2 }, // y, h
    member: bool = true,
    dir: sketch.Direction = .TD,
    no_claims: bool = false,
    rail: bool = false,
    at: [2]u32 = .{ 1, 2 },
    want: u4,
};

fn runCase(c: Case) !void {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    for (c.puts) |p| lat.at(p.x, p.y).* = p.cell;
    const nodes = if (c.pivot) |pv| pivotAt(@intCast(pv[0]), pv[1]) else pivotAt(0, 1);
    const edges = memberEdge(.fan_out_dropper);
    var s = fanSketch(if (c.pivot != null) &nodes else &.{}, if (c.member) &edges else &.{}, if (c.rail) &own_rail else &.{});
    s.direction = c.dir;
    if (c.no_claims) s.sharing.claims = &.{};
    fan_roles.resolveMasks(&lat, s);
    try testing.expectEqual(c.want, lat.atConst(c.at[0], c.at[1]).neighbours.toMask());
}

test "resolveMasks strips the spurious arm: the child's descent below the pivot, the rise above it, a stroke into an away-facing head" {
    const cases = [_]Case{
        .{ .puts = &.{ .{ .x = 1, .y = 1, .cell = border_s }, .{ .x = 1, .y = 2, .cell = fanCell(0, .fan_out_rail, all4) }, .{ .x = 1, .y = 3, .cell = fanCell(9, .forward, .{ .e = true, .s = true }) } }, .want = 0b1011 },
        .{ .puts = &.{ .{ .x = 1, .y = 2, .cell = fanCell(0, .fan_out_rail, all4) }, .{ .x = 1, .y = 1, .cell = fanCell(9, .forward, .{ .n = true, .e = true }) } }, .pivot = .{ 4, 1 }, .want = 0b1110 },
        .{ .puts = &.{ .{ .x = 1, .y = 1, .cell = border_s }, .{ .x = 1, .y = 2, .cell = fanCell(0, .fan_out_rail, all4) }, .{ .x = 1, .y = 3, .cell = arrowNorth(7) } }, .want = 0b1011 },
        // A lone vertical arm is out of scope, but the tee beside it still loses its descent.
        .{ .puts = &.{.{ .x = 1, .y = 2, .cell = fanCell(0, .fan_out_rail, .{ .n = true, .e = true, .w = true }) }}, .want = 0b1011 },
    };
    for (cases) |c| try runCase(c);
}

test "resolveMasks keeps all four arms: arrowhead footing, answered arm, LR/RL, grid rail, fan-IN neighbour, first-class rail, unplaceable pivot, dropper" {
    const rail4 = fanCell(0, .fan_out_rail, all4);
    const cases = [_]Case{
        // The arm an arrowhead stands on is never the spurious one (below and above).
        .{ .puts = &.{ .{ .x = 1, .y = 1, .cell = border_s }, .{ .x = 1, .y = 2, .cell = rail4 }, .{ .x = 1, .y = 3, .cell = arrowSouth(7) } }, .want = 0b1111 },
        .{ .puts = &.{ .{ .x = 1, .y = 1, .cell = arrowNorth(7) }, .{ .x = 1, .y = 2, .cell = rail4 } }, .pivot = .{ 4, 1 }, .want = 0b1111 },
        // An arm a stroke answers back.
        .{ .puts = &.{ .{ .x = 1, .y = 1, .cell = border_s }, .{ .x = 1, .y = 2, .cell = rail4 }, .{ .x = 1, .y = 3, .cell = fanCell(9, .forward, .{ .n = true, .e = true, .s = true }) } }, .want = 0b1111 },
        // Under LR/RL the vertical is the rail itself.
        .{ .puts = &.{.{ .x = 1, .y = 2, .cell = rail4 }}, .dir = .LR, .want = 0b1111 },
        .{ .puts = &.{.{ .x = 1, .y = 2, .cell = rail4 }}, .dir = .RL, .want = 0b1111 },
        // A grid rail keeps the rail-to-rail vertical (┼ over ┼).
        .{ .puts = &.{ .{ .x = 1, .y = 1, .cell = rail4 }, .{ .x = 1, .y = 2, .cell = rail4 } }, .pivot = .{ 0, 1 }, .at = .{ 1, 1 }, .want = 0b1111 },
        .{ .puts = &.{ .{ .x = 1, .y = 1, .cell = rail4 }, .{ .x = 1, .y = 2, .cell = rail4 } }, .pivot = .{ 0, 1 }, .want = 0b1111 },
        // A fan-IN rail row one cell away reprieves the fan-OUT junction too.
        .{ .puts = &.{ .{ .x = 1, .y = 1, .cell = rail4 }, .{ .x = 1, .y = 2, .cell = fanCell(3, .fan_in_rail, all4) } }, .pivot = .{ 0, 1 }, .at = .{ 1, 1 }, .want = 0b1111 },
        // A first-class rail's own geometry is left to the rail rasterizer.
        .{ .puts = &.{.{ .x = 1, .y = 2, .cell = rail4 }}, .pivot = .{ 0, 1 }, .member = false, .rail = true, .want = 0b1111 },
        // An unplaceable pivot: no claimed edge, no pivot node, a pivot straddling the cell.
        .{ .puts = &.{.{ .x = 1, .y = 2, .cell = rail4 }}, .member = false, .no_claims = true, .want = 0b1111 },
        .{ .puts = &.{.{ .x = 1, .y = 2, .cell = rail4 }}, .pivot = null, .want = 0b1111 },
        .{ .puts = &.{.{ .x = 1, .y = 2, .cell = rail4 }}, .pivot = .{ 0, 5 }, .want = 0b1111 },
        // A dropper and a bare corner are out of scope.
        .{ .puts = &.{.{ .x = 0, .y = 2, .cell = fanCell(0, .fan_out_dropper, all4) }}, .at = .{ 0, 2 }, .want = 0b1111 },
        .{ .puts = &.{.{ .x = 2, .y = 2, .cell = fanCell(0, .fan_out_rail, .{ .n = true, .s = true }) }}, .at = .{ 2, 2 }, .want = 0b0101 },
    };
    for (cases) |c| try runCase(c);
}
