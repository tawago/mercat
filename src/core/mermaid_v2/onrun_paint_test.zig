//! Paint-level pin for the DECORATED on-run label column.
//!
//! The whole point of FLANKED-RESUMPTION RULE's line-glyph sandwich is what the column
//! LOOKS like: full run, text, full run, head. `raster/labels_onrun.zig`
//! never names a glyph — it only decides which cell the text may take —
//! so nothing inside the raster stage can prove the picture comes out
//! right. This pin also guards the reverted half-stroke experiment: the
//! flanks must paint as unremarkable full strokes in the edge's own kind,
//! because a taper (`╵`/`╷`) made the blind decoder read solid edges as
//! dotted ones.
//!
//! It lives at the mermaid_v2 root because it must import BOTH the raster
//! stage and the painter, which no file inside `raster/` may do (the
//! painter sits above it in the pipeline); an explicit lint row grants the
//! privilege.

const std = @import("std");
const lattice = @import("lattice.zig");
const sketch = @import("sketch.zig");
const onrun = @import("raster/labels_onrun.zig");
const lw = @import("raster/labels_write.zig");
const paint = @import("paint.zig");

const testing = std.testing;

/// A decorated fan-OUT tap dropper on column 5: shared crossbar row 1,
/// four private dropper cells rows 2..5, arrowhead row 6, landing (node
/// border) row 7. Four private cells is the decorated minimum — flank,
/// label, flank, head.
fn buildFixture(a: std.mem.Allocator, kind: lattice.EdgeKind) !lattice.Lattice {
    const w: u32 = 9;
    const h: u32 = 9;
    const cells = try a.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = w, .height = h, .cells = cells };

    lat.at(5, 1).* = .{
        .occupant = .{ .edge_segment = .{ .edge = 7, .kind = kind, .role = .fan_out_rail } },
        .neighbours = .{ .n = true, .s = true },
        .stroke_kind = kind,
    };
    for ([_]u32{ 2, 3, 4, 5 }) |y| {
        lat.at(5, y).* = .{
            .occupant = .{ .edge_segment = .{ .edge = 7, .kind = kind, .role = .fan_out_dropper } },
            .neighbours = .{ .n = true, .s = true },
            .stroke_kind = kind,
        };
    }
    lat.at(5, 6).* = .{
        .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 7 } },
        .neighbours = .{ .n = true },
    };
    return lat;
}

const the_tap: sketch.Tap = .{
    .edge = 7,
    .node = 1,
    .at = .{ .x = 5, .y = 1 },
    .landing = .{ .x = 5, .y = 7 },
    .label = "ok",
};

fn theSketch() sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 9, .h = 9 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

/// Column `x` of a painted diagram, top to bottom, one codepoint per row.
fn columnOf(a: std.mem.Allocator, painted: []const u8, x: usize) ![]u21 {
    var out: std.ArrayListUnmanaged(u21) = .empty;
    var it = std.mem.splitScalar(u8, painted, '\n');
    while (it.next()) |line| {
        var col: usize = 0;
        var view = std.unicode.Utf8View.initUnchecked(line);
        var cps = view.iterator();
        var found: u21 = ' ';
        while (cps.nextCodepoint()) |cp| {
            if (col == x) {
                found = cp;
                break;
            }
            col += 1;
        }
        try out.append(a, found);
    }
    return out.toOwnedSlice(a);
}

fn paintedColumn(a: std.mem.Allocator, kind: lattice.EdgeKind) ![]u21 {
    var lat = try buildFixture(a, kind);
    const s = theSketch();
    const taps = [_]sketch.Tap{the_tap};
    const rails = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &[_]sketch.Point{ .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 1 } },
        .crossbar = .{ .{ .x = 2, .y = 1 }, .{ .x = 8, .y = 1 } },
        .taps = &taps,
        .kind = kind,
        .role = .fan_out_dropper,
    }};
    var s2 = s;
    s2.rails = &rails;

    try testing.expect(onrun.tryOnRunTap(&lat, s2, taps[0], lw.asciiRun("ok"), null));

    const painted = try paint.paint(a, lat, 0);
    return columnOf(a, painted, 5);
}

test "paint: a decorated on-run label reads │ label │ ▼ down its own column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const col = try paintedColumn(a, .solid);

    try testing.expectEqual(@as(u21, '│'), col[2]);
    try testing.expectEqual(@as(u21, '│'), col[3]);
    try testing.expectEqual(@as(u21, 'o'), col[4]);
    try testing.expectEqual(@as(u21, '│'), col[5]);
    try testing.expectEqual(@as(u21, '▼'), col[6]);
}

test "paint: a dotted or thick run keeps its own stroke on BOTH sides of the label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dotted = try paintedColumn(a, .dotted);
    for ([_]usize{ 2, 3, 5 }) |row| {
        try testing.expectEqual(@as(u21, '┊'), dotted[row]);
    }

    const thick = try paintedColumn(a, .thick);
    for ([_]usize{ 2, 3, 5 }) |row| {
        try testing.expectEqual(@as(u21, '║'), thick[row]);
    }
}
