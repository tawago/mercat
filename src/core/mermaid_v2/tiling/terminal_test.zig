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
        return .{ .width = W, .height = W, .cells = &self.buf };
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

// -- Node faces: all four bare/arrow combinations are conventions -------------

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
    // The single most common thing the renderer draws: `A --> B` top-down.
    // Nothing ever writes a reciprocal bit into the TARGET border, so a
    // defect bucket here would fire on every diagram in the corpus.
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

// -- The one node defect: a corner ------------------------------------------

test "node corner: ink landing on a corner is a defect for stroke and arrowhead alike" {
    // Perimeter ports are issued as face offsets only, so nothing the
    // router emits should ever end on a corner cell.
    const bare = pairAt(edgeCell(.{ .n = true, .s = true }), .south, border(.corner_nw, .{ .e = true, .s = true }));
    try testing.expectEqual(@as(u32, 1), bare.d_term_node_corner);
    try testing.expectEqual(@as(u32, 1), bare.defectTotal());

    const tipped = pairAt(arrowCell(.south, .{ .n = true }), .south, border(.corner_ne, .{ .w = true, .s = true }));
    try testing.expectEqual(@as(u32, 1), tipped.d_term_node_corner);
    try testing.expectEqual(@as(u32, 1), tipped.defectTotal());
}

// -- Frames: bare crossings are legal, an arrowhead is not -------------------

test "frame: a bare stroke against a face or a corner is frame-solid" {
    const face = pairAt(edgeCell(.{ .n = true, .s = true }), .south, frame(.edge_n, .{ .e = true, .w = true }));
    try testing.expectEqual(@as(u32, 1), face.c_term_frame_bare);
    try testing.expectEqual(@as(u32, 0), face.defectTotal());

    const corner = pairAt(edgeCell(.{ .n = true, .s = true }), .south, frame(.corner_nw, .{ .e = true, .s = true }));
    try testing.expectEqual(@as(u32, 1), corner.c_term_frame_corner);
    try testing.expectEqual(@as(u32, 0), corner.defectTotal());
}

test "frame: an arrowhead still abutting untouched frame stopped short" {
    // A genuine arrival into a cluster REPLACES the frame cell with the
    // arrowhead, so the pair below cannot be the result of one.
    for ([_]lattice.BorderRole{ .edge_n, .corner_nw }) |role| {
        const c = pairAt(arrowCell(.south, .{ .n = true }), .south, frame(role, .{ .e = true, .w = true }));
        try testing.expectEqual(@as(u32, 1), c.n_term_abut);
        try testing.expectEqual(@as(u32, 1), c.d_term_frame_arrow);
        try testing.expectEqual(@as(u32, 1), c.defectTotal());
    }
}

// -- Reciprocation and the reprieved gap ------------------------------------

test "reciprocated: a source-side departure is claimed before any face verdict" {
    // The border merge stamps the departure bit into the cell the run
    // LEAVES; that bit pointing back is the whole signature.
    const c = pairAt(edgeCell(.{ .n = true, .s = true }), .north, border(.edge_s, .{ .e = true, .w = true, .s = true }));
    try testing.expectEqual(@as(u32, 1), c.n_term_abut);
    try testing.expectEqual(@as(u32, 1), c.c_term_reciprocated);
    try testing.expectEqual(@as(u32, 0), c.c_term_node_ns_bare);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "gap: a ring one cell beyond a reprieved blank is a pair with no face verdict" {
    var g: Grid = .{};
    g.init();
    // (2,2) stroke -> (2,3) blank -> (2,4) ring that reciprocates.
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
    // The ring two cells away does NOT carry the arm back, so the walk is
    // not reprieved: the arm is dangling, which this family never files.
    g.set(2, 2, edgeCell(.{ .n = true, .s = true }));
    g.set(2, 4, border(.edge_n, .{ .e = true, .w = true }));
    const lat = g.lat();
    const c = scanAll(&lat);
    try testing.expectEqual(@as(u32, 0), c.n_term_abut);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

// -- Exclusions --------------------------------------------------------------

test "ghost: an invisible edge starts no pair and ends none" {
    var g: Grid = .{};
    g.init();
    // An invisible segment carrying a full straight mask, sandwiched
    // between two node borders. It occupies its cell and paints nothing,
    // so no terminal law may attach to it.
    g.set(2, 1, border(.edge_s, .{ .e = true, .w = true }));
    g.set(2, 2, ghostCell(.{ .n = true, .s = true }));
    g.set(2, 3, border(.edge_n, .{ .e = true, .w = true }));
    const lat = g.lat();
    const c = scanAll(&lat);
    try testing.expectEqual(@as(u32, 0), c.n_term_abut);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    // The same geometry with a VISIBLE stroke does produce two pairs —
    // proof the fixture above is silenced by the ghost and nothing else.
    g.set(2, 2, edgeCell(.{ .n = true, .s = true }));
    const visible = scanAll(&lat);
    try testing.expectEqual(@as(u32, 2), visible.n_term_abut);
}

test "ownership: only arms the mask actually claims produce pairs" {
    var g: Grid = .{};
    g.init();
    // Rings on all four sides, but the stroke claims only north and south.
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
    // The arrowhead claims all four bits but points south. The lateral
    // bits belong to `arrows.checkLateral` and the base cell to
    // `arrows.checkBase`; this family must claim exactly one of the three
    // rings around it.
    g.set(2, 2, arrowCell(.south, .{ .n = true, .e = true, .s = true, .w = true }));
    g.set(2, 3, border(.edge_n, .{ .e = true, .w = true }));
    g.set(1, 2, border(.corner_ne, .{ .w = true, .s = true }));
    g.set(3, 2, border(.corner_nw, .{ .e = true, .s = true }));
    const lat = g.lat();
    const c = scanAll(&lat);
    try testing.expectEqual(@as(u32, 1), c.n_term_abut);
    try testing.expectEqual(@as(u32, 1), c.c_term_node_ns_arrow);
    // The two corner rings sit on LATERAL bits and must not be filed here.
    try testing.expectEqual(@as(u32, 0), c.d_term_node_corner);
}

test "a plain TD arrival set contains zero defect buckets" {
    // The calibration claim in miniature: source node's bottom face, a
    // one-cell run, an arrowhead on the target's top face. Every pair is a
    // convention; the whole shape is silent.
    var g: Grid = .{};
    g.init();
    g.set(2, 0, border(.edge_s, .{ .e = true, .w = true, .s = true })); // merged departure
    g.set(2, 1, edgeCell(.{ .n = true, .s = true }));
    g.set(2, 2, arrowCell(.south, .{ .n = true }));
    g.set(2, 3, border(.edge_n, .{ .e = true, .w = true }));
    const lat = g.lat();
    const c = scanAll(&lat);
    // Two pairs: the departure off the source face and the arrival on the
    // target face. The stroke's south arm ends on the arrowhead, which is
    // not a ring and so ends no pair.
    try testing.expectEqual(@as(u32, 2), c.n_term_abut);
    try testing.expectEqual(@as(u32, 1), c.c_term_reciprocated);
    try testing.expectEqual(@as(u32, 1), c.c_term_node_ns_arrow);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}
