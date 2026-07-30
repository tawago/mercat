//! Unit tests for `tiling/fanrole.zig` — the fan-role shadow comparator.
//!
//! Two halves. First a MATCHING fixture: a hand-built post-stamping scene
//! where the producers' records and the stamped roles/masks agree on every
//! judged cell, so the comparator reports zero mismatches while plainly
//! doing work. Then one fixture per way the two readings can diverge, each
//! seeded with exactly one divergence, proving the comparator can fire on
//! that axis and does not fire on the others.

const std = @import("std");
const lattice = @import("../lattice.zig");
const sketch = @import("../sketch.zig");
const fanrole = @import("fanrole.zig");

const testing = std.testing;

const W: u32 = 9;
const H: u32 = 7;

fn blank() [W * H]lattice.Cell {
    var buf: [W * H]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    return buf;
}

fn idx(x: u32, y: u32) u32 {
    return y * W + x;
}

fn seg(edge: u32, role: lattice.EdgeRole, nb: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .edge_segment = .{ .edge = edge, .kind = .solid, .role = role } },
        .neighbours = nb,
    };
}

fn member(x: u32, y: u32, edge: u32, p: lattice.RailPolarity) lattice.Aux {
    return .{ .cell = idx(x, y), .value = edge, .kind = .rail_member, .detail = @intFromEnum(p) };
}

fn tap(x: u32, y: u32, edge: u32, p: lattice.RailPolarity) lattice.Aux {
    return .{ .cell = idx(x, y), .value = edge, .kind = .tap, .detail = @intFromEnum(p) };
}

/// The side table as the raster hands it over: sorted by (cell, kind, value).
fn table(rows: []lattice.Aux) []const lattice.Aux {
    std.mem.sort(lattice.Aux, rows, {}, lattice.Aux.lessThan);
    return rows;
}

fn node(id: u32, x: i32, y: i32, w: u32, h: u32) sketch.NodePlacement {
    return .{ .id = id, .rect = .{ .x = x, .y = y, .w = w, .h = h }, .shape = .rect, .lines = &.{}, .cluster_id = null };
}

fn fanEdge(id: u32, from: u32, to: u32, role: lattice.EdgeRole) sketch.EdgePath {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .polyline = &.{},
        .port_from = .{ .node = from, .side = .south, .offset = 0 },
        .port_to = .{ .node = to, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
        .role = role,
    };
}

fn sketchOf(
    nodes: []const sketch.NodePlacement,
    edges: []const sketch.EdgePath,
    rails: []const sketch.Rail,
) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = W, .h = H },
        .direction = .TD,
        .nodes = nodes,
        .clusters = &.{},
        .edges = edges,
        .busbars = rails,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn latOf(cells: []lattice.Cell, aux: []const lattice.Aux) lattice.Lattice {
    return .{ .width = W, .height = H, .cells = cells, .aux = aux };
}

// -- The matching scene -------------------------------------------------
//
// A peer-drawn fan-OUT from pivot node 1 (rows 0..2) onto a shared run at
// row 3, and a peer-drawn fan-IN arriving at pivot node 4 (rows 5..6) on a
// shared run at row 4. Both shared-run cells are stamped, both carry the
// members the Cell cannot name, and the fan-OUT cell's spurious southern
// arm has already been stripped — exactly what the producers imply.

// Container scope, so the slices the Sketch hands out point at static data
// rather than at a helper's dead stack frame.
const matching_nodes = [_]sketch.NodePlacement{
    node(1, 3, 0, 3, 3),
    node(4, 3, 5, 3, 2),
};
const matching_edges = [_]sketch.EdgePath{
    fanEdge(20, 1, 2, .fan_out_dropper),
    fanEdge(21, 1, 3, .fan_out_dropper),
    fanEdge(30, 5, 4, .fan_in_dropper),
};

fn matchingSketch() sketch.Sketch {
    return sketchOf(&matching_nodes, &matching_edges, &.{});
}

test "matching fixture: records and stamped roles agree on every judged cell" {
    var cells = blank();
    // Fan-OUT shared run at (4,3): the trunk arrives from the pivot above,
    // spreads east and west; the centre child's descent was stripped.
    cells[idx(4, 3)] = seg(20, .fan_out_rail, .{ .n = true, .e = true, .w = true });
    // A dropper on the same run: one member only, so nothing is recorded
    // there and nothing is stamped.
    cells[idx(2, 3)] = seg(20, .fan_out_dropper, .{ .e = true, .s = true });
    // Fan-IN shared run at (4,4): keeps all four arms by law.
    cells[idx(4, 4)] = seg(30, .fan_in_rail, .{ .n = true, .e = true, .s = true, .w = true });

    var rows = [_]lattice.Aux{
        member(4, 3, 21, .out),
        member(4, 4, 31, .in),
    };
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });

    try testing.expectEqual(@as(u32, 0), c.mismatchTotal());
    // ... and it did do work: a vacuous comparison would also report zero.
    try testing.expectEqual(@as(u32, 2), c.cells_judged);
    try testing.expectEqual(@as(u32, 1), c.fan_out.role_match);
    try testing.expectEqual(@as(u32, 1), c.fan_out.mask_match);
    try testing.expectEqual(@as(u32, 1), c.fan_in.role_match);
    try testing.expectEqual(@as(u32, 1), c.fan_in.mask_match);
    try testing.expectEqual(@as(u32, 0), c.fan_out.pivot_unresolved);
}

test "run leaves the lattice byte-identical" {
    var cells = blank();
    cells[idx(4, 3)] = seg(20, .fan_out_rail, .{ .n = true, .e = true, .w = true });
    cells[idx(4, 4)] = seg(30, .fan_in_rail, .{ .n = true, .e = true, .s = true, .w = true });
    var rows = [_]lattice.Aux{ member(4, 3, 21, .out), member(4, 4, 31, .in) };
    const lat = latOf(&cells, table(&rows));

    const before = try testing.allocator.dupe(lattice.Cell, lat.cells);
    defer testing.allocator.free(before);

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqualSlices(lattice.Cell, before, lat.cells);
    try testing.expectEqual(@as(u32, 2), c.cells_judged);
}

// -- One divergence per fixture -----------------------------------------

test "mismatch: a recorded shared run the stamping pass left a dropper" {
    // Two fan peers overlap COLLINEARLY, so the producers file a member but
    // the mask never gains a horizontal arm and the pass declines to stamp.
    var cells = blank();
    cells[idx(4, 3)] = seg(20, .fan_out_dropper, .{ .n = true, .s = true });
    var rows = [_]lattice.Aux{member(4, 3, 21, .out)};
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 1), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 1), c.fan_out.role_records_only);
    try testing.expectEqual(@as(u32, 0), c.fan_out.role_match);
}

test "mismatch: a stamped shared run no producer recorded" {
    // One peer's own corner supplies both a vertical and a horizontal arm,
    // so the mask-scan reads "shared" where only one edge has ink.
    var cells = blank();
    cells[idx(4, 3)] = seg(20, .fan_out_rail, .{ .n = true, .e = true });
    const lat = latOf(&cells, &.{});

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 1), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 1), c.fan_out.role_lattice_only);
}

test "mismatch: a shared run that lost its horizontal arm after stamping" {
    // The role says shared; the mask no longer meets the precondition the
    // pass stamped on, so a later mask pass took the arm away.
    var cells = blank();
    cells[idx(4, 4)] = seg(30, .fan_in_rail, .{ .n = true, .s = true });
    var rows = [_]lattice.Aux{member(4, 4, 31, .in)};
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 1), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 1), c.fan_in.role_match);
    try testing.expectEqual(@as(u32, 1), c.fan_in.mask_mismatch);
}

test "mismatch: a fan-OUT run kept both vertical arms with no recorded continuation" {
    // Pivot node 1 sits above row 3, nothing continues the column, and the
    // cell still carries N and S: the strip's own law says one of them
    // should be gone.
    var cells = blank();
    cells[idx(4, 3)] = seg(20, .fan_out_rail, .{ .n = true, .e = true, .s = true });
    var rows = [_]lattice.Aux{member(4, 3, 21, .out)};
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 1), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 1), c.fan_out.role_match);
    try testing.expectEqual(@as(u32, 1), c.fan_out.mask_mismatch);
    try testing.expectEqual(@as(u32, 0), c.fan_out.pivot_unresolved);
}

test "mismatch: the surviving fan-OUT arm faces away from the pivot" {
    // The strip fired on the pivot's own column and kept the SOUTH arm,
    // where pivot node 1 sits above: the painter reads that as ┬ instead of
    // ┴. Occurrence alone cannot see this — the cell is stripped either way
    // — so a comparator blind to direction would score it a clean match.
    var cells = blank();
    cells[idx(4, 3)] = seg(20, .fan_out_rail, .{ .s = true, .e = true, .w = true });
    var rows = [_]lattice.Aux{member(4, 3, 21, .out)};
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 1), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 1), c.fan_out.role_match);
    try testing.expectEqual(@as(u32, 1), c.fan_out.mask_mismatch);
    try testing.expectEqual(@as(u32, 0), c.fan_out.pivot_unresolved);
}

test "a lone arm off the pivot's columns is a dropper, not a stripped trunk" {
    // Same shape as the fixture above, three columns clear of pivot node 1
    // (x 3..5): no pivot-side descent can run down this column, so the
    // southern arm is the member's own drop and the strip was never in play.
    var cells = blank();
    cells[idx(7, 3)] = seg(20, .fan_out_rail, .{ .s = true, .w = true });
    var rows = [_]lattice.Aux{member(7, 3, 21, .out)};
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 0), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 1), c.fan_out.role_match);
    try testing.expectEqual(@as(u32, 1), c.fan_out.mask_match);
}

test "a single arm whose pivot the fan facts cannot place is tallied, never guessed" {
    var cells = blank();
    cells[idx(4, 3)] = seg(20, .fan_out_rail, .{ .s = true, .e = true });
    var rows = [_]lattice.Aux{member(4, 3, 99, .out)};
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 0), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 1), c.fan_out.pivot_unresolved);
    try testing.expectEqual(@as(u32, 1), c.fan_out.mask_match);
}

test "both vertical arms are legal where a second rail row continues the column" {
    // A grid-wrapped fan threads its trunk through a second rail row: the
    // records name the same family one cell below AND that cell carries a
    // horizontal arm of its own, which is what makes it a rail row rather
    // than a continuation. Both halves are required — see the sibling
    // fixture below, which strips the horizontal arm and nothing else.
    var cells = blank();
    cells[idx(4, 3)] = seg(20, .fan_out_rail, .{ .n = true, .e = true, .s = true });
    cells[idx(4, 4)] = seg(20, .fan_out_rail, .{ .n = true, .e = true, .w = true });
    var rows = [_]lattice.Aux{ member(4, 3, 21, .out), member(4, 4, 21, .out) };
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 0), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 2), c.fan_out.mask_match);
}

test "mismatch: a bare vertical neighbour is not a second rail row" {
    // The cell below carries this fan's membership but no horizontal arm,
    // so it is a plain continuation of the drop and `railJunctionAdjacent`
    // would not spare the strip. Accepting it as a continuation would
    // declare both arms legal — an under-report of the very gate this
    // module feeds.
    var cells = blank();
    cells[idx(4, 3)] = seg(20, .fan_out_rail, .{ .n = true, .e = true, .s = true });
    cells[idx(4, 4)] = seg(20, .fan_out_dropper, .{ .n = true, .s = true });
    var rows = [_]lattice.Aux{ member(4, 3, 21, .out), member(4, 4, 21, .out) };
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 1), c.fan_out.role_match);
    try testing.expectEqual(@as(u32, 1), c.fan_out.mask_mismatch);
    // The neighbour itself is a recorded run the pass left a dropper.
    try testing.expectEqual(@as(u32, 1), c.fan_out.role_records_only);
    try testing.expectEqual(@as(u32, 2), c.mismatchTotal());
}

test "an unplaceable pivot is tallied, never guessed" {
    // The recorded member's fan has no geometry in the Sketch, so no
    // vertical side resolves and the strip's decision is not derivable.
    var cells = blank();
    cells[idx(4, 3)] = seg(20, .fan_out_rail, .{ .n = true, .e = true, .s = true });
    var rows = [_]lattice.Aux{member(4, 3, 99, .out)};
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 0), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 1), c.fan_out.pivot_unresolved);
    try testing.expectEqual(@as(u32, 1), c.fan_out.mask_match);
}

test "a first-class rail owns its own cells and is judged on neither dimension" {
    // The bus-bar rasterizer writes role and mask from geometry and the
    // stamping pass skips those cells, so there is no inference to shadow.
    var cells = blank();
    cells[idx(4, 3)] = seg(20, .fan_out_rail, .{ .e = true, .w = true });
    var rows = [_]lattice.Aux{member(4, 3, 21, .out)};
    var stem = [_]sketch.Point{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 3 } };
    var taps = [_]sketch.Tap{
        .{ .edge = 20, .node = 2, .at = .{ .x = 2, .y = 3 }, .landing = .{ .x = 2, .y = 5 } },
        .{ .edge = 21, .node = 3, .at = .{ .x = 6, .y = 3 }, .landing = .{ .x = 6, .y = 5 } },
    };
    var rails = [_]sketch.Rail{.{
        .pivot = 1,
        .stem = &stem,
        .crossbar = .{ .{ .x = 2, .y = 3 }, .{ .x = 6, .y = 3 } },
        .taps = &taps,
        .kind = .solid,
    }};
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = sketchOf(&.{}, &.{}, &rails), .lat = &lat });
    try testing.expectEqual(@as(u32, 0), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 1), c.rail_owned);
    try testing.expectEqual(@as(u32, 0), c.cells_judged);
}

test "a fan record on a cell the pass cannot reach is reported, not scored" {
    var cells = blank();
    cells[idx(4, 5)] = .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 20 } }, .neighbours = .{ .n = true } };
    var rows = [_]lattice.Aux{tap(4, 5, 21, .out)};
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 0), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 1), c.records_off_grid);
    try testing.expectEqual(@as(u32, 0), c.cells_judged);
}

test "a tap record marks a shared run exactly as a membership record does" {
    var cells = blank();
    cells[idx(4, 3)] = seg(20, .fan_out_rail, .{ .n = true, .e = true, .w = true });
    var rows = [_]lattice.Aux{tap(4, 3, 21, .out)};
    const lat = latOf(&cells, table(&rows));

    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 0), c.mismatchTotal());
    try testing.expectEqual(@as(u32, 1), c.fan_out.role_match);
}

test "an empty lattice is judged without touching anything" {
    var cells: [0]lattice.Cell = undefined;
    const lat = lattice.Lattice{ .width = 0, .height = 0, .cells = &cells };
    const c = fanrole.run(.{ .sketch = matchingSketch(), .lat = &lat });
    try testing.expectEqual(@as(u32, 0), c.cells_judged);
    try testing.expectEqual(@as(u32, 0), c.mismatchTotal());
}

test "writeLine carries every bucket field of both families plus the mismatch total" {
    var c: fanrole.Counts = .{};
    c.fan_out.role_records_only = 3;
    c.fan_in.mask_mismatch = 4;

    var buf: [fanrole.line_buf_len]u8 = undefined;
    const line = c.writeLine(&buf);

    try testing.expect(std.mem.startsWith(u8, line, fanrole.line_prefix));
    inline for (.{ "fan_out", "fan_in" }) |family| {
        inline for (@typeInfo(fanrole.Bucket).@"struct".fields) |f| {
            const token = " " ++ family ++ "_" ++ f.name ++ "=";
            try testing.expect(std.mem.indexOf(u8, line, token) != null);
        }
    }
    try testing.expect(std.mem.indexOf(u8, line, " mismatch=7") != null);
}
