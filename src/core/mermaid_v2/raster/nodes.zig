//! Node rasterization — turns `NodePlacement` rects from a Sketch into
//! `node_border` and `node_interior` cells in a Lattice.
//!
//! Import allowlist (enforced by `tools/lint_imports.zig`): `std`,
//! `../sketch.zig`, `../lattice.zig` only — no `parse/` or `paint/`.
//!
//! All shapes rasterize as a rectangular border; round/circle/cylinder/
//! asymmetric variants await refined glyphs in `paint/`.

const std = @import("std");
const sketch = @import("../sketch.zig");

// Scoped logger: occupancy collisions during node rasterization are dev
// diagnostics, not user-facing problems. Routed to .debug so they stay out
// of normal stderr (CLI pipelines, TUI) unless explicitly enabled.
const log = std.log.scoped(.@"mermaid_v2.raster.nodes");
const lattice = @import("../lattice.zig");
const node_shapes = @import("node_shapes.zig");

pub const RasterError = error{
    OutOfMemory,
    OutOfBounds,
    OccupiedCell,
};

/// Rasterize all `NodePlacement`s in `s` into `lat`. Returns the number
/// of nodes that were successfully written to the lattice in full
/// (nodes skipped due to out-of-bounds rects are not counted; nodes
/// with per-cell conflicts ARE counted, since the warning + skip is a
/// best-effort partial write).
///
/// The lattice must be pre-sized by the caller (typically to
/// `s.bbox.w × s.bbox.h`). This function only mutates `*lat`; it owns
/// no state.
pub fn rasterizeNodes(
    allocator: std.mem.Allocator,
    lat: *lattice.Lattice,
    s: sketch.Sketch,
) RasterError!u32 {
    _ = allocator; // currently unused: no auxiliary allocations.
    var written: u32 = 0;
    for (s.nodes) |np| {
        if (!rectFitsLattice(np.rect, lat.*)) {
            log.debug(
                "raster/nodes: node {d} rect ({d},{d},{d}x{d}) out of bounds for lattice {d}x{d}; skipping",
                .{ np.id, np.rect.x, np.rect.y, np.rect.w, np.rect.h, lat.width, lat.height },
            );
            continue;
        }
        // Rasterize the rectangular perimeter + interior for every
        // shape, then tag each border cell with the shape so the
        // painter picks the matching glyph (rounded corners, slash
        // diagonals, parenthesis caps, etc.). Subroutine additionally
        // gets a pair of inner walls written into the interior when
        // there's enough horizontal slack.
        rasterizeRect(lat, np);
        node_shapes.tagShape(lat, np);
        node_shapes.rasterizeSubroutineInner(lat, np);
        written += 1;
    }
    return written;
}

// -- helpers -----------------------------------------------------------------

fn rectFitsLattice(r: sketch.Rect, lat: lattice.Lattice) bool {
    if (r.w == 0 or r.h == 0) return false;
    if (r.x < 0 or r.y < 0) return false;
    const right = r.right();
    const bottom = r.bottom();
    if (right > @as(i32, @intCast(lat.width))) return false;
    if (bottom > @as(i32, @intCast(lat.height))) return false;
    return true;
}

/// Write the perimeter + interior of a single rect-shaped node.
fn rasterizeRect(lat: *lattice.Lattice, np: sketch.NodePlacement) void {
    const rx: u32 = @intCast(np.rect.x);
    const ry: u32 = @intCast(np.rect.y);
    const rw: u32 = np.rect.w;
    const rh: u32 = np.rect.h;
    const x_last: u32 = rx + rw - 1;
    const y_last: u32 = ry + rh - 1;

    // Degenerate cases: w==1 or h==1 collapse the border. We still want
    // to mark the cells (otherwise the node would be invisible), but
    // there are no interior cells and the corner/edge roles collapse.
    if (rw == 1 or rh == 1) {
        writeThinRect(lat, np, rx, ry, x_last, y_last);
        return;
    }

    writeBorder(lat, rx, ry, np.id, .corner_nw, .{ .e = true, .s = true });
    writeBorder(lat, x_last, ry, np.id, .corner_ne, .{ .w = true, .s = true });
    writeBorder(lat, x_last, y_last, np.id, .corner_se, .{ .w = true, .n = true });
    writeBorder(lat, rx, y_last, np.id, .corner_sw, .{ .e = true, .n = true });

    var x: u32 = rx + 1;
    while (x < x_last) : (x += 1) {
        writeBorder(lat, x, ry, np.id, .edge_n, .{ .e = true, .w = true });
        writeBorder(lat, x, y_last, np.id, .edge_s, .{ .e = true, .w = true });
    }

    var y: u32 = ry + 1;
    while (y < y_last) : (y += 1) {
        writeBorder(lat, rx, y, np.id, .edge_w, .{ .n = true, .s = true });
        writeBorder(lat, x_last, y, np.id, .edge_e, .{ .n = true, .s = true });
    }

    var iy: u32 = ry + 1;
    while (iy < y_last) : (iy += 1) {
        var ix: u32 = rx + 1;
        while (ix < x_last) : (ix += 1) {
            writeInterior(lat, ix, iy, np.id);
        }
    }
}

/// Defensive shim for 1xN or Nx1 rects: lay down border cells along
/// the run with horizontal-or-vertical neighbour bits. No interior.
fn writeThinRect(
    lat: *lattice.Lattice,
    np: sketch.NodePlacement,
    rx: u32,
    ry: u32,
    x_last: u32,
    y_last: u32,
) void {
    if (rx == x_last and ry == y_last) {
        writeBorder(lat, rx, ry, np.id, .corner_nw, .{});
        return;
    }
    if (ry == y_last) {
        writeBorder(lat, rx, ry, np.id, .corner_nw, .{ .e = true });
        var x: u32 = rx + 1;
        while (x < x_last) : (x += 1) {
            writeBorder(lat, x, ry, np.id, .edge_n, .{ .e = true, .w = true });
        }
        writeBorder(lat, x_last, ry, np.id, .corner_ne, .{ .w = true });
        return;
    }
    writeBorder(lat, rx, ry, np.id, .corner_nw, .{ .s = true });
    var y: u32 = ry + 1;
    while (y < y_last) : (y += 1) {
        writeBorder(lat, rx, y, np.id, .edge_w, .{ .n = true, .s = true });
    }
    writeBorder(lat, rx, y_last, np.id, .corner_sw, .{ .n = true });
}

fn writeBorder(
    lat: *lattice.Lattice,
    x: u32,
    y: u32,
    node: lattice.NodeId,
    role: lattice.BorderRole,
    nbrs: lattice.Neighbours,
) void {
    const cell = lat.at(x, y);
    if (cell.occupant != .empty) {
        log.debug(
            "raster/nodes: cell ({d},{d}) already occupied; skipping border write for node {d}",
            .{ x, y, node },
        );
        return;
    }
    cell.* = .{
        .occupant = .{ .node_border = .{ .node = node, .role = role } },
        .neighbours = nbrs,
    };
}

fn writeInterior(
    lat: *lattice.Lattice,
    x: u32,
    y: u32,
    node: lattice.NodeId,
) void {
    const cell = lat.at(x, y);
    if (cell.occupant != .empty) {
        log.debug(
            "raster/nodes: cell ({d},{d}) already occupied; skipping interior write for node {d}",
            .{ x, y, node },
        );
        return;
    }
    cell.* = .{
        .occupant = .{ .node_interior = node },
        .neighbours = .{},
    };
}

const testing = std.testing;

fn makeLattice(allocator: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try allocator.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn expectBorder(
    lat: lattice.Lattice,
    x: u32,
    y: u32,
    node: lattice.NodeId,
    role: lattice.BorderRole,
    nbrs: lattice.Neighbours,
) !void {
    const c = lat.atConst(x, y).*;
    switch (c.occupant) {
        .node_border => |b| {
            try testing.expectEqual(node, b.node);
            try testing.expectEqual(role, b.role);
        },
        else => return error.NotABorder,
    }
    try testing.expectEqual(nbrs.toMask(), c.neighbours.toMask());
}

fn expectInterior(lat: lattice.Lattice, x: u32, y: u32, node: lattice.NodeId) !void {
    const c = lat.atConst(x, y).*;
    switch (c.occupant) {
        .node_interior => |n| try testing.expectEqual(node, n),
        else => return error.NotInterior,
    }
    try testing.expectEqual(@as(u4, 0), c.neighbours.toMask());
}

fn expectEmpty(lat: lattice.Lattice, x: u32, y: u32) !void {
    const c = lat.atConst(x, y).*;
    switch (c.occupant) {
        .empty => {},
        else => return error.NotEmpty,
    }
}

fn singleNodeSketch(np: sketch.NodePlacement, nodes_buf: []sketch.NodePlacement) sketch.Sketch {
    nodes_buf[0] = np;
    return .{
        .bbox = np.rect,
        .direction = .TD,
        .nodes = nodes_buf[0..1],
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

test "single 3x3 rect produces 4 corners + 4 edges + 1 interior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 3, 3);
    var nodes_buf: [1]sketch.NodePlacement = undefined;
    const s = singleNodeSketch(.{
        .id = 7,
        .rect = .{ .x = 0, .y = 0, .w = 3, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    }, &nodes_buf);

    const n = try rasterizeNodes(a, &lat, s);
    try testing.expectEqual(@as(u32, 1), n);

    // Corners.
    try expectBorder(lat, 0, 0, 7, .corner_nw, .{ .e = true, .s = true });
    try expectBorder(lat, 2, 0, 7, .corner_ne, .{ .w = true, .s = true });
    try expectBorder(lat, 2, 2, 7, .corner_se, .{ .w = true, .n = true });
    try expectBorder(lat, 0, 2, 7, .corner_sw, .{ .e = true, .n = true });

    // Edges (one cell each side).
    try expectBorder(lat, 1, 0, 7, .edge_n, .{ .e = true, .w = true });
    try expectBorder(lat, 1, 2, 7, .edge_s, .{ .e = true, .w = true });
    try expectBorder(lat, 0, 1, 7, .edge_w, .{ .n = true, .s = true });
    try expectBorder(lat, 2, 1, 7, .edge_e, .{ .n = true, .s = true });

    // Single interior cell.
    try expectInterior(lat, 1, 1, 7);
}

test "wider 5x3 rect has 4 corners, 3+3 top/bottom edges, 3 interior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 5, 3);
    var nodes_buf: [1]sketch.NodePlacement = undefined;
    const s = singleNodeSketch(.{
        .id = 1,
        .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    }, &nodes_buf);

    const n = try rasterizeNodes(a, &lat, s);
    try testing.expectEqual(@as(u32, 1), n);

    // Corners.
    try expectBorder(lat, 0, 0, 1, .corner_nw, .{ .e = true, .s = true });
    try expectBorder(lat, 4, 0, 1, .corner_ne, .{ .w = true, .s = true });
    try expectBorder(lat, 4, 2, 1, .corner_se, .{ .w = true, .n = true });
    try expectBorder(lat, 0, 2, 1, .corner_sw, .{ .e = true, .n = true });

    // Three top edge cells, three bottom edge cells.
    var x: u32 = 1;
    while (x <= 3) : (x += 1) {
        try expectBorder(lat, x, 0, 1, .edge_n, .{ .e = true, .w = true });
        try expectBorder(lat, x, 2, 1, .edge_s, .{ .e = true, .w = true });
    }
    // No side-edge cells (height 3 means only one middle row, occupied
    // by edge_w/edge_e at the corners' column — let's confirm those).
    try expectBorder(lat, 0, 1, 1, .edge_w, .{ .n = true, .s = true });
    try expectBorder(lat, 4, 1, 1, .edge_e, .{ .n = true, .s = true });

    // Three interior cells in the middle row.
    try expectInterior(lat, 1, 1, 1);
    try expectInterior(lat, 2, 1, 1);
    try expectInterior(lat, 3, 1, 1);
}

test "two non-overlapping rects both rasterize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 10, 5);
    var nodes_buf: [2]sketch.NodePlacement = undefined;
    nodes_buf[0] = .{
        .id = 1,
        .rect = .{ .x = 0, .y = 0, .w = 4, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
    nodes_buf[1] = .{
        .id = 2,
        .rect = .{ .x = 5, .y = 1, .w = 4, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 10, .h = 5 },
        .direction = .TD,
        .nodes = nodes_buf[0..2],
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const n = try rasterizeNodes(a, &lat, s);
    try testing.expectEqual(@as(u32, 2), n);

    try expectBorder(lat, 0, 0, 1, .corner_nw, .{ .e = true, .s = true });
    try expectBorder(lat, 3, 0, 1, .corner_ne, .{ .w = true, .s = true });
    try expectInterior(lat, 1, 1, 1);

    try expectBorder(lat, 5, 1, 2, .corner_nw, .{ .e = true, .s = true });
    try expectBorder(lat, 8, 1, 2, .corner_ne, .{ .w = true, .s = true });
    try expectInterior(lat, 6, 2, 2);

    // The gap between them should be empty.
    try expectEmpty(lat, 4, 0);
    try expectEmpty(lat, 4, 4);
}

test "conflicting cell is skipped, leaving the prior occupant intact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 4, 4);

    // Pre-fill the top-left corner cell with a fake label_char.
    lat.at(0, 0).* = .{
        .occupant = .{ .label_char = 'X' },
        .neighbours = .{},
    };

    var nodes_buf: [1]sketch.NodePlacement = undefined;
    const s = singleNodeSketch(.{
        .id = 9,
        .rect = .{ .x = 0, .y = 0, .w = 3, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    }, &nodes_buf);

    const n = try rasterizeNodes(a, &lat, s);
    // Node is still counted (best-effort partial write).
    try testing.expectEqual(@as(u32, 1), n);

    // The pre-occupied cell is untouched.
    const c00 = lat.atConst(0, 0).*;
    switch (c00.occupant) {
        .label_char => |ch| try testing.expectEqual(@as(u21, 'X'), ch),
        else => return error.OverwroteOccupiedCell,
    }
    // Other border cells were still written.
    try expectBorder(lat, 2, 0, 9, .corner_ne, .{ .w = true, .s = true });
    try expectInterior(lat, 1, 1, 9);
}

test "out-of-bounds rect is skipped and not counted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 4, 4);
    var nodes_buf: [2]sketch.NodePlacement = undefined;
    nodes_buf[0] = .{
        .id = 1,
        // Extends to x=5 (right edge exclusive 6), past width 4.
        .rect = .{ .x = 2, .y = 0, .w = 4, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
    nodes_buf[1] = .{
        .id = 2,
        .rect = .{ .x = 0, .y = 0, .w = 3, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .direction = .TD,
        .nodes = nodes_buf[0..2],
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const n = try rasterizeNodes(a, &lat, s);
    // OOB node skipped; in-bounds node rasterized.
    try testing.expectEqual(@as(u32, 1), n);

    try expectBorder(lat, 0, 0, 2, .corner_nw, .{ .e = true, .s = true });
    try expectBorder(lat, 2, 0, 2, .corner_ne, .{ .w = true, .s = true });
    try expectInterior(lat, 1, 1, 2);
}
