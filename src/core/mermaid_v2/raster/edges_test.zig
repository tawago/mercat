//! Unit tests for raster/edges.zig. Split out to keep edges.zig under
//! the 500-line cap.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const edges = @import("edges.zig");

const testing = std.testing;

fn makeLattice(allocator: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try allocator.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn makeSketch(es: []const sketch.EdgePath) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 16, .h = 16 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = es,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn makeEdge(
    id: u32,
    pts: []const sketch.Point,
    arrow_from: sketch.ArrowKind,
    arrow_to: sketch.ArrowKind,
) sketch.EdgePath {
    return .{
        .id = id,
        .from = 0,
        .to = 1,
        .polyline = pts,
        .port_from = .{ .node = 0, .side = .east, .offset = 0 },
        .port_to = .{ .node = 1, .side = .west, .offset = 0 },
        .arrow_from = arrow_from,
        .arrow_to = arrow_to,
        .label = null,
        .kind = .solid,
    };
}

test "single horizontal segment writes interior cells with E+W bits" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 10);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 2, .y = 2 }, .{ .x = 6, .y = 2 } };
    const es = [_]sketch.EdgePath{makeEdge(1, &pts, .none, .none)};
    const written = (try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge)).edges_written;
    try testing.expectEqual(@as(u32, 1), written);

    try testing.expect(switch (lat.atConst(2, 2).occupant) {
        .empty => true,
        else => false,
    });
    try testing.expect(switch (lat.atConst(6, 2).occupant) {
        .empty => true,
        else => false,
    });

    var x: u32 = 3;
    while (x <= 5) : (x += 1) {
        const cell = lat.atConst(x, 2);
        try testing.expect(switch (cell.occupant) {
            .edge_segment => |seg| seg.edge == 1,
            else => false,
        });
        try testing.expectEqual(
            (lattice.Neighbours{ .e = true, .w = true }).toMask(),
            cell.neighbours.toMask(),
        );
    }
}

test "L-shaped corner has reverse-incoming + outgoing bits" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 10);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{
        .{ .x = 2, .y = 2 },
        .{ .x = 2, .y = 6 },
        .{ .x = 6, .y = 6 },
    };
    const es = [_]sketch.EdgePath{makeEdge(7, &pts, .none, .none)};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    const corner = lat.atConst(2, 6);
    try testing.expect(switch (corner.occupant) {
        .edge_segment => |seg| seg.edge == 7,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true }).toMask(),
        corner.neighbours.toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        lat.atConst(2, 3).neighbours.toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        lat.atConst(4, 6).neighbours.toMask(),
    );
}

test "arrowhead at end of polyline" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 4);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 0 } };
    const es = [_]sketch.EdgePath{makeEdge(42, &pts, .none, .filled)};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    const cell = lat.atConst(4, 0);
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .east and ah.edge == 42,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
}

test "length-1 final segment after a corner points the terminal arrowhead into the port" {
    // Polyline runs EAST to a corner, then a SINGLE cell SOUTH into the
    // target port. The final segment writes no interior cell (its only
    // cell is the skipped target), so the terminal arrowhead lands ON the
    // corner. It must point SOUTH (the final approach into the port), not
    // EAST (the incoming run) — an east arrowhead would float sideways
    // beside the target instead of entering it. Regression guard for the
    // frenzy Mermaid->DiagramTypes floating-▶ defect.
    const a = testing.allocator;
    var lat = try makeLattice(a, 8, 5);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 1 } };
    const es = [_]sketch.EdgePath{makeEdge(11, &pts, .none, .filled)};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    const cell = lat.atConst(5, 0);
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 11,
        else => false,
    });
}

test "two crossing edges merge neighbour bits" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 10);
    defer a.free(lat.cells);

    const pts_h = [_]sketch.Point{ .{ .x = 1, .y = 5 }, .{ .x = 10, .y = 5 } };
    const pts_v = [_]sketch.Point{ .{ .x = 5, .y = 1 }, .{ .x = 5, .y = 9 } };
    const es = [_]sketch.EdgePath{
        makeEdge(1, &pts_h, .none, .none),
        makeEdge(2, &pts_v, .none, .none),
    };
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    const cell = lat.atConst(5, 5);
    try testing.expect(switch (cell.occupant) {
        .edge_segment => true,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
}

test "degenerate polyline with < 2 points is skipped" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 4, 4);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{.{ .x = 1, .y = 1 }};
    const es = [_]sketch.EdgePath{makeEdge(99, &pts, .none, .none)};
    const written = (try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge)).edges_written;
    try testing.expectEqual(@as(u32, 0), written);
}

test "EdgeRole round-trips from EdgePath into Cell.edge_segment.role" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 4);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 1, .y = 1 }, .{ .x = 7, .y = 1 } };
    var e = makeEdge(11, &pts, .none, .none);
    e.role = .back_edge;
    const es = [_]sketch.EdgePath{e};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    var x: u32 = 2;
    while (x <= 6) : (x += 1) {
        const cell = lat.atConst(x, 1);
        try testing.expect(switch (cell.occupant) {
            .edge_segment => |seg| seg.role == .back_edge and seg.edge == 11,
            else => false,
        });
    }
}

test "zero-length intermediate point is skipped" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 4);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{
        .{ .x = 1, .y = 1 },
        .{ .x = 1, .y = 1 },
        .{ .x = 5, .y = 1 },
    };
    const es = [_]sketch.EdgePath{makeEdge(3, &pts, .none, .none)};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    var x: u32 = 2;
    while (x <= 4) : (x += 1) {
        try testing.expect(switch (lat.atConst(x, 1).occupant) {
            .edge_segment => |seg| seg.edge == 3,
            else => false,
        });
    }
}

test "edge cells colliding with node-owned cells are counted as lost" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 10);
    defer a.free(lat.cells);

    // A node interior blocks columns 3..5 of row 2 — the raster-time
    // signature of a path_through_interior layout defect.
    var x: u32 = 3;
    while (x <= 5) : (x += 1) {
        lat.at(x, 2).* = .{
            .occupant = .{ .node_interior = 7 },
            .neighbours = .{},
        };
    }

    const pts = [_]sketch.Point{ .{ .x = 2, .y = 2 }, .{ .x = 8, .y = 2 } };
    const es = [_]sketch.EdgePath{makeEdge(1, &pts, .none, .none)};
    const report = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    // Cells 3,4,5 collide and are skipped; 6,7 are written ((a,b] walk
    // excludes the target endpoint 8 on the last segment).
    try testing.expectEqual(@as(u32, 3), report.cells_lost);
    try testing.expectEqual(@as(u32, 1), report.edges_written);
    // Blocked cells stay node-owned.
    try testing.expect(lat.atConst(4, 2).occupant == .node_interior);
}

test "collision-free edge reports zero cells lost" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 10);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 2, .y = 2 }, .{ .x = 6, .y = 2 } };
    const es = [_]sketch.EdgePath{makeEdge(1, &pts, .none, .filled)};
    const report = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);
    try testing.expectEqual(@as(u32, 0), report.cells_lost);
}

// -- Frame-solid border bridging (D-CROSS, owner ruling 2026-07-19) ----------
// The V-D-CROSS-01 reading transposed to a subgraph FRAME: a through-going edge
// crossing a border BRIDGES it (frame glyph continuous, no fabricated tee); a
// TERMINAL arrival (final segment cell / arrowhead) keeps today's merge.

/// Stamp one `.cluster_border` cell carrying `mask` (a frame run glyph).
fn stampBorder(lat: *lattice.Lattice, x: u32, y: u32, mask: lattice.Neighbours) void {
    lat.at(x, y).* = .{
        .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } },
        .neighbours = mask,
    };
}

test "through-crossing bridges a subgraph frame border" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    // Horizontal frame run `─` at row 5; a vertical edge crosses it mid-path.
    stampBorder(&lat, 5, 5, .{ .e = true, .w = true });
    const pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 8 } };
    const es = [_]sketch.EdgePath{makeEdge(1, &pts, .none, .none)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    // The border cell keeps its occupant and its `─` mask — no ┼ fabricated.
    const border = lat.atConst(5, 5).*;
    try testing.expect(border.occupant == .cluster_border);
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        border.neighbours.toMask(),
    );
    // The edge resumes on BOTH adjacent cells (gapless).
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        lat.atConst(5, 4).neighbours.toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        lat.atConst(5, 6).neighbours.toMask(),
    );
    // Exactly one bridge event, no corner refusal.
    try testing.expectEqual(@as(u32, 1), r.crossings.b_frame_bridge);
    try testing.expectEqual(@as(u32, 0), r.crossings.b_border_fusion_refused);
}

test "terminal segment cell on a frame border keeps today's merge" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    // The edge ENDS on the border (target port at (5,7); last written cell is
    // (5,6) the border) — a terminal arrival INTO the cluster, which merges.
    stampBorder(&lat, 5, 6, .{ .e = true, .w = true });
    const pts = [_]sketch.Point{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 7 } };
    const es = [_]sketch.EdgePath{makeEdge(9, &pts, .none, .none)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    const cell = lat.atConst(5, 6).*;
    try testing.expect(switch (cell.occupant) {
        .edge_segment => |seg| seg.edge == 9,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
    try testing.expectEqual(@as(u32, 0), r.crossings.b_frame_bridge);
}

test "an arrowhead terminating on a frame border is stamped (arrival AT the cluster)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    stampBorder(&lat, 5, 6, .{ .e = true, .w = true });
    const pts = [_]sketch.Point{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 7 } };
    const es = [_]sketch.EdgePath{makeEdge(9, &pts, .none, .filled)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    const cell = lat.atConst(5, 6).*;
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 9,
        else => false,
    });
    try testing.expectEqual(@as(u32, 0), r.crossings.b_frame_bridge);
}

test "corner arm onto a subgraph frame border is refused" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    // A vertical frame run `│` at (6,5); the edge turns its corner ON it.
    stampBorder(&lat, 6, 5, .{ .n = true, .s = true });
    const pts = [_]sketch.Point{ .{ .x = 2, .y = 5 }, .{ .x = 6, .y = 5 }, .{ .x = 6, .y = 9 } };
    const es = [_]sketch.EdgePath{makeEdge(3, &pts, .none, .none)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    // The frame stays pristine: still a cluster_border with its `│` mask, no
    // ┼/├ welded by the corner arm.
    const border = lat.atConst(6, 5).*;
    try testing.expect(border.occupant == .cluster_border);
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        border.neighbours.toMask(),
    );
    // The corner arm was refused (one report-only event). The incoming east
    // run STOPS at this cell — it is the segment endpoint, owned by the corner
    // writer, not a through-going cell — so no frame-bridge event fires for it.
    try testing.expectEqual(@as(u32, 1), r.crossings.b_border_fusion_refused);
    try testing.expectEqual(@as(u32, 0), r.crossings.b_frame_bridge);
}

// -- `.cross` mode: pre-Slice-1 junction weld (owner ruling 2026-07-19) -------
// The user-selectable legacy notation. A through-going edge (and a corner)
// crossing a subgraph frame border WELDS into it exactly as before Slice 1 —
// the border cell becomes an `edge_segment` with the merged/replaced mask and
// NO bridge/refusal event fires. These pin the byte-identical restoration.

test "cross mode: through-crossing welds the frame border (pre-slice-1)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    // Same geometry as the bridge through-crossing test, but `.cross`.
    stampBorder(&lat, 5, 5, .{ .e = true, .w = true });
    const pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 8 } };
    const es = [_]sketch.EdgePath{makeEdge(1, &pts, .none, .none)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .cross);

    // The border cell is OVERWRITTEN as this edge's segment, its `─` bits
    // OR-merged with the crossing `│` → a fabricated ┼ (writeEdgeCell's
    // `.cluster_border` arm). This is the old behavior verbatim.
    const border = lat.atConst(5, 5).*;
    try testing.expect(switch (border.occupant) {
        .edge_segment => |seg| seg.edge == 1,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
        border.neighbours.toMask(),
    );
    // No frame-solid event fires in `.cross` mode.
    try testing.expectEqual(@as(u32, 0), r.crossings.b_frame_bridge);
    try testing.expectEqual(@as(u32, 0), r.crossings.b_border_fusion_refused);
}

test "cross mode: corner arm onto a subgraph frame border welds a tee (pre-slice-1)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    // Same geometry as the bridge corner-refusal test, but `.cross`.
    stampBorder(&lat, 6, 5, .{ .n = true, .s = true });
    const pts = [_]sketch.Point{ .{ .x = 2, .y = 5 }, .{ .x = 6, .y = 5 }, .{ .x = 6, .y = 9 } };
    const es = [_]sketch.EdgePath{makeEdge(3, &pts, .none, .none)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .cross);

    // The border is welded into the edge (no pristine frame): the incoming east
    // run overwrites it, then the corner arm replaces the mask with its
    // {west,south} corner bits — the old, byte-identical outcome.
    const border = lat.atConst(6, 5).*;
    try testing.expect(switch (border.occupant) {
        .edge_segment => |seg| seg.edge == 3,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .w = true, .s = true }).toMask(),
        border.neighbours.toMask(),
    );
    // No frame-solid events in `.cross` mode.
    try testing.expectEqual(@as(u32, 0), r.crossings.b_border_fusion_refused);
    try testing.expectEqual(@as(u32, 0), r.crossings.b_frame_bridge);
}

test "shared trunk corner: sibling drops bending at one cell yield ┴, not a phantom ┼" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    // Three `.forward` edges (an UNDETECTED fan: no fan role, so
    // stampFanTrunks never stamps or strips the trunk) descend a shared
    // source column to a common rail row (5), then bend to their own
    // columns. None continues SOUTH past the trunk cell (5,5): the left
    // two bend west, the right one bends east. The trunk cell must render
    // ┴ ({n,e,w}) — a phantom {s} here (drawn by a sibling's straight
    // endpoint before the corner rewrite) would falsely assert a fourth
    // arm and paint ┼.
    const a_pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 5 }, .{ .x = 2, .y = 5 }, .{ .x = 2, .y = 8 } };
    const b_pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 5 }, .{ .x = 4, .y = 5 }, .{ .x = 4, .y = 8 } };
    const c_pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 5 }, .{ .x = 8, .y = 5 }, .{ .x = 8, .y = 8 } };
    const es = [_]sketch.EdgePath{
        makeEdge(1, &a_pts, .none, .none),
        makeEdge(2, &b_pts, .none, .none),
        makeEdge(3, &c_pts, .none, .none),
    };
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge);

    // Trunk cell: north riser + east/west rail, NO south arm.
    const trunk = lat.atConst(5, 5).neighbours;
    try testing.expect(trunk.n and trunk.e and trunk.w);
    try testing.expect(!trunk.s);

    // Contrast: a real sibling drop keeps its south arm (┬ at the bending
    // column), proving the fix suppresses only the phantom, not real drops.
    const drop = lat.atConst(4, 5).neighbours;
    try testing.expect(drop.s);
}
