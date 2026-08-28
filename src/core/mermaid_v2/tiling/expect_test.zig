//! Unit tests for `tiling/expect.zig`, over hand-built Sketch + lattice
//! pairs: a clean pair first, then one deliberate divergence at a time so
//! each bucket is shown to be the ONLY thing that moves.

const std = @import("std");
const lattice = @import("../lattice.zig");
const sem_graph = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");
const expect = @import("expect.zig");

const testing = std.testing;

/// Two 3x3 boxes stacked with one cell of gap, joined by a single edge.
/// Lattice is 3 wide, 7 tall:
///
///   rows 0..2  node 0     rows 4..6  node 1
///   row 3      the edge's only interior cell (its arrowhead)
const Fixture = struct {
    cells: [21]lattice.Cell = undefined,
    nodes: [2]sketch.NodePlacement = undefined,
    edges: [1]sketch.EdgePath = undefined,
    poly: [2]sketch.Point = undefined,
    lines_a: [1][]const u8 = .{"A"},
    lines_b: [1][]const u8 = .{"B"},

    fn lat(self: *Fixture) lattice.Lattice {
        return .{ .width = 3, .height = 7, .cells = &self.cells };
    }

    fn set(self: *Fixture, x: usize, y: usize, c: lattice.Cell) void {
        self.cells[y * 3 + x] = c;
    }

    fn box(self: *Fixture, node: u32, top: usize) void {
        self.set(0, top, .{ .occupant = .{ .node_border = .{ .node = node, .role = .corner_nw } }, .neighbours = .{ .e = true, .s = true } });
        self.set(1, top, .{ .occupant = .{ .node_border = .{ .node = node, .role = .edge_n } }, .neighbours = .{ .e = true, .w = true } });
        self.set(2, top, .{ .occupant = .{ .node_border = .{ .node = node, .role = .corner_ne } }, .neighbours = .{ .w = true, .s = true } });
        self.set(0, top + 1, .{ .occupant = .{ .node_border = .{ .node = node, .role = .edge_w } }, .neighbours = .{ .n = true, .s = true } });
        self.set(1, top + 1, .{ .occupant = .{ .label_char = if (node == 0) 'A' else 'B' }, .neighbours = .{} });
        self.set(2, top + 1, .{ .occupant = .{ .node_border = .{ .node = node, .role = .edge_e } }, .neighbours = .{ .n = true, .s = true } });
        self.set(0, top + 2, .{ .occupant = .{ .node_border = .{ .node = node, .role = .corner_sw } }, .neighbours = .{ .e = true, .n = true } });
        self.set(1, top + 2, .{ .occupant = .{ .node_border = .{ .node = node, .role = .edge_s } }, .neighbours = .{ .e = true, .w = true } });
        self.set(2, top + 2, .{ .occupant = .{ .node_border = .{ .node = node, .role = .corner_se } }, .neighbours = .{ .w = true, .n = true } });
    }

    fn init(self: *Fixture) void {
        for (&self.cells) |*c| c.* = lattice.Cell.empty;
        self.box(0, 0);
        self.box(1, 4);
        // The source-border merge stamped the departure bit.
        self.cells[2 * 3 + 1].neighbours = .{ .e = true, .w = true, .s = true };
        // The edge's single interior cell carries its arrowhead.
        self.set(1, 3, .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 0 } }, .neighbours = .{ .n = true, .s = true } });

        self.nodes[0] = .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 3, .h = 3 }, .shape = .rect, .lines = &self.lines_a, .cluster_id = null };
        self.nodes[1] = .{ .id = 1, .rect = .{ .x = 0, .y = 4, .w = 3, .h = 3 }, .shape = .rect, .lines = &self.lines_b, .cluster_id = null };
        self.poly = .{ .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 4 } };
        self.edges[0] = .{
            .id = 0,
            .from = 0,
            .to = 1,
            .polyline = &self.poly,
            .port_from = .{ .node = 0, .side = .south, .offset = 1 },
            .port_to = .{ .node = 1, .side = .north, .offset = 1 },
            .arrow_from = .none,
            .arrow_to = .filled,
            .label = null,
            .kind = .solid,
        };
    }

    fn sk(self: *Fixture) sketch.Sketch {
        return .{
            .bbox = .{ .x = 0, .y = 0, .w = 3, .h = 7 },
            .direction = .TD,
            .nodes = &self.nodes,
            .clusters = &.{},
            .edges = &self.edges,
            .diagnostics = &.{},
            .budget = .{ .max_width = 80, .rung = 0 },
        };
    }
};

fn emptyGraph() sem_graph.SemGraph {
    return .{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
}

fn run(f: *Fixture, lat: *const lattice.Lattice) counts.Counts {
    var c: counts.Counts = .{};
    expect.check(testing.allocator, .{
        .graph = emptyGraph(),
        .sketch = f.sk(),
        .lat = lat,
        .labels_placed = 2,
        .labels_dropped = 0,
        .labels_displaced = 0,
    }, &c);
    return c;
}

test "expect: a coherent Sketch and lattice produce no expectation defect" {
    var f: Fixture = .{};
    f.init();
    const lat = f.lat();
    const c = run(&f, &lat);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try testing.expectEqual(@as(u32, 1), c.n_edges_declared);
    try testing.expectEqual(@as(u32, 1), c.n_arrows_declared);
    try testing.expectEqual(@as(u32, 2), c.n_nodes_declared);
    try testing.expectEqual(@as(u32, 2), c.n_labels_declared);
    try testing.expectEqual(@as(u32, 0), c.u_label_census_mismatch);
    try testing.expectEqual(@as(u32, 0), c.u_audit_oom);
    try testing.expectEqual(@as(u32, 0), c.m_term_ink_deficit);
}

test "expect: a blank approach cell is missing evidence and a missing arrow" {
    var f: Fixture = .{};
    f.init();
    f.set(1, 3, lattice.Cell.empty);
    const lat = f.lat();
    const c = run(&f, &lat);
    try testing.expectEqual(@as(u32, 1), c.d_edge_no_terminal_evidence);
    try testing.expectEqual(@as(u32, 1), c.d_arrow_missing);
    try testing.expectEqual(@as(u32, 0), c.c_edge_absorbed);
}

test "expect: a blank approach whose run resumes one cell on is reprieved" {
    var f: Fixture = .{};
    f.init();
    f.set(1, 3, lattice.Cell.empty);
    // The arrival is one cell further along the approach axis.
    f.set(1, 4, .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 0 } }, .neighbours = .{ .n = true } });
    const lat = f.lat();
    const c = run(&f, &lat);
    try testing.expectEqual(@as(u32, 0), c.d_edge_no_terminal_evidence);
    try testing.expectEqual(@as(u32, 0), c.d_arrow_missing);
}

test "expect: foreign opaque ink at the approach is absorbed, never missing" {
    var f: Fixture = .{};
    f.init();
    // A label landed on the approach cell: the arrival may well be under
    // it, and positional evidence cannot say whose ink this is.
    f.set(1, 3, .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} });
    const lat = f.lat();
    const c = run(&f, &lat);
    try testing.expectEqual(@as(u32, 1), c.c_edge_absorbed);
    try testing.expectEqual(@as(u32, 0), c.d_edge_no_terminal_evidence);
    // The arrowhead write is refused over a label, a documented path.
    try testing.expectEqual(@as(u32, 1), c.c_arrow_refused);
    try testing.expectEqual(@as(u32, 0), c.d_arrow_missing);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "expect: evidence is positional, so a foreign first writer still counts" {
    var f: Fixture = .{};
    f.init();
    // Some other edge claimed the approach cell first. Its id is wrong for
    // this edge; the ink is still there.
    f.set(1, 3, .{ .occupant = .{ .edge_segment = .{ .edge = 99, .kind = .solid } }, .neighbours = .{ .n = true, .s = true } });
    const lat = f.lat();
    const c = run(&f, &lat);
    try testing.expectEqual(@as(u32, 0), c.d_edge_no_terminal_evidence);
    try testing.expectEqual(@as(u32, 0), c.c_edge_absorbed);
    // No arrowhead anywhere on the axis, though.
    try testing.expectEqual(@as(u32, 1), c.d_arrow_missing);
}

test "expect: a missing source-merge bit on a vertical departure is a defect" {
    var f: Fixture = .{};
    f.init();
    const lat = f.lat();
    try testing.expectEqual(@as(u32, 0), run(&f, &lat).d_source_merge_missing);

    // Strip the departure bit the merge promises.
    f.cells[2 * 3 + 1].neighbours = .{ .e = true, .w = true };
    try testing.expectEqual(@as(u32, 1), run(&f, &lat).d_source_merge_missing);
}

test "expect: a horizontal departure is outside the source-merge contract" {
    var f: Fixture = .{};
    f.init();
    // Re-route the edge to leave eastward: the merge is N/S-only, so a
    // border without the bit is not a defect.
    f.poly = .{ .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 } };
    f.cells[2 * 3 + 1].neighbours = .{ .e = true, .w = true };
    const lat = f.lat();
    try testing.expectEqual(@as(u32, 0), run(&f, &lat).d_source_merge_missing);
}

test "expect: a node ring with no cells of its own is missing" {
    var f: Fixture = .{};
    f.init();
    var y: usize = 4;
    while (y < 7) : (y += 1) {
        var x: usize = 0;
        while (x < 3) : (x += 1) f.set(x, y, lattice.Cell.empty);
    }
    const lat = f.lat();
    const c = run(&f, &lat);
    try testing.expectEqual(@as(u32, 1), c.d_node_ring_missing);
    try testing.expectEqual(@as(u32, 1), c.d_node_label_missing);
}

test "expect: an off-grid placement is a convention, not a missing ring" {
    var f: Fixture = .{};
    f.init();
    f.nodes[1].rect = .{ .x = 0, .y = 4, .w = 9, .h = 3 };
    const lat = f.lat();
    const c = run(&f, &lat);
    try testing.expectEqual(@as(u32, 1), c.c_node_offgrid);
    try testing.expectEqual(@as(u32, 0), c.d_node_ring_missing);
    try testing.expectEqual(@as(u32, 0), c.d_node_label_missing);
}

test "expect: a label with no room refuses rather than fails" {
    var f: Fixture = .{};
    f.init();
    // Below 3x3 the label placer refuses outright.
    f.nodes[1].rect = .{ .x = 0, .y = 4, .w = 2, .h = 2 };
    const lat = f.lat();
    const c = run(&f, &lat);
    try testing.expectEqual(@as(u32, 1), c.c_node_label_no_room);
    try testing.expectEqual(@as(u32, 0), c.d_node_label_missing);
}

test "expect: a shadowed arrival shows up in the ink deficit" {
    var f: Fixture = .{};
    f.init();
    // The arrival cell is gone: node 1 declares one in-arrival and has no
    // ink abutting its perimeter at all.
    f.set(1, 3, lattice.Cell.empty);
    const lat = f.lat();
    try testing.expectEqual(@as(u32, 1), run(&f, &lat).m_term_ink_deficit);
}

test "expect: the census makes sem-to-sketch loss visible without per-edge claims" {
    var f: Fixture = .{};
    f.init();
    const lat = f.lat();

    var nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 2, .raw_id = "C", .label = "C", .shape = .rect, .classes = &.{}, .cluster = null },
    };
    var c: counts.Counts = .{};
    expect.check(testing.allocator, .{
        .graph = .{ .direction = .TD, .nodes = &nodes, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null },
        .sketch = f.sk(),
        .lat = &lat,
        .labels_placed = 2,
    }, &c);
    try testing.expectEqual(@as(u32, 3), c.m_graph_nodes);
    try testing.expectEqual(@as(u32, 2), c.m_sketch_nodes);
    // A census delta is a measurement; it accuses no particular node.
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "expect: a tap keys on its landing, so a rail fan needs no polyline" {
    var cells: [35]lattice.Cell = undefined;
    for (&cells) |*c| c.* = lattice.Cell.empty;
    const lat = lattice.Lattice{ .width = 5, .height = 7, .cells = &cells };
    // Rail along row 3, one tap dropping to a landing at (0,5).
    cells[3 * 5 + 0] = .{ .occupant = .{ .edge_segment = .{ .edge = 4, .kind = .solid, .role = .fan_out_rail } }, .neighbours = .{ .e = true, .s = true } };
    cells[4 * 5 + 0] = .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 7 } }, .neighbours = .{ .n = true, .s = true } };

    var taps = [_]sketch.Tap{.{ .edge = 7, .node = 2, .at = .{ .x = 0, .y = 3 }, .landing = .{ .x = 0, .y = 5 } }};
    var bars = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &.{},
        .crossbar = .{ .{ .x = 0, .y = 3 }, .{ .x = 2, .y = 3 } },
        .taps = &taps,
        .kind = .solid,
    }};
    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 5, .h = 7 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .rails = &bars,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    var c: counts.Counts = .{};
    expect.check(testing.allocator, .{ .graph = emptyGraph(), .sketch = s, .lat = &lat }, &c);
    try testing.expectEqual(@as(u32, 1), c.n_taps_declared);
    try testing.expectEqual(@as(u32, 1), c.m_sketch_edges);
    try testing.expectEqual(@as(u32, 1), c.n_arrows_declared);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "expect: a failing allocator degrades to partial counts, never to a crash" {
    var f: Fixture = .{};
    f.init();
    const lat = f.lat();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var c: counts.Counts = .{};
    expect.check(failing.allocator(), .{
        .graph = emptyGraph(),
        .sketch = f.sk(),
        .lat = &lat,
        .labels_placed = 2,
    }, &c);

    try testing.expectEqual(@as(u32, 1), c.u_audit_oom);
    // The counters filled in before the allocation survive...
    try testing.expectEqual(@as(u32, 2), c.m_sketch_nodes);
    try testing.expectEqual(@as(u32, 2), c.n_labels_declared);
    // ...and the tier that needed the scratch simply did not run.
    try testing.expectEqual(@as(u32, 0), c.n_nodes_declared);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}
