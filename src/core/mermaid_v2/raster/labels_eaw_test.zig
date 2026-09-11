//! Unit tests for the East-Asian-Width label geometry: `labels.cellSpan`
//! / `prepare`'s cell count and the three writers that advance by it (node
//! label, cluster title, edge/tap label).
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
const lw = @import("labels_write.zig");

const testing = std.testing;

/// Lattice cells `text` claims, as `prepare` resolves them — the footprint
/// every writer and free-space probe reserves by.
fn cellSpanOf(text: []const u8) !u32 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var table = lw.GlyphTable.init(arena.allocator());
    const run = try lw.prepare(arena.allocator(), &table, text);
    return run.cell_count;
}

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
    var cp: u21 = 0;
    while (cp < 0x80) : (cp += 1) {
        try testing.expectEqual(@as(u32, 1), labels.cellSpan(cp));
    }
    try testing.expectEqual(@as(u32, 1), labels.cellSpan(prim.LINE_BREAK));
    try testing.expectEqual(@as(u32, 2), labels.cellSpan('日'));
}

test "a prepared label's cell count equals prim.displayWidth for tab- and control-free text" {
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
        try testing.expectEqual(prim.displayWidth(s), try cellSpanOf(s));
    }
    try testing.expectEqual(@as(u32, 4), prim.displayWidth("\t"));
    try testing.expectEqual(@as(u32, 1), try cellSpanOf("\t"));
}

test "wide node label writes char + continuation and paints two columns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 5);
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
    try testing.expectEqual(@as(u21, ' '), cellChar(lat, 7, 0));
}

test "edge-label probe reserves display cells: a wide label no longer overwrites the ink beside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

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

    var free_lat = try makeLattice(alloc, 8, 4);
    free_lat.at(2, 2).* = .{ .occupant = .{ .label_char = '日' }, .neighbours = .{} };

    const free_report = try labels.rasterizeLabels(alloc, &free_lat, s, null);
    try testing.expectEqual(@as(u32, 1), free_report.placed);
}

/// The interned grapheme a head cell refers to, or null for a scalar head.
fn glyphAt(lat: lattice.Lattice, x: u32, y: u32) ?lattice.Glyph {
    return lat.glyphOf(cellChar(lat, x, y));
}

/// One rect node (id 1) with the given label lines, as a one-element
/// array the sketch can borrow.
fn nodeSketch(rect: sketch.Rect, lines: []const []const u8) struct { nodes: [1]sketch.NodePlacement } {
    return .{ .nodes = .{.{
        .id = 1,
        .rect = rect,
        .shape = .rect,
        .lines = lines,
        .cluster_id = null,
    }} };
}

test "a prepared label counts graphemes: a combining mark claims no cell, an emoji sequence claims two" {
    try testing.expectEqual(@as(u32, 4), try cellSpanOf("cafe\u{0301}"));
    try testing.expectEqual(@as(u32, 2), try cellSpanOf("\u{1F680}"));
    try testing.expectEqual(@as(u32, 2), try cellSpanOf("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"));
    try testing.expectEqual(@as(u32, 2), try cellSpanOf("\u{1F1EF}\u{1F1F5}"));
    try testing.expectEqual(@as(u32, 2), try cellSpanOf("\u{2764}\u{FE0F}"));
    try testing.expectEqual(@as(u32, 1), try cellSpanOf("\u{2764}"));
    for ([_][]const u8{ "\u{1F680} Launch", "\u{2705} Done", "cafe\u{0301}", "nai\u{0308}ve", "\u{1F44D}\u{1F3FD} OK" }) |s| {
        try testing.expectEqual(prim.displayWidth(s), try cellSpanOf(s));
    }
    // Text the strict measure rejects (a malformed byte) is counted per
    // codepoint, one cell per bad byte — exactly as prim.displayWidth does.
    try testing.expectEqual(prim.displayWidth("a\xffb"), try cellSpanOf("a\xffb"));
    try testing.expectEqual(@as(u32, 3), try cellSpanOf("a\xffb"));
}

test "emoji node label writes head + continuation and is charged two columns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 5);
    const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = 8, .h = 3 };
    fillNodeInterior(&lat, rect, 1);
    const fixture = nodeSketch(rect, &.{"\u{1F680} Go"});
    var s = emptySketch(12, 5, .TD);
    s.nodes = &fixture.nodes;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);
    try testing.expectEqual(@as(usize, 0), report.diagnostics.len);

    // inner width 6, label 5 columns: pad 0, so the rocket heads cell 1.
    try testing.expectEqual(@as(u21, 0x1F680), cellChar(lat, 1, 1));
    try testing.expect(isCont(lat, 2, 1));
    try testing.expectEqual(@as(u21, ' '), cellChar(lat, 3, 1));
    try testing.expectEqual(@as(u21, 'G'), cellChar(lat, 4, 1));
    try testing.expectEqual(@as(u21, 'o'), cellChar(lat, 5, 1));
    // A single-codepoint grapheme is stored as the scalar: no table entry.
    try testing.expectEqual(@as(usize, 0), lat.glyphs.len);
    // The head is charged two columns, as the painter will paint it
    // (paint.zig "paint: a wide label glyph plus its continuation paints two columns from two cells").
    try testing.expectEqual(@as(u32, 2), prim.codepointWidth(cellChar(lat, 1, 1)));
}

test "a decomposed accent occupies one cell per grapheme and interns base plus mark" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 8, 3);
    const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = 6, .h = 3 };
    fillNodeInterior(&lat, rect, 1);
    const fixture = nodeSketch(rect, &.{"cafe\u{0301}"});
    var s = emptySketch(8, 3, .TD);
    s.nodes = &fixture.nodes;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);

    // Four cells: c a f é — the accent rides the e, claiming no cell.
    try testing.expectEqual(@as(u21, 'c'), cellChar(lat, 1, 1));
    try testing.expectEqual(@as(u21, 'a'), cellChar(lat, 2, 1));
    try testing.expectEqual(@as(u21, 'f'), cellChar(lat, 3, 1));
    try testing.expect(lattice.isGlyphRef(cellChar(lat, 4, 1)));
    try testing.expect(!isCont(lat, 5, 1));
    const glyph = glyphAt(lat, 4, 1).?;
    try testing.expectEqualStrings("e\u{0301}", glyph.bytes);
    try testing.expectEqual(@as(u8, 1), glyph.width);
}

test "a ZWJ family occupies two cells: head reference plus continuation, every byte interned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    var lat = try makeLattice(alloc, 10, 3);
    const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = 6, .h = 3 };
    fillNodeInterior(&lat, rect, 1);
    const fixture = nodeSketch(rect, &.{family ++ " x"});
    var s = emptySketch(10, 3, .TD);
    s.nodes = &fixture.nodes;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);

    try testing.expect(lattice.isGlyphRef(cellChar(lat, 1, 1)));
    try testing.expect(isCont(lat, 2, 1));
    try testing.expectEqual(@as(u21, ' '), cellChar(lat, 3, 1));
    try testing.expectEqual(@as(u21, 'x'), cellChar(lat, 4, 1));
    const glyph = glyphAt(lat, 1, 1).?;
    try testing.expectEqualStrings(family, glyph.bytes);
    try testing.expectEqual(@as(u8, 2), glyph.width);
}

test "an edge label with a flag reserves two cells for it and paints the pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lat = try makeLattice(alloc, 12, 6);
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 9, .y = 3 } };
    const edges = [_]sketch.EdgePath{makeEdge(42, &poly, "\u{1F1EF}\u{1F1F5} JP")};
    var s = emptySketch(12, 6, .LR);
    s.edges = &edges;

    const report = try labels.rasterizeLabels(alloc, &lat, s, null);
    try testing.expectEqual(@as(u32, 1), report.placed);

    var found = false;
    var x: u32 = 0;
    while (x + 4 < lat.width) : (x += 1) {
        if (glyphAt(lat, x, 2)) |glyph| {
            try testing.expectEqualStrings("\u{1F1EF}\u{1F1F5}", glyph.bytes);
            try testing.expect(isCont(lat, x + 1, 2));
            try testing.expectEqual(@as(u21, ' '), cellChar(lat, x + 2, 2));
            try testing.expectEqual(@as(u21, 'J'), cellChar(lat, x + 3, 2));
            found = true;
        }
    }
    try testing.expect(found);
}

test "the interned table copies grapheme bytes: the label string may die before the lattice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The label lives in its own buffer, scribbled over after the write.
    var label_buf: [8]u8 = undefined;
    @memcpy(label_buf[0..5], "e\u{0301}ab");
    const label: []const u8 = label_buf[0..5];

    var lat = try makeLattice(alloc, 8, 3);
    const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = 6, .h = 3 };
    fillNodeInterior(&lat, rect, 1);
    const fixture = nodeSketch(rect, &.{label});
    var s = emptySketch(8, 3, .TD);
    s.nodes = &fixture.nodes;
    _ = try labels.rasterizeLabels(alloc, &lat, s, null);

    @memset(&label_buf, '?');
    const glyph = glyphAt(lat, 1, 1).?;
    try testing.expectEqualStrings("e\u{0301}", glyph.bytes);
    try testing.expect(glyph.bytes.ptr != label.ptr);
}

test "an edge label with a decomposed accent and a line break claims the same cells as one without" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The sentinel is a control; it must not push the whole label onto a
    // per-codepoint walk that would give the combining mark its own cell.
    const with_break = "e\u{0301}" ++ [_]u8{prim.LINE_BREAK} ++ "x";
    const plain = "e\u{0301} x";
    try testing.expectEqual(try cellSpanOf(plain), try cellSpanOf(with_break));
    try testing.expectEqual(prim.displayWidth(with_break), try cellSpanOf(with_break));

    var lats: [2]lattice.Lattice = .{ try makeLattice(alloc, 12, 6), try makeLattice(alloc, 12, 6) };
    const poly = [_]sketch.Point{ .{ .x = 1, .y = 3 }, .{ .x = 9, .y = 3 } };
    for ([_][]const u8{ with_break, plain }, 0..) |label, i| {
        const edges = [_]sketch.EdgePath{makeEdge(42, &poly, label)};
        var s = emptySketch(12, 6, .LR);
        s.edges = &edges;
        const report = try labels.rasterizeLabels(alloc, &lats[i], s, null);
        try testing.expectEqual(@as(u32, 1), report.placed);
    }
    try testing.expectEqualSlices(lattice.Cell, lats[1].cells, lats[0].cells);

    var found = false;
    var x: u32 = 0;
    while (x + 2 < lats[0].width) : (x += 1) {
        if (glyphAt(lats[0], x, 2)) |glyph| {
            try testing.expectEqualStrings("e\u{0301}", glyph.bytes);
            try testing.expectEqual(@as(u21, ' '), cellChar(lats[0], x + 1, 2));
            try testing.expectEqual(@as(u21, 'x'), cellChar(lats[0], x + 2, 2));
            found = true;
        }
    }
    try testing.expect(found);
}
