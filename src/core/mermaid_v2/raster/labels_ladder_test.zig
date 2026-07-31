//! Unit tests for the labels_edge.zig three-pass ladder (LAW 1 relocate-
//! before-reroute + LAW 2 label-region isolation). Split out of
//! labels_test.zig for the mermaid_v2 500-line cap.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels = @import("labels.zig");

const testing = std.testing;

fn makeLattice(alloc: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try alloc.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn cellChar(lat: lattice.Lattice, x: u32, y: u32) u21 {
    return switch (lat.atConst(x, y).occupant) {
        .label_char => |c| c,
        else => 0,
    };
}

fn emptySketch(bw: u32, bh: u32, dir: sketch.Direction) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = bw, .h = bh },
        .direction = dir,
        .nodes = &[_]sketch.NodePlacement{},
        .clusters = &[_]sketch.ClusterFrame{},
        .edges = &[_]sketch.EdgePath{},
        .diagnostics = &[_]sketch.Diagnostic{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn makeEdge(id: u32, poly: []const sketch.Point, label: ?[]const u8) sketch.EdgePath {
    return .{
        .id = id,
        .from = 0,
        .to = 1,
        .polyline = poly,
        .port_from = .{ .node = 0, .side = .east, .offset = 0 },
        .port_to = .{ .node = 1, .side = .west, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = label,
        .kind = .solid,
    };
}

fn stampEdgeCell(lat: *lattice.Lattice, x: u32, y: u32, edge_id: u32) void {
    lat.at(x, y).* = .{
        .occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = .solid } },
        .neighbours = .{ .w = true, .e = true },
    };
}

test "own-edge ink beside the anchor does not displace the label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(12, 6, .LR);
    s.edges = &edges;

    // Stamp the label's OWN edge's run into the lattice, directly below the
    // whole anchor row — distance-1 own-ink adjacency, the exemption LAW 2
    // grants (the convention anchor sits right beside its own run).
    var x: u32 = 1;
    while (x <= 5) : (x += 1) stampEdgeCell(&lat, x, 3, 42);

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(u32, 0), report.displaced);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    // The label lands at its primary anchor (3,2), abutting its own ink.
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 3, 2));
}

test "isolation rejects a foreign-ink neighbour in every one of the 8 directions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const dirs = [8][2]i32{
        .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
        .{ -1, 0 },  .{ 1, 0 },
        .{ -1, 1 },  .{ 0, 1 },  .{ 1, 1 },
    };
    for (dirs) |d| {
        var lat = try makeLattice(alloc, 12, 7);
        // Vertical own segment on column 5; the single-char anchor is two
        // columns right of the rail at mid-height: (7,3). None of its 8
        // neighbours lie on the own path, so a foreign stamp in any of them
        // is unambiguous foreign ink.
        const poly = [_]sketch.Point{ .{ .x = 5, .y = 1 }, .{ .x = 5, .y = 5 } };
        const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
        var s = emptySketch(12, 7, .TD);
        s.edges = &edges;

        stampEdgeCell(&lat, @intCast(7 + d[0]), @intCast(3 + d[1]), 9);

        const report = try labels.rasterizeLabels(alloc, &lat, s, null);
        try testing.expectEqual(@as(u32, 1), report.placed);
        try testing.expectEqual(@as(u32, 1), report.displaced);
        try testing.expectEqual(@as(u21, 0), cellChar(lat, 7, 3));
    }
}

// LAW 1 / P1: when the primary anchor is nowhere near the label's own
// edge's ink, the first pass relocates the label to a slot whose nearest
// ink (Chebyshev <= 2) IS its own edge — even though the ownership-blind
// ladder would have accepted the anchor.
test "P1 beats the primary anchor: the label relocates to sit by its own edge's ink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 14, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 9, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(14, 6, .LR);
    s.edges = &edges;

    // The only rasterized ink of edge 42 is the far end of its run.
    stampEdgeCell(&lat, 9, 3, 42);

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(u32, 1), report.displaced);

    // Not at the anchor (5,2) — own ink is 4 cells away there...
    try testing.expectEqual(@as(u21, 0), cellChar(lat, 5, 2));
    // ...but at (7,2), the first walk slot within Chebyshev 2 of (9,3).
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 7, 2));
}

// LAW 1 / P2: with every P1 (own-adjacent) slot blocked by foreign node
// ink, the second pass still prefers a slot strictly nearer the label's
// own ink (within Chebyshev 4) over the earlier-in-ladder anchor slot the
// ownership-blind pass P3 would take.
test "P2 walks the label toward its own edge's ink when P1 positions are blocked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Height 4: the row BELOW the segment is out of bounds, so the walk
    // cannot find a P1 slot under the far end of the run.
    var lat = try makeLattice(alloc, 16, 4);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 13, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(16, 4, .LR);
    s.edges = &edges;

    // Own ink only at the far end of the run...
    stampEdgeCell(&lat, 13, 3, 42);
    // ...and foreign node-border ink above it, so every slot within
    // Chebyshev 2 of the own ink violates the LAW 2 margin (P1 exhausted).
    lat.at(12, 1).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };
    lat.at(13, 1).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(u32, 1), report.displaced);

    // P3 alone would take the anchor (7,2); P2 runs first and lands the
    // label at (9,2) — own ink at Chebyshev 4, no competing edge ink.
    try testing.expectEqual(@as(u21, 0), cellChar(lat, 7, 2));
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 9, 2));
}

// LAW 2 / final pass: when every candidate's margin is violated only by
// node/cluster ink, the `any_solid` pass places the label abutting the
// border instead of dropping it; when the violator is a foreign EDGE, no
// pass ever waives the margin and the label drops.
test "allow_solid waives only the node/cluster margin, never the foreign-edge margin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const poly = [_]sketch.Point{ .{ .x = 1, .y = 2 }, .{ .x = 9, .y = 2 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(12, 5, .LR);
    s.edges = &edges;

    // Case 1: node-border ink walls off rows 0 and 4, so both candidate
    // rows (1 and 3) touch solid ink everywhere. Placed anyway, at the
    // primary anchor, by the solid-tolerant last pass.
    var lat = try makeLattice(alloc, 12, 5);
    var x: u32 = 0;
    while (x < 12) : (x += 1) {
        lat.at(x, 0).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };
        lat.at(x, 4).* = .{ .occupant = .{ .node_border = .{ .node = 2, .role = .edge_n } }, .neighbours = .{} };
    }
    const solid_report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), solid_report.placed);
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 5, 1));

    // Case 2: the same walls made of a FOREIGN edge's ink — the margin is
    // never waived, so the label drops.
    var lat2 = try makeLattice(alloc, 12, 5);
    x = 0;
    while (x < 12) : (x += 1) {
        stampEdgeCell(&lat2, x, 0, 9);
        stampEdgeCell(&lat2, x, 4, 9);
    }
    const edge_report = try labels.rasterizeLabels(alloc, &lat2, s, null);
    try testing.expectEqual(@as(u32, 0), edge_report.placed);
    try testing.expectEqual(@as(u32, 1), edge_report.dropped);
}

test "edge-label placement is deterministic: identical lattices place identically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 9, .y = 3 } };
    const edges = [_]sketch.EdgePath{ makeEdge(42, &poly, "ab"), makeEdge(7, &poly, "cd") };
    var s = emptySketch(14, 6, .LR);
    s.edges = &edges;

    var grids: [2]lattice.Lattice = undefined;
    for (&grids) |*g| {
        g.* = try makeLattice(alloc, 14, 6);
        stampEdgeCell(g, 9, 3, 42);
        _ = try labels.rasterizeLabels(alloc, g, s, null);
    }
    for (grids[0].cells, grids[1].cells) |c0, c1| {
        try testing.expect(std.meta.eql(c0.occupant, c1.occupant));
    }
}
