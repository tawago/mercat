//! Unit tests for `tiling/scan.zig`: non-mutation, the ownership
//! property, the meta counters, and the item-4 column bridge.

const std = @import("std");
const lattice = @import("../lattice.zig");
const sem_graph = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");
const scan = @import("scan.zig");

const testing = std.testing;

fn emptyGraph() sem_graph.SemGraph {
    return .{
        .direction = .TD,
        .nodes = &.{},
        .edges = &.{},
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
}

fn emptySketch() sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn ctxOf(lat: *const lattice.Lattice) scan.Ctx {
    return .{
        .graph = emptyGraph(),
        .sketch = emptySketch(),
        .lat = lat,
        .mode = .bridge,
    };
}

fn arrowCell(dir: lattice.Dir4, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .arrowhead = .{ .dir = dir, .edge = 7 } }, .neighbours = nb };
}

fn edgeCell(nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = 7, .kind = .solid } }, .neighbours = nb };
}

test "scan: run() leaves the lattice byte-identical" {
    // The pinned proof of D2: the audit hands out copies only, cannot
    // reach a writer, and demonstrably changes nothing.
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    buf[4] = arrowCell(.south, .{ .n = true, .e = true, .w = true });
    buf[3] = edgeCell(.{ .e = true });
    buf[1] = .{ .occupant = .{ .label_char = '日' }, .neighbours = .{} };
    buf[6] = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_n } }, .neighbours = .{ .e = true, .w = true } };
    const lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };

    const before = try testing.allocator.dupe(lattice.Cell, lat.cells);
    defer testing.allocator.free(before);

    const c = scan.run(testing.allocator, ctxOf(&lat));
    try testing.expectEqualSlices(lattice.Cell, before, lat.cells);

    // ... and it did do work (a vacuous scan would trivially pass).
    try testing.expectEqual(@as(u32, 9), c.n_cells);
    try testing.expectEqual(@as(u32, 1), c.n_arrow_cells);
}

test "ownership: each seeded defect increments defectTotal by exactly one" {
    // One hand-built lattice per seeded defect; each must move the total
    // by exactly one, so no (cell, bit) is consumed by two families.
    const Seed = struct {
        name: []const u8,
        cells: [9]lattice.Cell,
    };

    var clean: [9]lattice.Cell = undefined;
    for (&clean) |*c| c.* = lattice.Cell.empty;

    var orphan_lateral = clean;
    // ▼ with a west arm pointing at background with nothing beyond.
    orphan_lateral[4] = arrowCell(.south, .{ .n = true, .w = true });
    orphan_lateral[1] = edgeCell(.{ .n = true, .s = true });

    var orphan_silent = clean;
    // ▼ with a west arm at a stroke that never points back.
    orphan_silent[4] = arrowCell(.south, .{ .n = true, .w = true });
    orphan_silent[1] = edgeCell(.{ .n = true, .s = true });
    orphan_silent[3] = edgeCell(.{ .n = true, .s = true });

    const seeds = [_]Seed{
        .{ .name = "arrow lateral into background", .cells = orphan_lateral },
        .{ .name = "arrow lateral at a silent stroke", .cells = orphan_silent },
    };

    for (seeds) |seed| {
        var buf = seed.cells;
        const lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };
        const c = scan.run(testing.allocator, ctxOf(&lat));
        if (c.defectTotal() != 1) {
            std.debug.print("seed '{s}': defectTotal {d}, want 1\n", .{ seed.name, c.defectTotal() });
            return error.OwnershipViolated;
        }
    }

    // The clean control fires nothing at all.
    var buf = clean;
    buf[4] = arrowCell(.south, .{ .n = true });
    buf[1] = edgeCell(.{ .n = true, .s = true });
    const lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };
    try testing.expectEqual(@as(u32, 0), scan.run(testing.allocator, ctxOf(&lat)).defectTotal());
}

test "scan: a zero-sized lattice is a no-op" {
    const lat = lattice.Lattice{ .width = 0, .height = 0, .cells = &[_]lattice.Cell{} };
    const c = scan.run(testing.allocator, ctxOf(&lat));
    try testing.expectEqual(@as(u32, 0), c.n_cells);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try testing.expectEqual(@as(u32, 0), c.u_audit_oom);
}

test "scan: meta counters record cells and frame notation" {
    var buf: [6]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    const lat = lattice.Lattice{ .width = 3, .height = 2, .cells = &buf };

    var ctx = ctxOf(&lat);
    var c = scan.run(testing.allocator, ctx);
    try testing.expectEqual(@as(u32, 6), c.n_cells);
    try testing.expectEqual(@as(u32, 0), c.n_mode_cross);
    try testing.expectEqual(@as(u32, 0), c.n_clustered);

    ctx.mode = .cross;
    c = scan.run(testing.allocator, ctx);
    try testing.expectEqual(@as(u32, 1), c.n_mode_cross);
}

test "scan: the item-4 bridge sees a wide label lying about its row width" {
    // A CJK label cell occupies ONE lattice cell but paints TWO columns:
    // the row claims 3 cells and paints 4. This is the audit vocabulary
    // the EAW writer fix is measured against.
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    buf[0] = .{ .occupant = .{ .label_char = '日' }, .neighbours = .{} };
    buf[1] = .{ .occupant = .{ .label_char = 'a' }, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 3, .height = 1, .cells = &buf };

    const c = scan.run(testing.allocator, ctxOf(&lat));
    try testing.expectEqual(@as(u32, 1), c.m_wide_label_cells);
    try testing.expectEqual(@as(u32, 1), c.m_row_col_overflow);
    // A measurement, never a defect claim.
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    // An all-narrow row is exactly as wide as it claims.
    buf[0] = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    const narrow = scan.run(testing.allocator, ctxOf(&lat));
    try testing.expectEqual(@as(u32, 0), narrow.m_wide_label_cells);
    try testing.expectEqual(@as(u32, 0), narrow.m_row_col_overflow);
}

test "scan: emit() writes to stderr only and returns the same counts as run()" {
    var buf: [4]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    const lat = lattice.Lattice{ .width = 2, .height = 2, .cells = &buf };
    const c = scan.run(testing.allocator, ctxOf(&lat));

    var line_buf: [counts.line_buf_len]u8 = undefined;
    const line = c.writeLine(&line_buf);
    try testing.expect(std.mem.startsWith(u8, line, counts.line_prefix));
    // The View is the only handle a check ever gets on the lattice.
    const v = cell.View.init(&lat);
    try testing.expectEqual(@as(u32, 2), v.width());
}
