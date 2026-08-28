//! Unit tests for raster/edges_write.zig — the cell-writer contract at the
//! `cluster_border` occupant (frame-solid ruling, terminal-arrival half).
//! Through-going bridging lives in the caller (`walkPolyline`) and is pinned
//! in edges_test.zig; here we pin the writer-level behaviors those callers
//! rely on: a TERMINAL segment cell and an ARROWHEAD still land on a border.
//! The PORT-STROKE half (`drawPortStroke`/`drawTargetPortStroke`, the facing
//! rule, the gap probe and its painted approach) lives in the sibling
//! `edges_port_test.zig` — split for the 500-line cap.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ew = @import("edges_write.zig");
const aux = @import("aux.zig");
const crossings = @import("crossings.zig");

const testing = std.testing;

fn borderCell(mask: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } },
        .neighbours = mask,
    };
}

test "writeEdgeCell: a terminal segment cell onto a cluster_border merges (today's behavior)" {
    // A polyline that TERMINATES on the frame keeps the pre-ruling merge: the
    // caller reaches writeEdgeCell only for the final cell, and here the border
    // is overwritten as an edge_segment with OR-merged bits. (Through-going
    // cells never reach this arm — the caller bridges them.)
    var cell = borderCell(.{ .e = true, .w = true }); // horizontal frame run
    var lost: u32 = 0;
    ew.writeEdgeCell(&cell, 7, .solid, .forward, .{ .n = true, .s = true }, 3, 3, &lost, .merged_untested, .{});
    try testing.expectEqual(@as(u32, 0), lost);
    try testing.expect(switch (cell.occupant) {
        .edge_segment => |seg| seg.edge == 7,
        else => false,
    });
    // Frame bits fused with the arriving vertical arms → a ┼-class mask.
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
}

test "writeArrowCell: an arrowhead may stamp onto a cluster_border (arrival AT the cluster)" {
    var cell = borderCell(.{ .e = true, .w = true });
    var lost: u32 = 0;
    ew.writeArrowCell(&cell, 7, .solid, .filled, .south, .{ .n = true, .s = true }, 3, 3, &lost, .merged_untested, .{});
    try testing.expectEqual(@as(u32, 0), lost);
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 7,
        else => false,
    });
}

test "writeArrowCell stamps the edge's own stroke_kind" {
    // An arrowhead landing on a FOREIGN edge's run must carry ITS OWN stroke,
    // not the foreign run's. Pre-seed a solid edge_segment (stroke .solid),
    // then land a dotted-edge arrowhead: the cell's stroke becomes .dotted.
    var cell: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .solid,
    };
    var lost: u32 = 0;
    ew.writeArrowCell(&cell, 9, .dotted, .filled, .east, .{ .e = true, .w = true }, 1, 1, &lost, .merged_foreign, .{});
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.edge == 9,
        else => false,
    });
    try testing.expectEqual(lattice.EdgeKind.dotted, cell.stroke_kind);
}

test "writeArrowCell on an empty cell stamps stroke_kind" {
    // Regression pin: the .empty arm also stamps, so a lone arrowhead cell's
    // stroke agrees with its edge kind.
    var cell = lattice.Cell.empty;
    var lost: u32 = 0;
    ew.writeArrowCell(&cell, 4, .thick, .filled, .south, .{ .n = true, .s = true }, 0, 0, &lost, .merged_untested, .{});
    try testing.expectEqual(lattice.EdgeKind.thick, cell.stroke_kind);
}

test "writeArrowCell records the declared head style on the cell" {
    // The head style travels from the sketch edge to the cell; both writers
    // must carry it, including the pristine refuse branch of the guarded one.
    var plain = lattice.Cell.empty;
    var lost: u32 = 0;
    ew.writeArrowCell(&plain, 1, .solid, .open, .south, .{ .n = true }, 0, 0, &lost, .merged_untested, .{});
    try testing.expectEqual(lattice.ArrowKind.open, plain.occupant.arrowhead.arrow);

    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };
    var refused: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 2, .kind = .solid, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
    };
    ew.writeArrowGuarded(&refused, 6, .solid, .cross, .east, .{ .e = true }, 1, 1, &lost, ctx, .{});
    try testing.expectEqual(lattice.ArrowKind.cross, refused.occupant.arrowhead.arrow);
}

test "writeArrowGuarded refuse branch stamps the arrowhead's own stroke_kind" {
    // Active crossing rule + a FOREIGN edge under the cell → the refuse branch
    // lays a pristine arrowhead. Its stroke must be the incoming edge's OWN
    // kind (.solid), never the foreign run's (.thick).
    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };
    var cell: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 2, .kind = .thick, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .thick,
    };
    var lost: u32 = 0;
    ew.writeArrowGuarded(&cell, 5, .solid, .filled, .east, .{ .e = true, .w = true }, 1, 1, &lost, ctx, .{});
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.edge == 5,
        else => false,
    });
    // Pristine bits (no foreign junction) and own stroke.
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
    try testing.expectEqual(lattice.EdgeKind.solid, cell.stroke_kind);
    try testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
}

test "directional primitives round-trip (straightMask/bitMask/reverse)" {
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        ew.straightMask(.north).toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        ew.straightMask(.east).toMask(),
    );
    try testing.expectEqual(ew.Move.south, ew.reverse(.north));
    try testing.expectEqual(
        (lattice.Neighbours{ .w = true }).toMask(),
        ew.bitMask(.west).toMask(),
    );
}

/// A 4x4 blank lattice plus a recorder writing into `c`.
fn recorderOn(a: std.mem.Allocator, lat: *lattice.Lattice, c: *aux.Collector) !aux.Recorder {
    const cells = try a.alloc(lattice.Cell, 16);
    for (cells) |*cc| cc.* = lattice.Cell.empty;
    lat.* = .{ .width = 4, .height = 4, .cells = cells };
    return aux.Recorder.init(c, lat);
}

test "writeEdgeCell files the merged carrier under the licence its caller established" {
    // The writer holds a `*Cell` and no channel context, so it cannot ask.
    // Whatever the caller established is what the record states — and the
    // painted cell is identical either way, which is what makes filling
    // this byte render-neutral by construction.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([3]lattice.CarrierKind{ .merged_licensed, .merged_foreign, .merged_untested }) |want| {
        var lat: lattice.Lattice = undefined;
        var col = aux.Collector.init(a);
        const rec = try recorderOn(a, &lat, &col);
        var lost: u32 = 0;
        var cell: lattice.Cell = .{
            .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
            .neighbours = .{ .e = true, .w = true },
        };
        ew.writeEdgeCell(&cell, 8, .solid, .forward, .{ .n = true, .s = true }, 1, 1, &lost, want, rec);

        const table = col.finish();
        try testing.expectEqual(@as(usize, 1), table.len);
        try testing.expectEqual(@as(u32, 8), table[0].value);
        try testing.expectEqual(@intFromEnum(want), table[0].detail);
        try testing.expectEqual(@as(u32, 3), cell.occupant.edge_segment.edge);
        try testing.expectEqual(
            (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
            cell.neighbours.toMask(),
        );
    }
}

test "an arrowhead landing on a foreign arrowhead files a foreign carrier" {
    // The C2 gate only examines an `.edge_segment` occupant, so an
    // arrowhead-over-arrowhead reaches `writeArrowCell` with the channel
    // question never put. `writeArrowGuarded` puts it there instead — for
    // the record only: the cell keeps the first head, exactly as before.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const CoSet = @typeInfo(@TypeOf((crossings.Ctx{ .counts = undefined }).co_sets)).pointer.child;
    const members = [_]u32{ 4, 9 };
    // Stamped, as a producer stamps: the licence is read off the recorded
    // channel identity, and an unstamped roster records none.
    const mates = [_]CoSet{.{ .origin = .fan_rail, .channel = 1, .members = &members }};

    for ([2]lattice.CarrierKind{ .merged_foreign, .merged_licensed }) |want| {
        var lat: lattice.Lattice = undefined;
        var col = aux.Collector.init(a);
        const rec = try recorderOn(a, &lat, &col);
        var counts: crossings.CrossingCounts = .{};
        var ctx: crossings.Ctx = .{ .counts = &counts, .stamp_state = .complete };
        if (want == .merged_licensed) ctx.co_sets = &mates;

        var cell: lattice.Cell = .{
            .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 4, .arrow = .filled } },
            .neighbours = .{ .n = true },
        };
        var lost: u32 = 0;
        ew.writeArrowGuarded(&cell, 9, .solid, .filled, .east, .{ .e = true }, 2, 2, &lost, ctx, rec);

        const table = col.finish();
        try testing.expectEqual(@as(usize, 1), table.len);
        try testing.expectEqual(@as(u32, 9), table[0].value);
        try testing.expectEqual(@intFromEnum(want), table[0].detail);
        // Asking cost nothing: the first head still owns the cell and the
        // C2 tally never moved.
        try testing.expectEqual(@as(u32, 4), cell.occupant.arrowhead.edge);
        try testing.expectEqual(@as(u32, 0), counts.arrowhead_transit_violation);
    }
}

test "writeEdgeCell files NO carrier on an unowned cell, whatever licence it is handed" {
    // THE INERTNESS THE PLACEHOLDER LICENCES REST ON. Two producers hand
    // this writer a licence they cannot compute — `rails.licenceAt`'s
    // `else` arm (the cell names nobody) and `edges_port.zig`'s gap-cell
    // write — and both pass `.merged_untested` with a comment saying the
    // value cannot matter because the arm files no carrier at all.
    //
    // That is a claim about THIS function, so it is pinned here rather than
    // asserted there. If a future edit starts filing a carrier on an
    // `.empty` or `.cluster_border` cell, this goes red and whoever made it
    // must go and give those two producers a real answer — instead of
    // silently publishing a licence nobody asked for. `.merged_licensed` is
    // passed deliberately: it is the one value that would be a lie.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([2]lattice.Cell{
        lattice.Cell.empty,
        borderCell(.{ .e = true, .w = true }),
    }) |proto| {
        var lat: lattice.Lattice = undefined;
        var col = aux.Collector.init(a);
        const rec = try recorderOn(a, &lat, &col);
        var cell = proto;
        var lost: u32 = 0;
        ew.writeEdgeCell(&cell, 5, .solid, .forward, .{ .n = true, .s = true }, 1, 1, &lost, .merged_licensed, rec);

        try testing.expectEqual(@as(usize, 0), col.finish().len);
        try testing.expectEqual(@as(u32, 0), lost);
        // The cell was still WRITTEN — the arm is live, it just has no
        // second id to be anonymous about, which is exactly why no record.
        try testing.expectEqual(@as(u32, 5), cell.occupant.edge_segment.edge);
    }
}
