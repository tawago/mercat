//! Unit tests for `tiling/rings.zig`: the outline stencil, the legal
//! populations that shadow a ring cell, and the off-ring fusion ladder —
//! including its order, which is load-bearing.

const std = @import("std");
const lattice = @import("../lattice.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");
const rings = @import("rings.zig");

const testing = std.testing;

const Grid = struct {
    buf: [25]lattice.Cell = undefined,

    fn init(self: *Grid) void {
        for (&self.buf) |*c| c.* = lattice.Cell.empty;
    }

    fn lat(self: *Grid) lattice.Lattice {
        return .{ .width = 5, .height = 5, .cells = &self.buf };
    }

    fn set(self: *Grid, x: usize, y: usize, c: lattice.Cell) void {
        self.buf[y * 5 + x] = c;
    }
};

fn border(node: u32, role: lattice.BorderRole, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .node_border = .{ .node = node, .role = role } }, .neighbours = nb };
}

fn frame(id: u32, role: lattice.BorderRole, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .cluster_border = .{ .cluster = id, .role = role } }, .neighbours = nb };
}

fn edgeCell(id: u32, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = id, .kind = .solid } }, .neighbours = nb };
}

/// Lay a closed 3x3 node ring with its NW corner at (0,0).
fn nodeRing(g: *Grid, node: u32) void {
    g.set(0, 0, border(node, .corner_nw, .{ .e = true, .s = true }));
    g.set(1, 0, border(node, .edge_n, .{ .e = true, .w = true }));
    g.set(2, 0, border(node, .corner_ne, .{ .w = true, .s = true }));
    g.set(0, 1, border(node, .edge_w, .{ .n = true, .s = true }));
    g.set(2, 1, border(node, .edge_e, .{ .n = true, .s = true }));
    g.set(0, 2, border(node, .corner_sw, .{ .e = true, .n = true }));
    g.set(1, 2, border(node, .edge_s, .{ .e = true, .w = true }));
    g.set(2, 2, border(node, .corner_se, .{ .w = true, .n = true }));
    g.set(1, 1, .{ .occupant = .{ .node_interior = node }, .neighbours = .{} });
}

fn scanAll(lat: *const lattice.Lattice, mode_cross: bool) counts.Counts {
    const v = cell.View.init(lat);
    var c: counts.Counts = .{};
    var y: u32 = 0;
    while (y < v.height()) : (y += 1) {
        var x: u32 = 0;
        while (x < v.width()) : (x += 1) {
            const t = v.at(x, y).?;
            if (t.kind == .ring_node or t.kind == .ring_frame) rings.check(v, x, y, t, mode_cross, &c);
        }
    }
    return c;
}

fn one(lat: *const lattice.Lattice, x: u32, y: u32, mode_cross: bool) counts.Counts {
    const v = cell.View.init(lat);
    var c: counts.Counts = .{};
    rings.check(v, x, y, v.at(x, y).?, mode_cross, &c);
    return c;
}

test "stencil: a closed node ring reports no break at all" {
    var g: Grid = .{};
    g.init();
    nodeRing(&g, 3);
    const lat = g.lat();
    const c = scanAll(&lat, false);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try testing.expectEqual(@as(u32, 0), c.c_ring_node_thin);
}

test "stencil: a missing ring cell is a break, and who took it decides the bucket" {
    var g: Grid = .{};
    g.init();
    nodeRing(&g, 3);

    // Blank it out: the outline is genuinely broken from both sides.
    g.set(1, 0, lattice.Cell.empty);
    var lat = g.lat();
    var c = scanAll(&lat, false);
    try testing.expectEqual(@as(u32, 2), c.d_ring_node_break);

    // A cluster frame got there first: the border write legally skipped it.
    g.set(1, 0, frame(0, .edge_n, .{ .e = true, .w = true }));
    lat = g.lat();
    c = scanAll(&lat, false);
    try testing.expectEqual(@as(u32, 0), c.d_ring_node_break);
    try testing.expectEqual(@as(u32, 2), c.c_ring_node_shadowed);

    // A title band overwrote it.
    g.set(1, 0, .{ .occupant = .{ .label_char = 'S' }, .neighbours = .{} });
    lat = g.lat();
    c = scanAll(&lat, false);
    try testing.expectEqual(@as(u32, 2), c.c_ring_node_label);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "stencil: another node's ring cell is shadowing, not a break" {
    var g: Grid = .{};
    g.init();
    nodeRing(&g, 3);
    g.set(1, 0, border(9, .edge_n, .{ .e = true, .w = true }));
    const lat = g.lat();
    const c = scanAll(&lat, false);
    // Four sightings: node 3's two corners look at the intruder, and the
    // intruder looks back at both of them.
    try testing.expectEqual(@as(u32, 4), c.c_ring_node_shadowed);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "stencil: the degenerate-node signature gates the whole stencil" {
    // A 1xN node collapses its corners to a single arm; without the gate
    // that missing second axis would read as a break.
    var g: Grid = .{};
    g.init();
    g.set(0, 0, border(3, .corner_nw, .{ .e = true }));
    g.set(1, 0, border(3, .edge_n, .{ .e = true, .w = true }));
    g.set(2, 0, border(3, .corner_ne, .{ .w = true }));
    const lat = g.lat();
    const c = scanAll(&lat, false);
    try testing.expectEqual(@as(u32, 2), c.c_ring_node_thin);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "stencil: a frame arm on a title glyph, on edge ink, and on nothing" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, frame(0, .edge_n, .{ .e = true, .w = true }));

    // Nothing either side: a broken frame, twice.
    var lat = g.lat();
    try testing.expectEqual(@as(u32, 2), one(&lat, 1, 1, false).d_ring_frame_break);

    // The title band stamps every cell of its span, spaces included.
    g.set(0, 1, .{ .occupant = .{ .label_char = ' ' }, .neighbours = .{} });
    // A terminal arrival replaced the cell on the other side.
    g.set(2, 1, edgeCell(4, .{ .e = true, .w = true }));
    lat = g.lat();
    const c = one(&lat, 1, 1, false);
    try testing.expectEqual(@as(u32, 1), c.c_ring_frame_title);
    try testing.expectEqual(@as(u32, 1), c.c_ring_frame_terminal);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "stencil: an inner frame overwriting an outer one is shadowing" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, frame(0, .edge_n, .{ .e = true, .w = true }));
    g.set(0, 1, frame(0, .corner_nw, .{ .e = true, .s = true }));
    g.set(2, 1, frame(1, .edge_n, .{ .e = true, .w = true }));
    const lat = g.lat();
    const c = one(&lat, 1, 1, false);
    try testing.expectEqual(@as(u32, 1), c.c_ring_frame_shadowed);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "fusion: a weld-explained east arm is claimed before the axis buckets" {
    // The arrowhead-base weld ORs an arm into a node border for ANY tip,
    // east and west included. If the axis buckets ran first this would be
    // filed as a defect on every horizontal arrival.
    var g: Grid = .{};
    g.init();
    g.set(1, 1, border(3, .edge_e, .{ .n = true, .s = true, .e = true }));
    g.set(1, 0, border(3, .corner_ne, .{ .w = true, .s = true }));
    g.set(1, 2, border(3, .corner_se, .{ .w = true, .n = true }));
    g.set(2, 1, .{ .occupant = .{ .arrowhead = .{ .dir = .east, .edge = 5 } }, .neighbours = .{ .e = true, .w = true } });
    var lat = g.lat();
    var c = one(&lat, 1, 1, false);
    try testing.expectEqual(@as(u32, 1), c.c_border_arm_weld);
    try testing.expectEqual(@as(u32, 0), c.d_border_arm_unrecorded);

    // The same arm with an arrowhead pointing the other way is NOT a weld
    // (its base lies elsewhere), so it falls through to the record bucket
    // — and with no `.port` record, it is unexplained.
    g.set(2, 1, .{ .occupant = .{ .arrowhead = .{ .dir = .west, .edge = 5 } }, .neighbours = .{ .e = true, .w = true } });
    lat = g.lat();
    c = one(&lat, 1, 1, false);
    try testing.expectEqual(@as(u32, 0), c.c_border_arm_weld);
    try testing.expectEqual(@as(u32, 1), c.d_border_arm_unrecorded);
}

test "fusion: an off-axis arm into the same node's own border is wall structure" {
    // The subroutine double wall: a top-border cell carries a south arm
    // down into the node's own inner-wall border cell. No record, no weld
    // — but the arm lands on the same node's ring, so it is synthesized
    // structure, not an unexplained attachment. A DIFFERENT node's ring
    // does not qualify.
    var g: Grid = .{};
    g.init();
    g.set(1, 1, border(3, .edge_n, .{ .e = true, .w = true, .s = true }));
    g.set(0, 1, border(3, .corner_nw, .{ .e = true, .s = true }));
    g.set(2, 1, border(3, .corner_ne, .{ .w = true, .s = true }));
    g.set(1, 2, border(3, .edge_w, .{ .n = true, .s = true }));
    var lat = g.lat();
    var c = one(&lat, 1, 1, false);
    try testing.expectEqual(@as(u32, 1), c.c_border_arm_wall);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    // Same geometry, foreign node below: falls through to the record
    // ladder and, unrecorded, is a defect.
    g.set(1, 2, border(4, .edge_w, .{ .n = true, .s = true }));
    lat = g.lat();
    c = one(&lat, 1, 1, false);
    try testing.expectEqual(@as(u32, 0), c.c_border_arm_wall);
    try testing.expectEqual(@as(u32, 1), c.d_border_arm_unrecorded);
}

test "fusion: a port-recorded arm is the convention on every face; unrecorded is a defect" {
    var g: Grid = .{};
    g.init();
    // A south edge cell with an extra south arm and its `.port` record: a
    // recorded vertical departure.
    g.set(1, 1, border(3, .edge_s, .{ .e = true, .w = true, .s = true }));
    g.set(0, 1, border(3, .corner_sw, .{ .e = true, .n = true }));
    g.set(2, 1, border(3, .corner_se, .{ .w = true, .n = true }));
    g.set(1, 2, edgeCell(5, .{ .n = true, .s = true }));
    var lat = g.lat();
    const port_rec_s = [_]lattice.Aux{.{ .cell = 1 * 5 + 1, .value = 5, .kind = .port, .detail = lattice.portArmDetail(.south) }};
    lat.aux = &port_rec_s;
    var c = one(&lat, 1, 1, false);
    try testing.expectEqual(@as(u32, 1), c.c_border_arm_port);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    // An EAST arm with its record — uniform port erasure writes E/W arms
    // too (LR/RL departures and arrivals) — is the same convention.
    g.set(1, 1, border(3, .edge_w, .{ .n = true, .s = true, .e = true }));
    g.set(1, 0, border(3, .corner_nw, .{ .e = true, .s = true }));
    g.set(1, 2, border(3, .corner_sw, .{ .e = true, .n = true }));
    g.set(2, 1, edgeCell(5, .{ .e = true, .w = true }));
    lat = g.lat();
    const port_rec_e = [_]lattice.Aux{.{ .cell = 1 * 5 + 1, .value = 5, .kind = .port, .detail = lattice.portArmDetail(.east) }};
    lat.aux = &port_rec_e;
    c = one(&lat, 1, 1, false);
    try testing.expectEqual(@as(u32, 1), c.c_border_arm_port);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    // The same arm with the side table empty: no writer on record.
    lat = g.lat();
    c = one(&lat, 1, 1, false);
    try testing.expectEqual(@as(u32, 0), c.c_border_arm_port);
    try testing.expectEqual(@as(u32, 1), c.d_border_arm_unrecorded);
}

test "fusion: a port record excuses only the arm it merged" {
    // A south-border cell with an extra SOUTH arm, but the cell's only
    // `.port` record names an EAST stroke: the record is evidence for a
    // different arm, so the south arm stays an unexplained defect. A
    // direction-blind check would have laundered it.
    var g: Grid = .{};
    g.init();
    g.set(1, 1, border(3, .edge_s, .{ .e = true, .w = true, .s = true }));
    g.set(0, 1, border(3, .corner_sw, .{ .e = true, .n = true }));
    g.set(2, 1, border(3, .corner_se, .{ .w = true, .n = true }));
    g.set(1, 2, edgeCell(5, .{ .n = true, .s = true }));
    var lat = g.lat();
    const east_rec = [_]lattice.Aux{.{ .cell = 1 * 5 + 1, .value = 5, .kind = .port, .detail = lattice.portArmDetail(.east) }};
    lat.aux = &east_rec;
    const c = one(&lat, 1, 1, false);
    try testing.expectEqual(@as(u32, 0), c.c_border_arm_port);
    try testing.expectEqual(@as(u32, 1), c.d_border_arm_unrecorded);
}

test "fusion: a frame's extra arm is a convention under cross and a leak under bridge" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, frame(0, .edge_n, .{ .e = true, .w = true, .s = true }));
    g.set(0, 1, frame(0, .corner_nw, .{ .e = true, .s = true }));
    g.set(2, 1, frame(0, .corner_ne, .{ .w = true, .s = true }));
    g.set(1, 2, edgeCell(5, .{ .n = true, .s = true }));
    const lat = g.lat();

    const bridged = one(&lat, 1, 1, false);
    try testing.expectEqual(@as(u32, 1), bridged.d_frame_arm_foreign);

    const crossed = one(&lat, 1, 1, true);
    try testing.expectEqual(@as(u32, 1), crossed.c_frame_arm_cross_mode);
    try testing.expectEqual(@as(u32, 0), crossed.defectTotal());
}
