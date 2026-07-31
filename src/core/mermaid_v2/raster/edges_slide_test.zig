//! Unit tests for THE HEAD SLIDE (`edges_port.slideHead`) and the shape it
//! produces end to end through `edges.rasterizeEdges`.
//!
//! An arrowhead cell is TERMINAL: its base side is fed by its own collinear
//! run and its TIP side must abut the attachment directly. So a decorated
//! end that stops one cell short of the wall (the 1-cell port reprieve)
//! must not paint that gap behind its head — `├─◀` puts run ink on the tip
//! side, which the contract forbids. The head slides FORWARD onto the gap
//! instead, and the cell it vacates keeps the run ink the walk already
//! wrote: `│◀────┐`.
//!
//! Split from `edges_port_test.zig`/`edges_test.zig`, both at the 500-line
//! cap. Imports: `std`, `sketch.zig`, `lattice.zig`, `edges.zig`,
//! `edges_port.zig`.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const edges = @import("edges.zig");
const ep = @import("edges_port.zig");

const testing = std.testing;

fn blank(a: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try a.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn putBorder(lat: *lattice.Lattice, x: u32, y: u32, role: lattice.BorderRole, mask: lattice.Neighbours) void {
    lat.at(x, y).* = .{
        .occupant = .{ .node_border = .{ .node = 0, .role = role } },
        .neighbours = mask,
        .stroke_kind = .solid,
        .shape = .rect,
    };
}

/// The four faces, as (travel toward the wall, border role, wall run mask).
/// A vertical face is reached along the vertical axis and carries {e,w}.
const Face = struct {
    dir: lattice.Dir4,
    role: lattice.BorderRole,
    mask: lattice.Neighbours,
};

const faces = [_]Face{
    .{ .dir = .east, .role = .edge_w, .mask = .{ .n = true, .s = true } },
    .{ .dir = .west, .role = .edge_e, .mask = .{ .n = true, .s = true } },
    .{ .dir = .south, .role = .edge_n, .mask = .{ .e = true, .w = true } },
    .{ .dir = .north, .role = .edge_s, .mask = .{ .e = true, .w = true } },
};

/// Walk `n` steps from (x, y) along `d` on a 7×7 grid.
fn walk(x: i32, y: i32, d: lattice.Dir4, n: i32) sketch.Point {
    return switch (d) {
        .north => .{ .x = x, .y = y - n },
        .south => .{ .x = x, .y = y + n },
        .east => .{ .x = x + n, .y = y },
        .west => .{ .x = x - n, .y = y },
    };
}

test "a decorated gap arrival slides its head onto the border-adjacent cell" {
    // All four faces. The wall sits at the centre-relative position 3 steps
    // out along `dir`; the polyline runs toward it and stops on the gap cell
    // one short, so the raw head lands two cells from the wall. The slide
    // moves it onto the gap.
    const a = testing.allocator;
    for (faces) |f| {
        var lat = try blank(a, 9, 9);
        defer a.free(lat.cells);
        // Start at the centre and travel `dir`: run cell, gap, wall.
        const start: sketch.Point = .{ .x = 4, .y = 4 };
        const gap = walk(start.x, start.y, f.dir, 2);
        const wall = walk(start.x, start.y, f.dir, 3);
        putBorder(&lat, @intCast(wall.x), @intCast(wall.y), f.role, f.mask);
        const raw_head: ep.Head = .{ .cell = walk(start.x, start.y, f.dir, 1), .dir = f.dir };
        const slid = ep.slideHead(&lat, gap, raw_head);
        try testing.expectEqual(gap.x, slid.cell.x);
        try testing.expectEqual(gap.y, slid.cell.y);
        try testing.expectEqual(f.dir, slid.dir);
    }
}

test "a head already abutting the wall does not slide" {
    // No gap: the polyline endpoint IS the border, so there is nothing to
    // slide onto and the head stays where the walk put it.
    const a = testing.allocator;
    var lat = try blank(a, 9, 9);
    defer a.free(lat.cells);
    putBorder(&lat, 6, 4, .edge_w, .{ .n = true, .s = true });
    const head: ep.Head = .{ .cell = .{ .x = 5, .y = 4 }, .dir = .east };
    const slid = ep.slideHead(&lat, .{ .x = 6, .y = 4 }, head);
    try testing.expectEqual(@as(i32, 5), slid.cell.x);
}

test "an occupied gap cell leaves the head where it is" {
    // The probe fires only across an EMPTY endpoint. A cell somebody else
    // owns refuses it, so the head does not move and the whole end falls
    // back to the pre-existing behavior — the slide never overwrites.
    const a = testing.allocator;
    var lat = try blank(a, 9, 9);
    defer a.free(lat.cells);
    putBorder(&lat, 6, 4, .edge_w, .{ .n = true, .s = true });
    lat.at(5, 4).* = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    const head: ep.Head = .{ .cell = .{ .x = 4, .y = 4 }, .dir = .east };
    const slid = ep.slideHead(&lat, .{ .x = 5, .y = 4 }, head);
    try testing.expectEqual(@as(i32, 4), slid.cell.x);
    try testing.expectEqual(
        lattice.Occupant.label_char,
        std.meta.activeTag(lat.atConst(5, 4).occupant),
    );
}

test "a gap before a CORNER does not slide: the landing is refused, not attached" {
    // Ports are face offsets; a corner landing draws no stroke at all. The
    // head must not advance toward a wall the writer refuses to attach to.
    const a = testing.allocator;
    var lat = try blank(a, 9, 9);
    defer a.free(lat.cells);
    putBorder(&lat, 6, 4, .corner_nw, .{ .e = true, .s = true });
    const head: ep.Head = .{ .cell = .{ .x = 4, .y = 4 }, .dir = .east };
    const slid = ep.slideHead(&lat, .{ .x = 5, .y = 4 }, head);
    try testing.expectEqual(@as(i32, 4), slid.cell.x);
}

test "a head two or more cells behind the gap does not slide" {
    // The slide is a ONE-cell advance onto the reprieve. A head further
    // back is genuinely detached: moving it would teleport the glyph off
    // its own run, so the end keeps the old behavior (tee + painted gap).
    const a = testing.allocator;
    var lat = try blank(a, 9, 9);
    defer a.free(lat.cells);
    putBorder(&lat, 6, 4, .edge_w, .{ .n = true, .s = true });
    const head: ep.Head = .{ .cell = .{ .x = 3, .y = 4 }, .dir = .east };
    const slid = ep.slideHead(&lat, .{ .x = 5, .y = 4 }, head);
    try testing.expectEqual(@as(i32, 3), slid.cell.x);
}

fn makeSketch(es: []const sketch.EdgePath) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 9, .h = 9 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = es,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn gapEdge(pts: []const sketch.Point, arrow_to: sketch.ArrowKind) sketch.EdgePath {
    return .{
        .id = 1,
        .from = 0,
        .to = 1,
        .polyline = pts,
        .port_from = .{ .node = 0, .side = .east, .offset = 0 },
        .port_to = .{ .node = 1, .side = .west, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = arrow_to,
        .label = null,
        .kind = .solid,
    };
}

test "a decorated gap arrival stamps its head against the wall, run ink behind it" {
    // End to end, all four faces: `│◀────` and its rotations. The head lands
    // on the border-adjacent cell, the cell it came from is ordinary run
    // ink, the wall stays PLAIN (the tip-facing suppression — the abutting
    // decorated convention), and there is no blank anywhere between run,
    // head and wall.
    const a = testing.allocator;
    for (faces) |f| {
        var lat = try blank(a, 9, 9);
        defer a.free(lat.cells);
        const start: sketch.Point = .{ .x = 4, .y = 4 };
        const run_cell = walk(start.x, start.y, f.dir, 1);
        const gap = walk(start.x, start.y, f.dir, 2);
        const wall = walk(start.x, start.y, f.dir, 3);
        putBorder(&lat, @intCast(wall.x), @intCast(wall.y), f.role, f.mask);
        // The polyline stops on the gap cell — the 1-cell reprieve.
        const pts = [_]sketch.Point{ start, gap };
        const es = [_]sketch.EdgePath{gapEdge(&pts, .filled)};
        _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

        // Head on the gap cell, pointing at the wall.
        const head = lat.atConst(@intCast(gap.x), @intCast(gap.y));
        try testing.expectEqual(lattice.Occupant.arrowhead, std.meta.activeTag(head.occupant));
        try testing.expectEqual(f.dir, head.occupant.arrowhead.dir);
        // The vacated cell is run ink of the same edge — a base-side
        // extension, the only legal side.
        const behind = lat.atConst(@intCast(run_cell.x), @intCast(run_cell.y));
        try testing.expectEqual(lattice.Occupant.edge_segment, std.meta.activeTag(behind.occupant));
        try testing.expectEqual(@as(u32, 1), behind.occupant.edge_segment.edge);
        // The wall is untouched: no tap behind a tip-facing head.
        try testing.expectEqual(f.mask.toMask(), lat.atConst(@intCast(wall.x), @intCast(wall.y)).neighbours.toMask());
    }
}

test "an UNDECORATED gap arrival keeps the painted gap and tees the wall" {
    // No head, no tip side, no constraint: the bare run still closes its
    // approach the way the port writer has always done it.
    const a = testing.allocator;
    var lat = try blank(a, 9, 9);
    defer a.free(lat.cells);
    putBorder(&lat, 7, 4, .edge_w, .{ .n = true, .s = true });
    const pts = [_]sketch.Point{ .{ .x = 4, .y = 4 }, .{ .x = 6, .y = 4 } };
    const es = [_]sketch.EdgePath{gapEdge(&pts, .none)};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);
    try testing.expectEqual(
        lattice.Occupant.edge_segment,
        std.meta.activeTag(lat.atConst(6, 4).occupant),
    );
    try testing.expect(lat.atConst(7, 4).neighbours.w);
}
