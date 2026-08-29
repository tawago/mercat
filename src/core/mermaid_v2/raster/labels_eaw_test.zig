//! Unit tests for the East-Asian-Width label geometry: `labels.cellSpan`
//! / `cellSpanOf` and the three writers that advance by it (node label,
//! cluster title, edge/tap label).
//!
//! The acceptance rail these pin is ASCII byte-identity: every ASCII
//! codepoint spans exactly one cell, so every cursor advance and every
//! free-space reservation is bit-for-bit what it was before continuation
//! cells existed. Split out of labels_test.zig to stay under the cap.

const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels = @import("labels.zig");

const testing = std.testing;

fn makeLattice(alloc: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try alloc.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn fillNodeInterior(lat: *lattice.Lattice, rect: sketch.Rect, nid: u32) void {
    var y: i32 = rect.y + 1;
    while (y < rect.bottom() - 1) : (y += 1) {
        var x: i32 = rect.x + 1;
        while (x < rect.right() - 1) : (x += 1) {
            lat.at(@intCast(x), @intCast(y)).* = .{
                .occupant = .{ .node_interior = nid },
                .neighbours = .{},
            };
        }
    }
}

fn cellChar(lat: lattice.Lattice, x: u32, y: u32) u21 {
    return switch (lat.atConst(x, y).occupant) {
        .label_char => |c| c,
        else => 0,
    };
}

fn isCont(lat: lattice.Lattice, x: u32, y: u32) bool {
    return switch (lat.atConst(x, y).occupant) {
        .label_cont => true,
        else => false,
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

test "cellSpan is 1 for every ASCII codepoint including tab" {
    // The whole ASCII range, exhaustively: tab (4 display columns) and the
    // C0 controls (0 columns, incl. the LINE_BREAK sentinel) deliberately
    // keep the frozen one-cell span. This is the mechanical proof that no
    // ASCII render can grow a continuation cell or shift a cursor.
    var cp: u21 = 0;
    while (cp < 0x80) : (cp += 1) {
        try testing.expectEqual(@as(u32, 1), labels.cellSpan(cp));
    }
    try testing.expectEqual(@as(u32, 1), labels.cellSpan(prim.LINE_BREAK));
    try testing.expectEqual(@as(u32, 2), labels.cellSpan('日'));
}

test "cellSpanOf equals prim.displayWidth for tab- and control-free text" {
    const samples = [_][]const u8{
        "",
        "A",
        "hello world",
        "route: api",
        "日本語",
        "A日B語C",
        "…",
    };
    for (samples) |s| {
        try testing.expectEqual(prim.displayWidth(s), labels.cellSpanOf(s));
    }
    // The one documented divergence: a tab paints 4 columns but claims 1
    // cell (frozen to keep ASCII byte-identity).
    try testing.expectEqual(@as(u32, 4), prim.displayWidth("\t"));
    try testing.expectEqual(@as(u32, 1), labels.cellSpanOf("\t"));
}

test "wide node label writes char + continuation and paints two columns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 5);
    // inner_w = 6 cells; the label is 3 wide glyphs = 6 display columns.
    const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = 8, .h = 3 };
    fillNodeInterior(&lat, rect, 1);

    const nodes = [_]sketch.NodePlacement{.{
        .id = 1,
        .rect = rect,
        .shape = .rect,
        .lines = &.{"日本語"},
        .cluster_id = null,
    }};
    var s = emptySketch(12, 5, .TD);
    s.nodes = &nodes;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    // No truncation: the box was sized in display columns and the writer
    // now advances in the same unit.
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    try testing.expectEqual(@as(u21, '日'), cellChar(lat, 1, 1));
    try testing.expect(isCont(lat, 2, 1));
    try testing.expectEqual(@as(u21, '本'), cellChar(lat, 3, 1));
    try testing.expect(isCont(lat, 4, 1));
    try testing.expectEqual(@as(u21, '語'), cellChar(lat, 5, 1));
    try testing.expect(isCont(lat, 6, 1));
}

test "a wide node glyph whose second cell is not this node's interior is refused whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 5);
    const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = 8, .h = 3 };
    fillNodeInterior(&lat, rect, 1);
    // Punch a foreign cell where the first glyph's TAIL would land.
    lat.at(2, 1).* = .{ .occupant = .{ .node_interior = 9 }, .neighbours = .{} };

    const nodes = [_]sketch.NodePlacement{.{
        .id = 1,
        .rect = rect,
        .shape = .rect,
        .lines = &.{"日本語"},
        .cluster_id = null,
    }};
    var s = emptySketch(12, 5, .TD);
    s.nodes = &nodes;

    _ = try labels.rasterizeLabels(alloc, &lat, s, null);

    // Head refused too — never a half glyph — and the cursor still moved,
    // so the following glyphs keep their columns.
    try testing.expectEqual(@as(u21, 0), cellChar(lat, 1, 1));
    try testing.expect(!isCont(lat, 1, 1));
    try testing.expectEqual(@as(u21, '本'), cellChar(lat, 3, 1));
    try testing.expect(isCont(lat, 4, 1));
}

test "wide cluster title advances by span and still closes the band" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 14, 6);
    var x: u32 = 0;
    while (x < 12) : (x += 1) {
        lat.at(x, 0).* = .{
            .occupant = .{ .cluster_border = .{ .cluster = 3, .role = .edge_n } },
            .neighbours = .{},
        };
    }

    const clusters = [_]sketch.ClusterFrame{.{
        .id = 3,
        .rect = .{ .x = 0, .y = 0, .w = 12, .h = 4 },
        .parent_id = null,
        .label = "日本",
        .depth = 0,
    }};
    var s = emptySketch(14, 6, .TD);
    s.clusters = &clusters;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);

    try testing.expectEqual(@as(u21, ' '), cellChar(lat, 2, 0));
    try testing.expectEqual(@as(u21, '日'), cellChar(lat, 3, 0));
    try testing.expect(isCont(lat, 4, 0));
    try testing.expectEqual(@as(u21, '本'), cellChar(lat, 5, 0));
    try testing.expect(isCont(lat, 6, 0));
    // The trailing space closes the band past the last PAINTED column,
    // not one cell after the last codepoint.
    try testing.expectEqual(@as(u21, ' '), cellChar(lat, 7, 0));
}

test "edge-label probe reserves display cells: a wide label no longer overwrites the ink beside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Row 2 is the only candidate row (the segment sits on row 3 and row 4
    // is out of bounds). A 2-glyph CJK label needs 4 cells; only 3 are
    // free before the pre-placed ink, so the probe must refuse this row —
    // by codepoint count it would have "fit" and clobbered the ink.
    var lat = try makeLattice(alloc, 8, 4);
    lat.at(4, 2).* = .{
        .occupant = .{ .edge_segment = .{ .edge = 77, .kind = .solid } },
        .neighbours = .{ .n = true, .s = true },
    };

    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "日本")};
    var s = emptySketch(8, 4, .LR);
    s.edges = &edges;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 0), report.placed);
    try testing.expectEqual(@as(u32, 1), report.dropped);

    // The pre-placed ink survived untouched.
    try testing.expect(switch (lat.atConst(4, 2).occupant) {
        .edge_segment => |seg| seg.edge == 77,
        else => false,
    });
}

test "edge label writes head + continuation when the reserved span fits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 7, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "日")};
    var s = emptySketch(12, 6, .LR);
    s.edges = &edges;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);

    var found = false;
    var x: u32 = 0;
    while (x + 1 < lat.width) : (x += 1) {
        if (cellChar(lat, x, 2) == '日') {
            try testing.expect(isCont(lat, x + 1, 2));
            found = true;
        }
    }
    try testing.expect(found);
}

test "blank-flank rule treats a continuation as a label neighbour" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A wide label already occupies cells (2,2)-(3,2): head + continuation.
    // Every span the ladder can reach on the only candidate row sits within
    // two cells of the CONTINUATION, so the run-separation rule must refuse
    // them exactly as it would refuse the head, and the label drops.
    const poly = [_]sketch.Point{ .{ .x = 3, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(5, &poly, "ab")};
    var s = emptySketch(8, 4, .LR);
    s.edges = &edges;

    var lat = try makeLattice(alloc, 8, 4);
    lat.at(2, 2).* = .{ .occupant = .{ .label_char = '日' }, .neighbours = .{} };
    lat.at(3, 2).* = .{ .occupant = .label_cont, .neighbours = .{} };

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 0), report.placed);
    try testing.expectEqual(@as(u32, 1), report.dropped);

    // Control: the continuation is what refuses it. Free that one cell and
    // the identical ladder places the label (at x=5, two blanks past the
    // head at x=2).
    var free_lat = try makeLattice(alloc, 8, 4);
    free_lat.at(2, 2).* = .{ .occupant = .{ .label_char = '日' }, .neighbours = .{} };

    const free_report = try labels.rasterizeLabels(alloc, &free_lat, s, null);
    try testing.expectEqual(@as(u32, 1), free_report.placed);
}
