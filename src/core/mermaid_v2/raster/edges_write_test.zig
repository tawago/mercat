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
    var cell = borderCell(.{ .e = true, .w = true });
    var lost: u32 = 0;
    var cc: crossings.CrossingCounts = .{};
    ew.writeEdgeCell(&cell, 7, .solid, .forward, .{ .n = true, .s = true }, 3, 3, &lost, &cc, .merged_untested, .{});
    try testing.expectEqual(@as(u32, 0), lost);
    try testing.expect(switch (cell.occupant) {
        .edge_segment => |seg| seg.edge == 7,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
}

test "writeArrowCell: an arrowhead may stamp onto a cluster_border (arrival AT the cluster)" {
    var cell = borderCell(.{ .e = true, .w = true });
    var lost: u32 = 0;
    var cc: crossings.CrossingCounts = .{};
    var hlost: u32 = 0;
    ew.writeArrowCell(&cell, 7, .solid, .filled, .south, .{ .n = true, .s = true }, 3, 3, &lost, &hlost, &cc, .merged_untested, .{});
    try testing.expectEqual(@as(u32, 0), lost);
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 7,
        else => false,
    });
}

test "writeArrowCell stamps the edge's own stroke_kind" {
    var cell: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .solid,
    };
    var lost: u32 = 0;
    var cc: crossings.CrossingCounts = .{};
    var hlost: u32 = 0;
    ew.writeArrowCell(&cell, 9, .dotted, .filled, .east, .{ .e = true, .w = true }, 1, 1, &lost, &hlost, &cc, .merged_foreign, .{});
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.edge == 9,
        else => false,
    });
    try testing.expectEqual(lattice.EdgeKind.dotted, cell.stroke_kind);
}

test "writeArrowCell on an empty cell stamps stroke_kind" {
    var cell = lattice.Cell.empty;
    var lost: u32 = 0;
    var cc: crossings.CrossingCounts = .{};
    var hlost: u32 = 0;
    ew.writeArrowCell(&cell, 4, .thick, .filled, .south, .{ .n = true, .s = true }, 0, 0, &lost, &hlost, &cc, .merged_untested, .{});
    try testing.expectEqual(lattice.EdgeKind.thick, cell.stroke_kind);
}

test "writeArrowCell records the declared head style on the cell" {
    var plain = lattice.Cell.empty;
    var lost: u32 = 0;
    var cc: crossings.CrossingCounts = .{};
    var hlost: u32 = 0;
    ew.writeArrowCell(&plain, 1, .solid, .open, .south, .{ .n = true }, 0, 0, &lost, &hlost, &cc, .merged_untested, .{});
    try testing.expectEqual(lattice.ArrowKind.open, plain.occupant.arrowhead.arrow);

    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };
    var refused: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 2, .kind = .solid, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
    };
    ew.writeArrowGuarded(&refused, 6, .solid, .cross, .east, .{ .e = true }, 1, 1, &lost, &hlost, ctx, .{});
    try testing.expectEqual(lattice.ArrowKind.cross, refused.occupant.arrowhead.arrow);
}

test "writeArrowGuarded refuse branch stamps the arrowhead's own stroke_kind" {
    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };
    var cell: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 2, .kind = .thick, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .thick,
    };
    var lost: u32 = 0;
    var hlost: u32 = 0;
    ew.writeArrowGuarded(&cell, 5, .solid, .filled, .east, .{ .e = true, .w = true }, 1, 1, &lost, &hlost, ctx, .{});
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.edge == 5,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
    try testing.expectEqual(lattice.EdgeKind.solid, cell.stroke_kind);
    try testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
}

test "a head refused at a node/label collision counts BOTH cells_lost and heads_lost" {
    var border: lattice.Cell = .{
        .occupant = .{ .node_border = .{ .node = 3, .role = .edge_s } },
        .neighbours = .{},
    };
    var lost: u32 = 0;
    var cc: crossings.CrossingCounts = .{};
    var hlost: u32 = 0;
    ew.writeArrowCell(&border, 7, .solid, .filled, .south, .{ .n = true, .s = true }, 0, 0, &lost, &hlost, &cc, .merged_untested, .{});
    try testing.expectEqual(@as(u32, 1), lost);
    try testing.expectEqual(@as(u32, 1), hlost);
    try testing.expect(border.occupant == .node_border);

    var border2: lattice.Cell = .{
        .occupant = .{ .node_border = .{ .node = 3, .role = .edge_s } },
        .neighbours = .{},
    };
    ew.writeEdgeCell(&border2, 7, .solid, .forward, .{ .n = true, .s = true }, 0, 0, &lost, &cc, .merged_untested, .{});
    try testing.expectEqual(@as(u32, 2), lost);
    try testing.expectEqual(@as(u32, 1), hlost);
}

test "writers record the ink-attribution state at the decision (cell-grid boundary)" {
    var fresh = lattice.Cell.empty;
    var lost: u32 = 0;
    var cc: crossings.CrossingCounts = .{};
    ew.writeEdgeCell(&fresh, 1, .solid, .forward, .{ .n = true, .s = true }, 0, 0, &lost, &cc, .merged_untested, .{});
    try testing.expectEqual(lattice.InkState.stroke, fresh.state);
    var rail = lattice.Cell.empty;
    ew.writeEdgeCell(&rail, 1, .solid, .fan_out_rail, .{ .e = true, .w = true }, 0, 0, &lost, &cc, .merged_untested, .{});
    try testing.expectEqual(lattice.InkState.rail_interior, rail.state);

    ew.writeEdgeCell(&rail, 2, .solid, .fan_out_dropper, .{ .s = true }, 0, 0, &lost, &cc, .merged_licensed, .{});
    try testing.expectEqual(lattice.InkState.junction, rail.state);

    var run = lattice.Cell.empty;
    ew.writeEdgeCell(&run, 1, .solid, .forward, .{ .e = true, .w = true }, 0, 0, &lost, &cc, .merged_untested, .{});
    ew.writeEdgeCell(&run, 2, .solid, .forward, .{ .e = true, .w = true }, 0, 0, &lost, &cc, .merged_licensed, .{});
    try testing.expectEqual(lattice.InkState.rail_interior, run.state);

    var crossed: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
        .state = .stroke,
    };
    var hlost: u32 = 0;
    const ctx: crossings.Ctx = .{ .counts = &cc };
    ew.writeArrowGuarded(&crossed, 9, .solid, .filled, .south, .{ .n = true, .s = true }, 1, 1, &lost, &hlost, ctx, .{});
    try testing.expectEqual(lattice.InkState.crossing, crossed.state);
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([3]lattice.CarrierKind{ .merged_licensed, .merged_foreign, .merged_untested }) |want| {
        var lat: lattice.Lattice = undefined;
        var col = aux.Collector.init(a);
        const rec = try recorderOn(a, &lat, &col);
        var lost: u32 = 0;
        var cc: crossings.CrossingCounts = .{};
        var cell: lattice.Cell = .{
            .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
            .neighbours = .{ .e = true, .w = true },
        };
        ew.writeEdgeCell(&cell, 8, .solid, .forward, .{ .n = true, .s = true }, 1, 1, &lost, &cc, want, rec);

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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Bundle = @typeInfo(@TypeOf((crossings.Ctx{ .counts = undefined }).bundle_sets)).pointer.child;
    const members = [_]u32{ 4, 9 };
    const mates = [_]Bundle{.{ .origin = .fan_rail, .bundle = 1, .members = &members }};

    for ([2]lattice.CarrierKind{ .merged_foreign, .merged_licensed }) |want| {
        var lat: lattice.Lattice = undefined;
        var col = aux.Collector.init(a);
        const rec = try recorderOn(a, &lat, &col);
        var counts: crossings.CrossingCounts = .{};
        var ctx: crossings.Ctx = .{ .counts = &counts, .stamp_state = .complete };
        if (want == .merged_licensed) ctx.bundle_sets = &mates;

        var cell: lattice.Cell = .{
            .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 4, .arrow = .filled } },
            .neighbours = .{ .n = true, .s = true },
        };
        var lost: u32 = 0;
        var hlost: u32 = 0;
        ew.writeArrowGuarded(&cell, 9, .solid, .filled, .south, .{ .n = true, .s = true }, 2, 2, &lost, &hlost, ctx, rec);

        const table = col.finish();
        try testing.expectEqual(@as(usize, 1), table.len);
        try testing.expectEqual(@as(u32, 9), table[0].value);
        try testing.expectEqual(@intFromEnum(want), table[0].detail);
        try testing.expectEqual(@as(u32, 4), cell.occupant.arrowhead.edge);
        try testing.expectEqual(@as(u32, 0), counts.arrowhead_transit_violation);
        try testing.expectEqual(@as(u32, 0), counts.arm_into_head);
        try testing.expectEqual(@as(u32, 0), hlost);
    }
}

fn southHead(edge: u32) lattice.Cell {
    return .{
        .occupant = .{ .arrowhead = .{ .dir = .south, .edge = edge, .arrow = .filled } },
        .neighbours = .{ .n = true, .s = true },
        .state = .stroke,
    };
}

test "a foreign lateral arm into a head is refused and counted against the writer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([2]lattice.CarrierKind{ .merged_licensed, .merged_foreign }) |licence| {
        var lat: lattice.Lattice = undefined;
        var col = aux.Collector.init(a);
        const rec = try recorderOn(a, &lat, &col);
        var lost: u32 = 0;
        var cc: crossings.CrossingCounts = .{};
        var cell = southHead(4);
        ew.writeEdgeCell(&cell, 9, .solid, .forward, .{ .n = true, .e = true }, 1, 1, &lost, &cc, licence, rec);

        try testing.expectEqual(@as(u32, 4), cell.occupant.arrowhead.edge);
        try testing.expectEqual((lattice.Neighbours{ .n = true, .s = true }).toMask(), cell.neighbours.toMask());
        try testing.expectEqual(lattice.InkState.stroke, cell.state);
        try testing.expectEqual(@as(u32, 1), lost);
        try testing.expectEqual(@as(u32, 1), cc.arm_into_head);
        try testing.expectEqual(@as(u32, 0), cc.arrowhead_transit_violation);
        const table = col.finish();
        try testing.expectEqual(@as(usize, 1), table.len);
        try testing.expectEqual(@as(u32, 9), table[0].value);
        try testing.expectEqual(@intFromEnum(lattice.CarrierKind.suppressed), table[0].detail);
    }

    var lost: u32 = 0;
    var cc: crossings.CrossingCounts = .{};
    var through = southHead(4);
    ew.writeEdgeCell(&through, 9, .solid, .forward, .{ .e = true, .w = true }, 1, 1, &lost, &cc, .merged_licensed, .{});
    try testing.expectEqual(@as(u32, 2), cc.arm_into_head);
    try testing.expectEqual((lattice.Neighbours{ .n = true, .s = true }).toMask(), through.neighbours.toMask());
}

test "a co-member riding a head's axis keeps the rail-interior residue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lat: lattice.Lattice = undefined;
    var col = aux.Collector.init(a);
    const rec = try recorderOn(a, &lat, &col);
    var lost: u32 = 0;
    var cc: crossings.CrossingCounts = .{};
    var cell = southHead(4);
    ew.writeEdgeCell(&cell, 9, .solid, .fan_in_dropper, .{ .n = true, .s = true }, 1, 1, &lost, &cc, .merged_licensed, rec);

    try testing.expectEqual(@as(u32, 4), cell.occupant.arrowhead.edge);
    try testing.expectEqual(lattice.InkState.rail_interior, cell.state);
    try testing.expectEqual(@as(u32, 0), lost);
    try testing.expectEqual(@as(u32, 0), cc.arm_into_head);
    const table = col.finish();
    try testing.expectEqual(@as(usize, 1), table.len);
    try testing.expectEqual(@intFromEnum(lattice.CarrierKind.merged_licensed), table[0].detail);
}

test "a foreign head pointing another way is refused; one pointing the same way rides" {
    var lost: u32 = 0;
    var hlost: u32 = 0;
    var cc: crossings.CrossingCounts = .{};

    var across = southHead(4);
    ew.writeArrowCell(&across, 9, .solid, .filled, .east, .{ .e = true, .w = true }, 1, 1, &lost, &hlost, &cc, .merged_licensed, .{});
    try testing.expectEqual(@as(u32, 4), across.occupant.arrowhead.edge);
    try testing.expectEqual(lattice.Dir4.south, across.occupant.arrowhead.dir);
    try testing.expectEqual((lattice.Neighbours{ .n = true, .s = true }).toMask(), across.neighbours.toMask());
    try testing.expectEqual(@as(u32, 1), lost);
    try testing.expectEqual(@as(u32, 1), hlost);
    try testing.expectEqual(@as(u32, 2), cc.arm_into_head);

    var opposed = southHead(4);
    ew.writeArrowCell(&opposed, 9, .solid, .filled, .north, .{ .n = true, .s = true }, 1, 1, &lost, &hlost, &cc, .merged_licensed, .{});
    try testing.expectEqual(lattice.Dir4.south, opposed.occupant.arrowhead.dir);
    try testing.expectEqual(@as(u32, 2), lost);
    try testing.expectEqual(@as(u32, 2), hlost);
    try testing.expectEqual(@as(u32, 2), cc.arm_into_head);

    var same = southHead(4);
    ew.writeArrowCell(&same, 9, .solid, .filled, .south, .{ .n = true, .s = true }, 1, 1, &lost, &hlost, &cc, .merged_licensed, .{});
    try testing.expectEqual(@as(u32, 4), same.occupant.arrowhead.edge);
    try testing.expectEqual(lattice.InkState.rail_interior, same.state);
    try testing.expectEqual(@as(u32, 2), lost);
    try testing.expectEqual(@as(u32, 2), hlost);

    var own = southHead(4);
    ew.writeArrowCell(&own, 4, .solid, .filled, .south, .{ .n = true, .s = true }, 1, 1, &lost, &hlost, &cc, .merged_untested, .{});
    try testing.expectEqual(@as(u32, 2), lost);
    try testing.expectEqual(@as(u32, 2), hlost);
}

test "writeEdgeCell files NO carrier on an unowned cell, whatever licence it is handed" {
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
        var cc: crossings.CrossingCounts = .{};
        ew.writeEdgeCell(&cell, 5, .solid, .forward, .{ .n = true, .s = true }, 1, 1, &lost, &cc, .merged_licensed, rec);

        try testing.expectEqual(@as(usize, 0), col.finish().len);
        try testing.expectEqual(@as(u32, 0), lost);
        try testing.expectEqual(@as(u32, 5), cell.occupant.edge_segment.edge);
    }
}

test "a head stamped over a co-member's run is rail-interior; over a stranger's, junction" {
    var lost: u32 = 0;
    var hlost: u32 = 0;
    var cc: crossings.CrossingCounts = .{};
    var shared: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid, .role = .forward } },
        .neighbours = .{ .n = true, .s = true },
        .state = .stroke,
    };
    ew.writeArrowCell(&shared, 9, .solid, .filled, .south, .{ .n = true, .s = true }, 1, 1, &lost, &hlost, &cc, .merged_licensed, .{});
    try testing.expectEqual(lattice.InkState.rail_interior, shared.state);
    try testing.expect(shared.occupant == .arrowhead);

    for ([_]lattice.CarrierKind{ .merged_foreign, .merged_untested }) |licence| {
        var foreign: lattice.Cell = .{
            .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid, .role = .forward } },
            .neighbours = .{ .n = true, .s = true },
            .state = .stroke,
        };
        ew.writeArrowCell(&foreign, 9, .solid, .filled, .south, .{ .n = true, .s = true }, 1, 1, &lost, &hlost, &cc, licence, .{});
        try testing.expectEqual(lattice.InkState.junction, foreign.state);
    }
}
