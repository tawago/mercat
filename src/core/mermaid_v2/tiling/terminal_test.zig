//! Unit tests for `tiling/terminal.zig`: the full bucket cross-product
//! (ring kind x face-vs-corner x bare-vs-arrowhead), the reprieved gap,
//! the ghost exclusion, and the calibration claim that a plain top-down
//! arrival is a convention rather than a defect.

const std = @import("std");
const lattice = @import("../lattice.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");
const terminal = @import("terminal.zig");

const testing = std.testing;

const W = 5;

const Grid = struct {
    buf: [W * W]lattice.Cell = undefined,

    fn init(self: *Grid) void {
        for (&self.buf) |*c| c.* = lattice.Cell.empty;
    }

    fn lat(self: *Grid) lattice.Lattice {
        return .{ .width = W, .height = W, .cells = &self.buf, .aux_collection = .{ .state = .complete } };
    }

    fn set(self: *Grid, x: usize, y: usize, c: lattice.Cell) void {
        self.buf[y * W + x] = c;
    }
};

fn border(role: lattice.BorderRole, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .node_border = .{ .node = 1, .role = role } }, .neighbours = nb };
}

fn frame(role: lattice.BorderRole, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = role } }, .neighbours = nb };
}

fn edgeCell(nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = 7, .kind = .solid } }, .neighbours = nb };
}

fn ghostCell(nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = 7, .kind = .invisible } }, .neighbours = nb };
}

fn arrowCell(dir: lattice.Dir4, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .arrowhead = .{ .dir = dir, .edge = 7 } }, .neighbours = nb };
}

/// Run the terminal law over every cell of `lat`, exactly as `scan.run`'s
/// ownership dispatch does for stroke and arrowhead cells.
fn scanAll(lat: *const lattice.Lattice) counts.Counts {
    const v = cell.View.init(lat);
    var c: counts.Counts = .{};
    var y: u32 = 0;
    while (y < v.height()) : (y += 1) {
        var x: u32 = 0;
        while (x < v.width()) : (x += 1) {
            terminal.check(v, x, y, v.at(x, y).?, &c);
        }
    }
    return c;
}

/// One ink cell at (2,2) meeting one ring cell one step in `d`.
fn pairAt(ink: lattice.Cell, d: lattice.Dir4, ring: lattice.Cell) counts.Counts {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, ink);
    const p = cell.step(2, 2, d, W, W).?;
    g.set(p.x, p.y, ring);
    const lat = g.lat();
    return scanAll(&lat);
}

/// The same pair, with a `.port` record filed on the ring cell — the
/// evidence `drawPortStroke` leaves for a departure stroke it merged.
fn pairAtWithPort(ink: lattice.Cell, d: lattice.Dir4, ring: lattice.Cell) counts.Counts {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, ink);
    const p = cell.step(2, 2, d, W, W).?;
    g.set(p.x, p.y, ring);
    var lat = g.lat();
    const records = [_]lattice.Aux{
        .{ .cell = lat.cellIndex(p.x, p.y), .value = 7, .kind = .port, .detail = lattice.portArmDetail(cell.reverse(d)) },
    };
    lat.aux = &records;
    return scanAll(&lat);
}

test "node face: a bare stroke arriving vertically is a convention" {
    const c = pairAt(edgeCell(.{ .n = true, .s = true }), .south, border(.edge_n, .{ .e = true, .w = true }));
    try testing.expectEqual(@as(u32, 1), c.n_term_abut);
    try testing.expectEqual(@as(u32, 1), c.c_term_node_ns_bare);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "node face: a bare stroke arriving horizontally is a convention" {
    const c = pairAt(edgeCell(.{ .e = true, .w = true }), .east, border(.edge_w, .{ .n = true, .s = true }));
    try testing.expectEqual(@as(u32, 1), c.n_term_abut);
    try testing.expectEqual(@as(u32, 1), c.c_term_node_ew_bare);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "node face: an arrowhead tip on a horizontal face is a convention" {
    const c = pairAt(arrowCell(.south, .{ .n = true }), .south, border(.edge_n, .{ .e = true, .w = true }));
    try testing.expectEqual(@as(u32, 1), c.n_term_abut);
    try testing.expectEqual(@as(u32, 1), c.c_term_node_ns_arrow);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "node face: an arrowhead tip on a vertical face is a convention" {
    const c = pairAt(arrowCell(.east, .{ .w = true }), .east, border(.edge_w, .{ .n = true, .s = true }));
    try testing.expectEqual(@as(u32, 1), c.n_term_abut);
    try testing.expectEqual(@as(u32, 1), c.c_term_node_ew_arrow);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "node corner: ink landing on a corner is a defect for stroke and arrowhead alike" {
    const bare = pairAt(edgeCell(.{ .n = true, .s = true }), .south, border(.corner_nw, .{ .e = true, .s = true }));
    try testing.expectEqual(@as(u32, 1), bare.d_term_node_corner);
    try testing.expectEqual(@as(u32, 1), bare.defectTotal());

    const tipped = pairAt(arrowCell(.south, .{ .n = true }), .south, border(.corner_ne, .{ .w = true, .s = true }));
    try testing.expectEqual(@as(u32, 1), tipped.d_term_node_corner);
    try testing.expectEqual(@as(u32, 1), tipped.defectTotal());
}

test "frame: a bare stroke against a face or a corner is frame-solid" {
    const face = pairAt(edgeCell(.{ .n = true, .s = true }), .south, frame(.edge_n, .{ .e = true, .w = true }));
    try testing.expectEqual(@as(u32, 1), face.c_term_frame_bare);
    try testing.expectEqual(@as(u32, 0), face.defectTotal());

    const corner = pairAt(edgeCell(.{ .n = true, .s = true }), .south, frame(.corner_nw, .{ .e = true, .s = true }));
    try testing.expectEqual(@as(u32, 1), corner.c_term_frame_corner);
    try testing.expectEqual(@as(u32, 0), corner.defectTotal());
}

test "frame: an arrowhead still abutting untouched frame stopped short" {
    for ([_]lattice.BorderRole{ .edge_n, .corner_nw }) |role| {
        const c = pairAt(arrowCell(.south, .{ .n = true }), .south, frame(role, .{ .e = true, .w = true }));
        try testing.expectEqual(@as(u32, 1), c.n_term_abut);
        try testing.expectEqual(@as(u32, 1), c.d_term_frame_arrow);
        try testing.expectEqual(@as(u32, 1), c.defectTotal());
    }
}

test "a port record claims the pair before any face verdict" {
    const c = pairAtWithPort(edgeCell(.{ .n = true, .s = true }), .north, border(.edge_s, .{ .e = true, .w = true, .s = true }));
    try testing.expectEqual(@as(u32, 1), c.n_term_abut);
    try testing.expectEqual(@as(u32, 1), c.c_term_port_recorded);
    try testing.expectEqual(@as(u32, 0), c.c_term_ring_arm_unrecorded);
    try testing.expectEqual(@as(u32, 0), c.c_term_node_ns_bare);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "an unrecorded ring arm is neither a departure nor a face verdict" {
    const c = pairAt(edgeCell(.{ .n = true, .s = true }), .north, border(.edge_s, .{ .e = true, .w = true, .s = true }));
    try testing.expectEqual(@as(u32, 1), c.n_term_abut);
    try testing.expectEqual(@as(u32, 0), c.c_term_port_recorded);
    try testing.expectEqual(@as(u32, 1), c.c_term_ring_arm_unrecorded);
    try testing.expectEqual(@as(u32, 0), c.c_term_node_ns_bare);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "a port record on a ring the pair never reaches changes nothing" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(.{ .n = true, .s = true }));
    g.set(2, 3, border(.edge_n, .{ .e = true, .w = true }));
    var lat = g.lat();
    const records = [_]lattice.Aux{
        .{ .cell = lat.cellIndex(0, 0), .value = 7, .kind = .port },
    };
    lat.aux = &records;
    const c = scanAll(&lat);
    try testing.expectEqual(@as(u32, 1), c.n_term_abut);
    try testing.expectEqual(@as(u32, 0), c.c_term_port_recorded);
    try testing.expectEqual(@as(u32, 1), c.c_term_node_ns_bare);
}

test "gap: a ring one cell beyond a reprieved blank is a pair with no face verdict" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(.{ .n = true, .s = true }));
    g.set(2, 4, border(.edge_n, .{ .e = true, .w = true, .n = true }));
    const lat = g.lat();
    const c = scanAll(&lat);
    try testing.expectEqual(@as(u32, 1), c.n_term_abut);
    try testing.expectEqual(@as(u32, 1), c.c_term_gap_reprieved);
    try testing.expectEqual(@as(u32, 0), c.c_term_node_ns_bare);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "gap: an unreprieved blank is no pair at all - that arm is the stroke family's" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(.{ .n = true, .s = true }));
    g.set(2, 4, border(.edge_n, .{ .e = true, .w = true }));
    const lat = g.lat();
    const c = scanAll(&lat);
    try testing.expectEqual(@as(u32, 0), c.n_term_abut);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "ghost: an invisible edge starts no pair and ends none" {
    var g: Grid = .{};
    g.init();
    g.set(2, 1, border(.edge_s, .{ .e = true, .w = true }));
    g.set(2, 2, ghostCell(.{ .n = true, .s = true }));
    g.set(2, 3, border(.edge_n, .{ .e = true, .w = true }));
    const lat = g.lat();
    const c = scanAll(&lat);
    try testing.expectEqual(@as(u32, 0), c.n_term_abut);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    g.set(2, 2, edgeCell(.{ .n = true, .s = true }));
    const visible = scanAll(&lat);
    try testing.expectEqual(@as(u32, 2), visible.n_term_abut);
}

test "ownership: only arms the mask actually claims produce pairs" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(.{ .n = true, .s = true }));
    g.set(2, 1, border(.edge_s, .{ .e = true, .w = true }));
    g.set(2, 3, border(.edge_n, .{ .e = true, .w = true }));
    g.set(1, 2, border(.edge_e, .{ .n = true, .s = true }));
    g.set(3, 2, border(.edge_w, .{ .n = true, .s = true }));
    const lat = g.lat();
    const c = scanAll(&lat);
    try testing.expectEqual(@as(u32, 2), c.n_term_abut);
    try testing.expectEqual(@as(u32, 2), c.c_term_node_ns_bare);
    try testing.expectEqual(@as(u32, 0), c.c_term_node_ew_bare);
}

test "ownership: an arrowhead contributes its TIP direction only" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, arrowCell(.south, .{ .n = true, .e = true, .s = true, .w = true }));
    g.set(2, 3, border(.edge_n, .{ .e = true, .w = true }));
    g.set(1, 2, border(.corner_ne, .{ .w = true, .s = true }));
    g.set(3, 2, border(.corner_nw, .{ .e = true, .s = true }));
    const lat = g.lat();
    const c = scanAll(&lat);
    try testing.expectEqual(@as(u32, 1), c.n_term_abut);
    try testing.expectEqual(@as(u32, 1), c.c_term_node_ns_arrow);
    try testing.expectEqual(@as(u32, 0), c.d_term_node_corner);
}

test "a plain TD arrival set contains zero defect buckets" {
    var g: Grid = .{};
    g.init();
    g.set(2, 0, border(.edge_s, .{ .e = true, .w = true, .s = true }));
    g.set(2, 1, edgeCell(.{ .n = true, .s = true }));
    g.set(2, 2, arrowCell(.south, .{ .n = true }));
    g.set(2, 3, border(.edge_n, .{ .e = true, .w = true }));
    var lat = g.lat();
    const records = [_]lattice.Aux{
        .{ .cell = lat.cellIndex(2, 0), .value = 7, .kind = .port, .detail = lattice.portArmDetail(.south) },
    };
    lat.aux = &records;
    const c = scanAll(&lat);
    try testing.expectEqual(@as(u32, 2), c.n_term_abut);
    try testing.expectEqual(@as(u32, 1), c.c_term_port_recorded);
    try testing.expectEqual(@as(u32, 1), c.c_term_node_ns_arrow);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "a tip-facing decorated arrival against a pristine face is a convention with no record" {
    inline for (.{
        .{ lattice.Dir4.south, lattice.BorderRole.edge_n },
        .{ lattice.Dir4.north, lattice.BorderRole.edge_s },
        .{ lattice.Dir4.east, lattice.BorderRole.edge_w },
        .{ lattice.Dir4.west, lattice.BorderRole.edge_e },
    }) |tc| {
        const d = tc[0];
        const role = tc[1];
        const wall: lattice.Neighbours = switch (role) {
            .edge_n, .edge_s => .{ .e = true, .w = true },
            else => .{ .n = true, .s = true },
        };
        const c = pairAt(arrowCell(d, .{}), d, border(role, wall));
        try testing.expectEqual(@as(u32, 1), c.n_term_abut);
        try testing.expectEqual(@as(u32, 0), c.c_term_port_recorded);
        try testing.expectEqual(@as(u32, 0), c.c_term_ring_arm_unrecorded);
        try testing.expectEqual(@as(u32, 0), c.d_border_arm_unrecorded);
        try testing.expectEqual(@as(u32, 0), c.defectTotal());
        switch (role) {
            .edge_n, .edge_s => try testing.expectEqual(@as(u32, 1), c.c_term_node_ns_arrow),
            else => try testing.expectEqual(@as(u32, 1), c.c_term_node_ew_arrow),
        }
    }
}

test "unavailable AUX abstains from terminal defects, not safe face conventions" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(.{ .n = true, .s = true }));
    g.set(2, 3, border(.corner_nw, .{ .e = true, .s = true }));
    var lat = g.lat();

    const complete = scanAll(&lat);
    try testing.expectEqual(@as(u32, 1), complete.d_term_node_corner);
    try testing.expectEqual(@as(u32, 0), complete.u_term_aux_unavailable);

    lat.aux_collection.state = .not_collected;
    const unavailable = scanAll(&lat);
    try testing.expectEqual(@as(u32, 0), unavailable.d_term_node_corner);
    try testing.expectEqual(@as(u32, 1), unavailable.u_term_aux_unavailable);

    lat.aux_collection.state = .out_of_memory;
    const failed = scanAll(&lat);
    try testing.expectEqual(@as(u32, 0), failed.d_term_node_corner);
    try testing.expectEqual(@as(u32, 1), failed.u_term_aux_unavailable);

    g.set(2, 2, arrowCell(.south, .{ .n = true }));
    g.set(2, 3, border(.edge_n, .{ .e = true, .w = true }));
    lat = g.lat();
    lat.aux_collection.state = .not_collected;
    const face = scanAll(&lat);
    try testing.expectEqual(@as(u32, 1), face.c_term_node_ns_arrow);
    try testing.expectEqual(@as(u32, 0), face.u_term_aux_unavailable);
    try testing.expectEqual(@as(u32, 0), face.defectTotal());
}
