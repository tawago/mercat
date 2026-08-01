//! Tests for `fan_roles.zig` — the producer-derived fan role stamp
//! (`markShared`, at write time) and the fan-OUT mask resolve
//! (`resolveMasks`, from the Sketch's pivot geometry). Discovered via
//! fan_roles.zig's top-level `test { _ = @import("fan_roles_test.zig"); }`
//! block, per the mermaid_v2/ test-file convention.
//!
//! All fixtures are hand-built lattices + Sketches (shape-generic — no seed
//! names). Bit layout: N=0, E=1, S=2, W=3 (see `lattice.Neighbours`). The
//! full `┼` is N+E+S+W = 0b1111; `┴` is N+E+W = 0b1011; `┬` is E+S+W =
//! 0b1110.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const fan_roles = @import("fan_roles.zig");

const testing = std.testing;

const all4: lattice.Neighbours = .{ .n = true, .e = true, .s = true, .w = true };

fn fanCell(edge: u32, role: lattice.EdgeRole, nb: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .edge_segment = .{ .edge = edge, .kind = .solid, .role = role } },
        .neighbours = nb,
    };
}

fn arrowSouth(edge: u32) lattice.Cell {
    return .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = edge } }, .neighbours = .{} };
}

/// A 3-wide, 5-tall grid; every cell empty.
fn blank(buf: []lattice.Cell) lattice.Lattice {
    for (buf) |*c| c.* = lattice.Cell.empty;
    return .{ .width = 3, .height = 5, .cells = buf };
}

/// A Sketch holding one placed pivot node (id 5) and one fan-OUT member
/// edge (id 0) departing it, plus whatever rails the caller supplies.
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
        .busbars = rails,
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

// ---------------------------------------------------------------------
// ROLE — the write-time stamp. A shared run is "a second member of this
// fan rode this cell", the very event that files the `.rail_member`
// record; nothing about the finished grid enters the decision.
// ---------------------------------------------------------------------
test "a second rider stamps the family rail role; a lone rider leaves the dropper" {
    var cell = fanCell(7, .fan_out_dropper, all4);

    // The cell's own edge arriving again is not a second rider.
    fan_roles.markShared(.{}, &cell, 1, 1, 7, .fan_out_dropper);
    try testing.expectEqual(lattice.EdgeRole.fan_out_dropper, cell.occupant.edge_segment.role);

    // A sibling of the same fan is: the cell IS the shared run.
    fan_roles.markShared(.{}, &cell, 1, 1, 8, .fan_out_dropper);
    try testing.expectEqual(lattice.EdgeRole.fan_out_rail, cell.occupant.edge_segment.role);
    // The first writer keeps the cell's identity — only the role moves.
    try testing.expectEqual(@as(u32, 7), cell.occupant.edge_segment.edge);
}

test "a rider of another family, or of no fan at all, stamps nothing" {
    // A fan-IN member landing on fan-OUT ink names no shared run of either
    // family: the two answers would contradict on one cell.
    var mixed = fanCell(7, .fan_out_dropper, all4);
    fan_roles.markShared(.{}, &mixed, 1, 1, 8, .fan_in_dropper);
    try testing.expectEqual(lattice.EdgeRole.fan_out_dropper, mixed.occupant.edge_segment.role);

    // An ordinary edge crossing fan ink is not a member of anything.
    var plain = fanCell(7, .fan_out_dropper, all4);
    fan_roles.markShared(.{}, &plain, 1, 1, 8, .forward);
    try testing.expectEqual(lattice.EdgeRole.fan_out_dropper, plain.occupant.edge_segment.role);

    // An arrowhead carries no role, so there is nothing a rail role could
    // describe there — the record is the whole of what can be said.
    var head = arrowSouth(7);
    fan_roles.markShared(.{}, &head, 1, 1, 8, .fan_out_dropper);
    try testing.expectEqual(std.meta.Tag(lattice.Occupant).arrowhead, std.meta.activeTag(head.occupant));
}

// ---------------------------------------------------------------------
// MASK — the fan-OUT strip, decided by where the Sketch places the PIVOT.
// ---------------------------------------------------------------------
test "a shared run below its pivot keeps N and drops the child's descent" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.at(1, 1).* = .{ .occupant = .{ .node_border = .{ .node = 5, .role = .edge_s } }, .neighbours = .{ .s = true } };
    lat.at(1, 2).* = fanCell(0, .fan_out_rail, all4);
    lat.at(1, 3).* = arrowSouth(0);

    const nodes = pivotAt(0, 2); // rows 0..1, so row 2 is below it
    const edges = memberEdge(.fan_out_dropper);
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &edges, &.{}));

    try testing.expectEqual(@as(u4, 0b1011), lat.atConst(1, 2).neighbours.toMask()); // ┴
}

test "a shared run above its pivot keeps S" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.at(1, 2).* = fanCell(0, .fan_out_rail, all4);

    const nodes = pivotAt(4, 1); // row 4, so the pivot is BELOW row 2
    const edges = memberEdge(.fan_out_dropper);
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &edges, &.{}));

    try testing.expectEqual(@as(u4, 0b1110), lat.atConst(1, 2).neighbours.toMask()); // ┬
}

test "a grid trunk keeps the rail-to-rail vertical (┼ over ┼)" {
    // A grid-wrapped (rows > 1) fan threads its trunk THROUGH a second rail
    // row: the arm joining row K to row K+1 is a real continuation, and
    // severing it would orphan the lower half of the fan from the pivot.
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

test "fan-IN shared runs keep all four arms" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    lat.at(1, 2).* = fanCell(0, .fan_in_rail, all4);

    const nodes = pivotAt(0, 2);
    var edges = memberEdge(.fan_in_dropper);
    edges[0].to = 5;
    fan_roles.resolveMasks(&lat, fanSketch(&nodes, &edges, &.{}));

    try testing.expectEqual(@as(u4, 0b1111), lat.atConst(1, 2).neighbours.toMask());
}

test "a first-class rail's own geometry is left to the bus-bar rasterizer" {
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
    // Three ways the derivation can come up empty — no fan geometry for the
    // cell's edge, no placement for the pivot, and a pivot whose own rows
    // include this row. Each must pass the cell through untouched rather
    // than guess which arm is spurious.
    var buf: [15]lattice.Cell = undefined;

    var no_edge = blank(&buf);
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
    const tall = pivotAt(0, 5); // rows 0..4 include row 2: neither arm faces it
    fan_roles.resolveMasks(&straddles, fanSketch(&tall, &edges, &.{}));
    try testing.expectEqual(@as(u4, 0b1111), straddles.atConst(1, 2).neighbours.toMask());
}

test "a dropper, a lone vertical arm and a bare corner are all out of scope" {
    var buf: [15]lattice.Cell = undefined;
    var lat = blank(&buf);
    // Still a dropper: no second rider was ever seen here.
    lat.at(0, 2).* = fanCell(0, .fan_out_dropper, all4);
    // A rail with one vertical arm: nothing to choose between.
    lat.at(1, 2).* = fanCell(0, .fan_out_rail, .{ .n = true, .e = true, .w = true });
    // A rail with no horizontal arm is a straight shared stem, not a
    // junction — stripping here would sever the trunk.
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
