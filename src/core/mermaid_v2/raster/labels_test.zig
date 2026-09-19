const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels = @import("labels.zig");

const testing = std.testing;
const ELLIPSIS: u21 = 0x2026;

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

test "node label fits centered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 10, 5);
    const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = 7, .h = 3 };
    fillNodeInterior(&lat, rect, 1);

    const nodes = [_]sketch.NodePlacement{.{
        .id = 1,
        .rect = rect,
        .shape = .rect,
        .lines = &.{"Hi"},
        .cluster_id = null,
    }};
    var s = emptySketch(10, 5, .TD);
    s.nodes = &nodes;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(u32, 0), report.dropped);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    try testing.expectEqual(@as(u21, 'H'), cellChar(lat, 2, 1));
    try testing.expectEqual(@as(u21, 'i'), cellChar(lat, 3, 1));
}

test "node label truncated emits diagnostic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 10, 5);
    const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 };
    fillNodeInterior(&lat, rect, 7);

    const nodes = [_]sketch.NodePlacement{.{
        .id = 7,
        .rect = rect,
        .shape = .rect,
        .lines = &.{"Hello"},
        .cluster_id = null,
    }};
    var s = emptySketch(10, 5, .TD);
    s.nodes = &nodes;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try testing.expectEqual(labels.LabelDiagnostic{
        .kind = .node_label_truncated,
        .node_or_edge_or_cluster_id = 7,
        .original_len = 5,
        .placed_len = 3,
    }, report.diagnostics[0]);

    try testing.expectEqual(@as(u21, 'H'), cellChar(lat, 1, 1));
    try testing.expectEqual(@as(u21, 'e'), cellChar(lat, 2, 1));
    try testing.expectEqual(ELLIPSIS, cellChar(lat, 3, 1));
}

test "cluster label overwrites top border" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 6);
    var x: u32 = 0;
    while (x < 8) : (x += 1) {
        lat.at(x, 0).* = .{
            .occupant = .{ .cluster_border = .{ .cluster = 3, .role = .edge_n } },
            .neighbours = .{},
        };
    }

    const clusters = [_]sketch.ClusterFrame{.{
        .id = 3,
        .rect = .{ .x = 0, .y = 0, .w = 8, .h = 4 },
        .parent_id = null,
        .label = "Sub",
        .depth = 0,
    }};
    var s = emptySketch(12, 6, .TD);
    s.clusters = &clusters;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    try testing.expectEqual(@as(u21, ' '), cellChar(lat, 2, 0));
    try testing.expectEqual(@as(u21, 'S'), cellChar(lat, 3, 0));
    try testing.expectEqual(@as(u21, 'u'), cellChar(lat, 4, 0));
    try testing.expectEqual(@as(u21, 'b'), cellChar(lat, 5, 0));
    try testing.expectEqual(@as(u21, ' '), cellChar(lat, 6, 0));
}

test "edge label fits above midpoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 10, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(10, 6, .LR);
    s.edges = &edges;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 3, 2));
}

test "no space for edge label emits diagnostic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 10, 1);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 5, .y = 0 } };
    const edges = [_]sketch.EdgePath{makeEdge(9, &poly, "lbl")};
    var s = emptySketch(10, 1, .LR);
    s.edges = &edges;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 0), report.placed);
    try testing.expectEqual(@as(u32, 1), report.dropped);
    try testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try testing.expectEqual(@as(u32, 9), report.diagnostics[0].node_or_edge_or_cluster_id);
    try testing.expect(report.diagnostics[0].kind == .edge_label_no_space);
}

test "vertical edge label paints at the exact prim anchor for both rail sides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const poly = [_]sketch.Point{ .{ .x = 10, .y = 2 }, .{ .x = 10, .y = 6 } };
    const label = "abc";
    const label_w = prim.displayWidth(label);

    {
        var lat = try makeLattice(alloc, 20, 10);
        var e = makeEdge(1, &poly, label);
        e.label_left_of_run = false;
        const edges = [_]sketch.EdgePath{e};
        var s = emptySketch(20, 10, .LR);
        s.edges = &edges;

        const report = try labels.rasterizeLabels(alloc, &lat, s, null);
        try testing.expectEqual(@as(u32, 1), report.placed);
        try testing.expectEqual(@as(u32, 0), report.dropped);

        const want = prim.edgeLabelAnchor(10, 2, 10, 6, label_w, .{});
        try testing.expectEqual(@as(u21, 'a'), cellChar(lat, @intCast(want.x), @intCast(want.y)));
        try testing.expectEqual(@as(u21, 'b'), cellChar(lat, @intCast(want.x + 1), @intCast(want.y)));
        try testing.expectEqual(@as(u21, 'c'), cellChar(lat, @intCast(want.x + 2), @intCast(want.y)));
    }

    {
        var lat = try makeLattice(alloc, 20, 10);
        var e = makeEdge(2, &poly, label);
        e.label_left_of_run = true;
        const edges = [_]sketch.EdgePath{e};
        var s = emptySketch(20, 10, .LR);
        s.edges = &edges;

        const report = try labels.rasterizeLabels(alloc, &lat, s, null);
        try testing.expectEqual(@as(u32, 1), report.placed);
        try testing.expectEqual(@as(u32, 0), report.dropped);

        const want = prim.leftOfRailAnchor(10, 2, 10, 6, label_w);
        try testing.expectEqual(@as(u21, 'a'), cellChar(lat, @intCast(want.x), @intCast(want.y)));
        try testing.expectEqual(@as(u21, 'b'), cellChar(lat, @intCast(want.x + 1), @intCast(want.y)));
        try testing.expectEqual(@as(u21, 'c'), cellChar(lat, @intCast(want.x + 2), @intCast(want.y)));
        const right = prim.edgeLabelAnchor(10, 2, 10, 6, label_w, .{});
        try testing.expect(want.x != right.x);
    }
}

test "rail tap labels paint at the tapLabelSeg-predicted segment for off-column and on-column taps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 30, 15);

    const junction: sketch.Point = .{ .x = 5, .y = 3 };
    const stem = [_]sketch.Point{ .{ .x = 5, .y = 8 }, junction };
    const crossbar = [2]sketch.Point{ junction, .{ .x = 20, .y = 3 } };

    const off_col_tap: sketch.Tap = .{
        .edge = 1,
        .node = 10,
        .at = .{ .x = 12, .y = 3 },
        .landing = .{ .x = 12, .y = 8 },
        .label = "ab",
    };
    const on_col_tap: sketch.Tap = .{
        .edge = 2,
        .node = 11,
        .at = .{ .x = 5, .y = 3 },
        .landing = .{ .x = 5, .y = 12 },
        .label = "cd",
    };
    const taps = [_]sketch.Tap{ off_col_tap, on_col_tap };

    const rail: sketch.Rail = .{
        .pivot = 0,
        .stem = &stem,
        .crossbar = crossbar,
        .taps = &taps,
        .kind = .solid,
    };
    var s = emptySketch(30, 15, .TD);
    s.rails = &[_]sketch.Rail{rail};

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 2), report.placed);
    try testing.expectEqual(@as(u32, 0), report.dropped);

    const off_seg = rail.tapLabelSeg(off_col_tap);
    const off_w = prim.displayWidth(off_col_tap.label.?);
    const off_anchor = prim.edgeLabelAnchor(off_seg[0].x, off_seg[0].y, off_seg[1].x, off_seg[1].y, off_w, .{});
    try testing.expectEqual(@as(u21, 'a'), cellChar(lat, @intCast(off_anchor.x), @intCast(off_anchor.y)));
    try testing.expectEqual(@as(u21, 'b'), cellChar(lat, @intCast(off_anchor.x + 1), @intCast(off_anchor.y)));

    const on_seg = rail.tapLabelSeg(on_col_tap);
    const on_w = prim.displayWidth(on_col_tap.label.?);
    const on_anchor = prim.edgeLabelAnchor(on_seg[0].x, on_seg[0].y, on_seg[1].x, on_seg[1].y, on_w, .{});
    try testing.expectEqual(@as(u21, 'c'), cellChar(lat, @intCast(on_anchor.x), @intCast(on_anchor.y)));
    try testing.expectEqual(@as(u21, 'd'), cellChar(lat, @intCast(on_anchor.x + 1), @intCast(on_anchor.y)));

    try testing.expect(off_seg[0].y == off_seg[1].y);
    try testing.expect(on_seg[0].x == on_seg[1].x);
}

test "clearLine settles for touch-free line at the MARGIN_BOUND boundary rather than searching further for a margined one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const want: i32 = 50;
    var list = std.ArrayList(sketch.NodePlacement){};
    var row: i32 = want - 40;
    var next_id: u32 = 0;
    while (row <= want + 29) : (row += 1) {
        if (row == want + 5) continue;
        try list.append(alloc, .{
            .id = next_id,
            .rect = .{ .x = 0, .y = row, .w = 10, .h = 1 },
            .shape = .rect,
            .lines = &.{},
            .cluster_id = null,
        });
        next_id += 1;
    }
    const placements = try list.toOwnedSlice(alloc);

    const got = sketch.clearLine(true, want, 0, 5, placements, 9999, 9998, .{ .margin = true });
    try testing.expectEqual(want + 5, got);
}

test "edge label falls back below the segment when above is out of bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 10, 4);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 5, .y = 0 } };
    const edges = [_]sketch.EdgePath{makeEdge(9, &poly, "lbl")};
    var s = emptySketch(10, 4, .LR);
    s.edges = &edges;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(u32, 0), report.dropped);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    try testing.expectEqual(@as(u21, 'l'), cellChar(lat, 3, 1));
    try testing.expectEqual(@as(u21, 'b'), cellChar(lat, 4, 1));
}

test "tryWrite rejects a pre-occupied primary-anchor cell as a real collision, not an OOB miss" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 10, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(10, 6, .LR);
    s.edges = &edges;

    lat.at(3, 2).* = .{ .occupant = .{ .node_interior = 99 }, .neighbours = .{} };

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    try testing.expectEqual(@as(u21, 0), cellChar(lat, 3, 2));
    try testing.expectEqual(@as(u21, 0), cellChar(lat, 2, 2));
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 1, 2));
}

test "edge-label runs on the same row keep two blank cells apart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(12, 6, .LR);
    s.edges = &edges;

    var px: u32 = 0;
    while (px < 3) : (px += 1) {
        lat.at(px, 2).* = .{ .occupant = .{ .label_char = 'Q' }, .neighbours = .{} };
    }

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    try testing.expectEqual(@as(u21, 'Q'), cellChar(lat, 2, 2));
    try testing.expectEqual(@as(u21, 0), cellChar(lat, 3, 2));
    try testing.expectEqual(@as(u21, 0), cellChar(lat, 4, 2));
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 5, 2));
}
