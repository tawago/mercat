//! Unit tests for `tiling/scan.zig`: non-mutation, the ownership
//! property, the meta counters, and the EAW label-geometry bridge.

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
    // The pinned non-mutation proof: the audit hands out copies only, cannot
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
    // One 5x5 lattice per seeded defect, each holding EXACTLY one thing
    // wrong. If any (cell, bit) were consumed by two check families, or a
    // family double-counted a cell-level verdict, a seed would move the
    // total by more than one.
    const W = 5;
    const N = W * W;
    const Seed = struct {
        name: []const u8,
        cells: [N]lattice.Cell,
    };

    var clean: [N]lattice.Cell = undefined;
    for (&clean) |*c| c.* = lattice.Cell.empty;

    const put = struct {
        fn at(cs: *[N]lattice.Cell, x: usize, y: usize, c: lattice.Cell) void {
            cs[y * W + x] = c;
        }
    }.at;

    // ▼ at (2,2) fed by a one-armed stub above it; its WEST bit points at
    // background with nothing beyond.
    var lat_orphan = clean;
    put(&lat_orphan, 2, 2, arrowCell(.south, .{ .n = true, .w = true }));
    put(&lat_orphan, 2, 1, edgeCell(.{ .s = true }));

    // Same, but the west neighbour is a stroke that never points back.
    var lat_silent = clean;
    put(&lat_silent, 2, 2, arrowCell(.south, .{ .n = true, .w = true }));
    put(&lat_silent, 2, 1, edgeCell(.{ .s = true }));
    put(&lat_silent, 1, 2, edgeCell(.{ .n = true }));

    // ▼ whose base cell is background: the tip receives nothing.
    var lat_base_blank = clean;
    put(&lat_base_blank, 2, 2, arrowCell(.south, .{ .s = true }));

    // A stroke cell with no arms at all.
    var lat_armless = clean;
    put(&lat_armless, 2, 2, edgeCell(.{}));

    // A one-armed stroke with nothing terminal beside it (a node's fill is
    // not a terminal).
    var lat_stub = clean;
    put(&lat_stub, 2, 2, edgeCell(.{ .n = true }));
    put(&lat_stub, 2, 1, .{ .occupant = .{ .node_interior = 5 }, .neighbours = .{} });

    // Ink crossing a box: the cell-level verdict fires once and suppresses
    // both of its own into-fill arms.
    var lat_interior = clean;
    put(&lat_interior, 2, 2, edgeCell(.{ .n = true, .s = true }));
    put(&lat_interior, 2, 1, .{ .occupant = .{ .node_interior = 5 }, .neighbours = .{} });
    put(&lat_interior, 2, 3, .{ .occupant = .{ .node_interior = 5 }, .neighbours = .{} });

    // Two straight runs of different edges laid end to end between two
    // arrowheads that are both properly fed.
    var lat_fused = clean;
    put(&lat_fused, 0, 2, arrowCell(.west, .{ .e = true }));
    put(&lat_fused, 1, 2, edgeCell(.{ .e = true, .w = true }));
    put(&lat_fused, 2, 2, .{ .occupant = .{ .edge_segment = .{ .edge = 8, .kind = .solid } }, .neighbours = .{ .e = true, .w = true } });
    put(&lat_fused, 3, 2, arrowCell(.east, .{ .w = true }));

    // A closed 3x3 node ring whose east side claims an extra east arm.
    var lat_ring_arm = clean;
    ring3(&lat_ring_arm, W, 3);
    put(&lat_ring_arm, 2, 1, .{ .occupant = .{ .node_border = .{ .node = 3, .role = .edge_e } }, .neighbours = .{ .n = true, .s = true, .e = true } });

    const seeds = [_]Seed{
        .{ .name = "arrow lateral into background", .cells = lat_orphan },
        .{ .name = "arrow lateral at a silent stroke", .cells = lat_silent },
        .{ .name = "arrowhead with a blank base", .cells = lat_base_blank },
        .{ .name = "armless stroke", .cells = lat_armless },
        .{ .name = "one-armed stroke with no terminal", .cells = lat_stub },
        .{ .name = "ink crossing a node interior", .cells = lat_interior },
        .{ .name = "two runs fused collinearly", .cells = lat_fused },
        .{ .name = "node ring with an extra east arm", .cells = lat_ring_arm },
    };

    for (seeds) |seed| {
        var buf = seed.cells;
        const lat = lattice.Lattice{ .width = W, .height = W, .cells = &buf };
        const c = scan.run(testing.allocator, ctxOf(&lat));
        if (c.defectTotal() != 1) {
            var line: [counts.line_buf_len]u8 = undefined;
            std.debug.print("seed '{s}': defectTotal {d}, want 1\n{s}\n", .{ seed.name, c.defectTotal(), c.writeLine(&line) });
            return error.OwnershipViolated;
        }
    }

    // The clean control fires nothing at all.
    var buf = clean;
    put(&buf, 2, 2, arrowCell(.south, .{ .n = true }));
    put(&buf, 2, 1, edgeCell(.{ .s = true }));
    const lat = lattice.Lattice{ .width = W, .height = W, .cells = &buf };
    try testing.expectEqual(@as(u32, 0), scan.run(testing.allocator, ctxOf(&lat)).defectTotal());
}

/// A closed 3x3 node ring with its NW corner at (0,0) of a `w`-wide grid.
fn ring3(cs: []lattice.Cell, w: usize, node: u32) void {
    const B = struct {
        fn c(node_id: u32, role: lattice.BorderRole, nb: lattice.Neighbours) lattice.Cell {
            return .{ .occupant = .{ .node_border = .{ .node = node_id, .role = role } }, .neighbours = nb };
        }
    };
    cs[0] = B.c(node, .corner_nw, .{ .e = true, .s = true });
    cs[1] = B.c(node, .edge_n, .{ .e = true, .w = true });
    cs[2] = B.c(node, .corner_ne, .{ .w = true, .s = true });
    cs[w] = B.c(node, .edge_w, .{ .n = true, .s = true });
    cs[w + 1] = .{ .occupant = .{ .node_interior = node }, .neighbours = .{} };
    cs[w + 2] = B.c(node, .edge_e, .{ .n = true, .s = true });
    cs[2 * w] = B.c(node, .corner_sw, .{ .e = true, .n = true });
    cs[2 * w + 1] = B.c(node, .edge_s, .{ .e = true, .w = true });
    cs[2 * w + 2] = B.c(node, .corner_se, .{ .w = true, .n = true });
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

test "scan: the EAW label bridge sees a wide label lying about its row width" {
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
