//! Unit tests for raster/labels.zig. Split out to keep labels.zig under
//! the 500-line cap.

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
        .id = 1, .rect = rect, .shape = .rect, .lines = &.{"Hi"}, .cluster_id = null,
    }};
    var s = emptySketch(10, 5, .TD);
    s.nodes = &nodes;

    const report = try labels.rasterizeLabels(alloc, &lat, s);
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
        .id = 7, .rect = rect, .shape = .rect, .lines = &.{"Hello"}, .cluster_id = null,
    }};
    var s = emptySketch(10, 5, .TD);
    s.nodes = &nodes;

    const report = try labels.rasterizeLabels(alloc, &lat, s);
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

    const report = try labels.rasterizeLabels(alloc, &lat, s);
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

    const report = try labels.rasterizeLabels(alloc, &lat, s);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 3, 2));
}

test "no space for edge label emits diagnostic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 1-row lattice: the rows above and below the segment are both out of
    // bounds and the segment row itself is never a candidate, so the whole
    // fallback ladder fails and the label is dropped.
    var lat = try makeLattice(alloc, 10, 1);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 5, .y = 0 } };
    const edges = [_]sketch.EdgePath{makeEdge(9, &poly, "lbl")};
    var s = emptySketch(10, 1, .LR);
    s.edges = &edges;

    const report = try labels.rasterizeLabels(alloc, &lat, s);
    try testing.expectEqual(@as(u32, 0), report.placed);
    try testing.expectEqual(@as(u32, 1), report.dropped);
    try testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try testing.expectEqual(@as(u32, 9), report.diagnostics[0].node_or_edge_or_cluster_id);
    try testing.expect(report.diagnostics[0].kind == .edge_label_no_space);
}

// `EdgePath.label_left_of_rail` contract (sketch.zig's "the painted label
// lands exactly where the bbox reserved it"): `layout/clusters.computeBbox`
// RESERVES room via `prim.edgeLabelAnchor`/`leftOfRailAnchor` and records
// which side it chose on `label_left_of_rail`; raster (here) must PAINT at
// that exact same anchor. This test recomputes the anchor directly via the
// shared `prim` functions (the same ones computeBbox calls) and asserts the
// painted cells land there — for BOTH the default right-of-rail anchor and
// the width-lever's left-of-rail anchor on a vertical segment, so a raster
// change that stops honoring the flag (or hand-rolls a different offset)
// fails this test even though it never touches layout/clusters.zig.
test "vertical edge label paints at the exact prim anchor for both rail sides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const poly = [_]sketch.Point{ .{ .x = 10, .y = 2 }, .{ .x = 10, .y = 6 } };
    const label = "abc";
    const label_w = prim.displayWidth(label);

    // Right-of-rail (default; label_left_of_rail = false).
    {
        var lat = try makeLattice(alloc, 20, 10);
        var e = makeEdge(1, &poly, label);
        e.label_left_of_rail = false;
        const edges = [_]sketch.EdgePath{e};
        var s = emptySketch(20, 10, .LR);
        s.edges = &edges;

        const report = try labels.rasterizeLabels(alloc, &lat, s);
        try testing.expectEqual(@as(u32, 1), report.placed);
        try testing.expectEqual(@as(u32, 0), report.dropped);

        const want = prim.edgeLabelAnchor(10, 2, 10, 6, label_w, .{});
        try testing.expectEqual(@as(u21, 'a'), cellChar(lat, @intCast(want.x), @intCast(want.y)));
        try testing.expectEqual(@as(u21, 'b'), cellChar(lat, @intCast(want.x + 1), @intCast(want.y)));
        try testing.expectEqual(@as(u21, 'c'), cellChar(lat, @intCast(want.x + 2), @intCast(want.y)));
    }

    // Left-of-rail (the width lever's relocated anchor; label_left_of_rail = true).
    {
        var lat = try makeLattice(alloc, 20, 10);
        var e = makeEdge(2, &poly, label);
        e.label_left_of_rail = true;
        const edges = [_]sketch.EdgePath{e};
        var s = emptySketch(20, 10, .LR);
        s.edges = &edges;

        const report = try labels.rasterizeLabels(alloc, &lat, s);
        try testing.expectEqual(@as(u32, 1), report.placed);
        try testing.expectEqual(@as(u32, 0), report.dropped);

        const want = prim.leftOfRailAnchor(10, 2, 10, 6, label_w);
        try testing.expectEqual(@as(u21, 'a'), cellChar(lat, @intCast(want.x), @intCast(want.y)));
        try testing.expectEqual(@as(u21, 'b'), cellChar(lat, @intCast(want.x + 1), @intCast(want.y)));
        try testing.expectEqual(@as(u21, 'c'), cellChar(lat, @intCast(want.x + 2), @intCast(want.y)));
        // Confirm the two anchors actually differ — otherwise this test
        // would pass even if raster ignored the flag entirely.
        const right = prim.edgeLabelAnchor(10, 2, 10, 6, label_w, .{});
        try testing.expect(want.x != right.x);
    }
}

// `BusBar.tapLabelSeg`'s off-column/on-column rule (sketch.zig): bbox
// reservation (layout/clusters.computeBbox) and rasterization (raster/labels,
// here) both call this SAME method to find the segment a tap label anchors
// to, then feed it to the SAME `prim.edgeLabelAnchor`. Building one
// off-column and one on-column tap and checking the painted cells against
// that shared formula pins both the rule (off-column -> junction..tap rail
// stretch; on-column -> tap..landing drop) and the cross-stage agreement.
test "bus-bar tap labels paint at the tapLabelSeg-predicted segment for off-column and on-column taps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 30, 15);

    const junction: sketch.Point = .{ .x = 5, .y = 3 };
    const stem = [_]sketch.Point{ .{ .x = 5, .y = 8 }, junction };
    const rail = [2]sketch.Point{ junction, .{ .x = 20, .y = 3 } };

    // Off-column: tap.at.x (12) != junction.x (5) -> seg = (junction.x,
    // tap.at.y)..tap.at, a HORIZONTAL rail stretch.
    const off_col_tap: sketch.Tap = .{
        .edge = 1,
        .node = 10,
        .at = .{ .x = 12, .y = 3 },
        .landing = .{ .x = 12, .y = 8 },
        .label = "ab",
    };
    // On-column: tap.at.x (5) == junction.x -> seg = tap.at..tap.landing,
    // a VERTICAL drop.
    const on_col_tap: sketch.Tap = .{
        .edge = 2,
        .node = 11,
        .at = .{ .x = 5, .y = 3 },
        .landing = .{ .x = 5, .y = 12 },
        .label = "cd",
    };
    const taps = [_]sketch.Tap{ off_col_tap, on_col_tap };

    const busbar: sketch.BusBar = .{
        .pivot = 0,
        .stem = &stem,
        .rail = rail,
        .taps = &taps,
        .kind = .solid,
    };
    var s = emptySketch(30, 15, .TD);
    s.busbars = &[_]sketch.BusBar{busbar};

    const report = try labels.rasterizeLabels(alloc, &lat, s);
    try testing.expectEqual(@as(u32, 2), report.placed);
    try testing.expectEqual(@as(u32, 0), report.dropped);

    const off_seg = busbar.tapLabelSeg(off_col_tap);
    const off_w = prim.displayWidth(off_col_tap.label.?);
    const off_anchor = prim.edgeLabelAnchor(off_seg[0].x, off_seg[0].y, off_seg[1].x, off_seg[1].y, off_w, .{});
    try testing.expectEqual(@as(u21, 'a'), cellChar(lat, @intCast(off_anchor.x), @intCast(off_anchor.y)));
    try testing.expectEqual(@as(u21, 'b'), cellChar(lat, @intCast(off_anchor.x + 1), @intCast(off_anchor.y)));

    const on_seg = busbar.tapLabelSeg(on_col_tap);
    const on_w = prim.displayWidth(on_col_tap.label.?);
    const on_anchor = prim.edgeLabelAnchor(on_seg[0].x, on_seg[0].y, on_seg[1].x, on_seg[1].y, on_w, .{});
    try testing.expectEqual(@as(u21, 'c'), cellChar(lat, @intCast(on_anchor.x), @intCast(on_anchor.y)));
    try testing.expectEqual(@as(u21, 'd'), cellChar(lat, @intCast(on_anchor.x + 1), @intCast(on_anchor.y)));

    // Confirm the two segments actually differ in orientation — otherwise
    // this test would pass even if tapLabelSeg collapsed both cases to the
    // same rule.
    try testing.expect(off_seg[0].y == off_seg[1].y); // horizontal (rail stretch)
    try testing.expect(on_seg[0].x == on_seg[1].x); // vertical (drop)
}

// `MARGIN_BOUND` (sketch.zig): bounds how far `clearLine` searches for a
// fully-margined line (3 consecutive touch-free rows) before settling for a
// merely touch-free one. This builds a row of obstacles with a single
// touch-free row at delta=5 (not margined — its neighbours are blocked) and
// a fully-clear 3-row margined band starting only at delta=30 (past the
// bound). If `clearLine` kept searching past MARGIN_BOUND for a margined
// line it would return the delta=30 band instead of the delta=5 line.
test "clearLine settles for touch-free line at the MARGIN_BOUND boundary rather than searching further for a margined one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const want: i32 = 50;
    var list = std.ArrayList(sketch.NodePlacement){};
    // Block every row in [want-40, want+29] except want+5 (the lone
    // touch-free opening). Rows want+30..want+32 are left unblocked below,
    // forming a 3-row-clear margined band past the MARGIN_BOUND horizon.
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

    // Segment on row 0: the primary anchor row (y-1) is out of bounds, so
    // the ladder places the label on the row below instead of dropping it.
    var lat = try makeLattice(alloc, 10, 4);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 5, .y = 0 } };
    const edges = [_]sketch.EdgePath{makeEdge(9, &poly, "lbl")};
    var s = emptySketch(10, 4, .LR);
    s.edges = &edges;

    const report = try labels.rasterizeLabels(alloc, &lat, s);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(u32, 0), report.dropped);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    // Midpoint anchor x=3, one row below the segment.
    try testing.expectEqual(@as(u21, 'l'), cellChar(lat, 3, 1));
    try testing.expectEqual(@as(u21, 'b'), cellChar(lat, 4, 1));
}

// ---------------------------------------------------------------------
// labels_edge.zig / tryWrite: rejects a pre-occupied cell as a genuine
// collision, not merely an out-of-bounds check. Moved here (from the
// former misc grab-bag test file, since dissolved) since the only call
// this test makes is to `labels.rasterizeLabels` (tryWrite itself is
// private to labels_edge.zig and not reachable directly).
// ---------------------------------------------------------------------
test "tryWrite rejects a pre-occupied primary-anchor cell as a real collision, not an OOB miss" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 10, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(10, 6, .LR);
    s.edges = &edges;

    // Occupy the primary anchor cell (3,2) BEFORE rasterizing labels — same
    // spot "edge label fits above midpoint" (this file) shows the label
    // lands on when the cell is free. A pre-existing occupant here must be
    // a genuine collision the ladder walks around, not silently overwritten.
    lat.at(3, 2).* = .{ .occupant = .{ .node_interior = 99 }, .neighbours = .{} };

    const report = try labels.rasterizeLabels(alloc, &lat, s);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    // The obstacle at the primary anchor must survive untouched...
    try testing.expectEqual(@as(u21, 0), cellChar(lat, 3, 2));
    // ...and the label must have been displaced to the next ladder rung
    // (one column further from the midpoint, same row).
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 2, 2));
}

// ---------------------------------------------------------------------
// labels_edge.zig / tryWrite: inter-label separation invariant. Two
// independently-anchored label spans must never abut with zero gap (they
// fuse into one unreadable run). Only .label_char neighbours force
// separation; abutting non-label ink (edge/node/arrow) stays legal.
// Shape-generic: a pre-stamped label span forces the edge label off its
// abutting primary anchor onto a separated slot.
// ---------------------------------------------------------------------
test "tryWrite requires a blank column between abutting label spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 6);
    // Horizontal segment: primary anchor lands the single-char label at the
    // midpoint (x=3) one row above (y=2), same geometry as "edge label fits
    // above midpoint".
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(12, 6, .LR);
    s.edges = &edges;

    // Pre-stamp a label span occupying cols 0..2 on the anchor row (y=2), so
    // the cell immediately LEFT of the primary anchor (x=2) is a label_char.
    var px: u32 = 0;
    while (px < 3) : (px += 1) {
        lat.at(px, 2).* = .{ .occupant = .{ .label_char = 'Q' }, .neighbours = .{} };
    }

    const report = try labels.rasterizeLabels(alloc, &lat, s);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    // The pre-existing span's last cell (x=2) survives untouched, and the
    // primary anchor (x=3, whose LEFT flank x=2 is label_char) is rejected
    // by the guard...
    try testing.expectEqual(@as(u21, 'Q'), cellChar(lat, 2, 2));
    try testing.expectEqual(@as(u21, 0), cellChar(lat, 3, 2));
    // ...so the label lands one column further out (x=4), leaving x=3 as the
    // >=1 blank column of separation between the two spans.
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 4, 2));
}

test "tryWrite does not force separation from non-label ink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 5, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "x")};
    var s = emptySketch(12, 6, .LR);
    s.edges = &edges;

    // Pre-stamp NON-label ink at the left flank cell only (x=2, the cell
    // immediately left of the primary anchor x=3). The guard keys on
    // .label_char specifically, so this must NOT displace the label.
    lat.at(2, 2).* = .{ .occupant = .{ .node_interior = 7 }, .neighbours = .{} };

    const report = try labels.rasterizeLabels(alloc, &lat, s);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    // The label still lands at its primary anchor (x=3), abutting the
    // non-label ink — separation is only forced against other labels.
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 3, 2));
}
