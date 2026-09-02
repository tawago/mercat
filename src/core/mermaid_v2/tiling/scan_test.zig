//! Unit tests for `tiling/scan.zig`: non-mutation, the ownership
//! property, the meta counters, and the EAW label-geometry bridge.

const std = @import("std");
const ledger = @import("../base/ledger.zig");
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
        .bundle_stamp_state = .complete,
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
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    buf[4] = arrowCell(.south, .{ .n = true, .e = true, .w = true });
    buf[3] = edgeCell(.{ .e = true });
    buf[1] = .{ .occupant = .{ .label_char = '日' }, .neighbours = .{} };
    buf[6] = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_n } }, .neighbours = .{ .e = true, .w = true } };
    var records = [_]lattice.Aux{.{
        .cell = 4,
        .value = 8,
        .kind = .carrier,
        .detail = @intFromEnum(lattice.CarrierKind.merged_foreign),
    }};
    const lat = lattice.Lattice{
        .width = 3,
        .height = 3,
        .cells = &buf,
        .aux = &records,
        .aux_collection = .{ .state = .complete, .attempted_records = records.len },
    };

    const before = try testing.allocator.dupe(lattice.Cell, lat.cells);
    defer testing.allocator.free(before);
    const records_before = records;
    const aux_before = lat.aux_collection;

    const c = scan.run(testing.allocator, ctxOf(&lat));
    try testing.expectEqualSlices(lattice.Cell, before, lat.cells);
    try testing.expectEqualSlices(lattice.Aux, &records_before, &records);
    try testing.expectEqual(aux_before, lat.aux_collection);

    try testing.expectEqual(@as(u32, 9), c.n_cells);
    try testing.expectEqual(@as(u32, 1), c.n_arrow_cells);
}

test "ownership: each seeded defect increments defectTotal by exactly one" {
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

    var lat_orphan = clean;
    put(&lat_orphan, 2, 2, arrowCell(.south, .{ .n = true, .w = true }));
    put(&lat_orphan, 2, 1, edgeCell(.{ .s = true }));

    var lat_silent = clean;
    put(&lat_silent, 2, 2, arrowCell(.south, .{ .n = true, .w = true }));
    put(&lat_silent, 2, 1, edgeCell(.{ .s = true }));
    put(&lat_silent, 1, 2, edgeCell(.{ .n = true }));

    var lat_base_blank = clean;
    put(&lat_base_blank, 2, 2, arrowCell(.south, .{ .s = true }));

    var lat_armless = clean;
    put(&lat_armless, 2, 2, edgeCell(.{}));

    var lat_stub = clean;
    put(&lat_stub, 2, 2, edgeCell(.{ .n = true }));
    put(&lat_stub, 2, 1, .{ .occupant = .{ .node_interior = 5 }, .neighbours = .{} });

    var lat_interior = clean;
    put(&lat_interior, 2, 2, edgeCell(.{ .n = true, .s = true }));
    put(&lat_interior, 2, 1, .{ .occupant = .{ .node_interior = 5 }, .neighbours = .{} });
    put(&lat_interior, 2, 3, .{ .occupant = .{ .node_interior = 5 }, .neighbours = .{} });

    var lat_fused = clean;
    put(&lat_fused, 0, 2, arrowCell(.west, .{ .e = true }));
    put(&lat_fused, 1, 2, edgeCell(.{ .e = true, .w = true }));
    put(&lat_fused, 2, 2, .{ .occupant = .{ .edge_segment = .{ .edge = 8, .kind = .solid } }, .neighbours = .{ .e = true, .w = true } });
    put(&lat_fused, 3, 2, arrowCell(.east, .{ .w = true }));

    var lat_ring_arm = clean;
    ring3(&lat_ring_arm, W, 3);
    put(&lat_ring_arm, 2, 1, .{ .occupant = .{ .node_border = .{ .node = 3, .role = .edge_e } }, .neighbours = .{ .n = true, .s = true, .e = true } });

    var lat_term_corner = clean;
    ring3(&lat_term_corner, W, 3);
    put(&lat_term_corner, 2, 3, edgeCell(.{ .n = true }));

    var lat_term_frame = clean;
    frameRing3(&lat_term_frame, W, 4);
    put(&lat_term_frame, 1, 3, arrowCell(.north, .{ .s = true }));
    put(&lat_term_frame, 1, 4, edgeCell(.{ .n = true }));

    const seeds = [_]Seed{
        .{ .name = "arrow lateral into background", .cells = lat_orphan },
        .{ .name = "arrow lateral at a silent stroke", .cells = lat_silent },
        .{ .name = "arrowhead with a blank base", .cells = lat_base_blank },
        .{ .name = "armless stroke", .cells = lat_armless },
        .{ .name = "one-armed stroke with no terminal", .cells = lat_stub },
        .{ .name = "ink crossing a node interior", .cells = lat_interior },
        .{ .name = "two runs fused collinearly", .cells = lat_fused },
        .{ .name = "node ring with an extra east arm", .cells = lat_ring_arm },
        .{ .name = "run terminating on a node ring corner", .cells = lat_term_corner },
        .{ .name = "arrowhead abutting untouched frame", .cells = lat_term_frame },
    };

    for (seeds) |seed| {
        var buf = seed.cells;
        const lat = lattice.Lattice{ .width = W, .height = W, .cells = &buf, .aux_collection = .{ .state = .complete } };
        const c = scan.run(testing.allocator, ctxOf(&lat));
        if (c.defectTotal() != 1) {
            var line: [counts.line_buf_len]u8 = undefined;
            std.debug.print("seed '{s}': defectTotal {d}, want 1\n{s}\n", .{ seed.name, c.defectTotal(), c.writeLine(&line) });
            return error.OwnershipViolated;
        }
    }

    var buf = clean;
    put(&buf, 2, 2, arrowCell(.south, .{ .n = true }));
    put(&buf, 2, 1, edgeCell(.{ .s = true }));
    const lat = lattice.Lattice{ .width = W, .height = W, .cells = &buf, .aux_collection = .{ .state = .complete } };
    try testing.expectEqual(@as(u32, 0), scan.run(testing.allocator, ctxOf(&lat)).defectTotal());
}

/// The eight cells of a closed 3x3 ring: offset, role, and the arms that
/// role carries. Shared by the node and frame builders so the two rings
/// differ only in occupant.
const ring3_shape = [_]struct { dx: usize, dy: usize, role: lattice.BorderRole, nb: lattice.Neighbours }{
    .{ .dx = 0, .dy = 0, .role = .corner_nw, .nb = .{ .e = true, .s = true } },
    .{ .dx = 1, .dy = 0, .role = .edge_n, .nb = .{ .e = true, .w = true } },
    .{ .dx = 2, .dy = 0, .role = .corner_ne, .nb = .{ .w = true, .s = true } },
    .{ .dx = 0, .dy = 1, .role = .edge_w, .nb = .{ .n = true, .s = true } },
    .{ .dx = 2, .dy = 1, .role = .edge_e, .nb = .{ .n = true, .s = true } },
    .{ .dx = 0, .dy = 2, .role = .corner_sw, .nb = .{ .e = true, .n = true } },
    .{ .dx = 1, .dy = 2, .role = .edge_s, .nb = .{ .e = true, .w = true } },
    .{ .dx = 2, .dy = 2, .role = .corner_se, .nb = .{ .w = true, .n = true } },
};

/// A closed 3x3 node ring with its NW corner at (0,0) of a `w`-wide grid.
fn ring3(cs: []lattice.Cell, w: usize, node: u32) void {
    for (ring3_shape) |r| {
        cs[r.dy * w + r.dx] = .{
            .occupant = .{ .node_border = .{ .node = node, .role = r.role } },
            .neighbours = r.nb,
        };
    }
    cs[w + 1] = .{ .occupant = .{ .node_interior = node }, .neighbours = .{} };
}

/// The same ring as a subgraph frame. A frame has no interior fill, so
/// the centre cell stays background.
fn frameRing3(cs: []lattice.Cell, w: usize, cluster: u32) void {
    for (ring3_shape) |r| {
        cs[r.dy * w + r.dx] = .{
            .occupant = .{ .cluster_border = .{ .cluster = cluster, .role = r.role } },
            .neighbours = r.nb,
        };
    }
}

test "scan: a zero-sized lattice is a no-op" {
    const lat = lattice.Lattice{
        .width = 0,
        .height = 0,
        .cells = &[_]lattice.Cell{},
        .aux_collection = .{ .state = .complete },
    };
    const c = scan.run(testing.allocator, ctxOf(&lat));
    try testing.expectEqual(@as(u32, 0), c.n_cells);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try testing.expectEqual(@as(u32, 0), c.u_audit_oom);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_population_absent);
    try testing.expectEqual(@as(u32, 1), c.u_rail_population_absent);
    try testing.expectEqual(@as(u32, 1), c.u_rail_claim_population_absent);
}

test "scan: zero-size still reports unavailable AUX and bundle stamp causes" {
    const lat = lattice.Lattice{ .width = 0, .height = 0, .cells = &[_]lattice.Cell{} };
    var ctx = ctxOf(&lat);
    ctx.sketch.bundle_stamp_state = .unattempted;
    const c = scan.run(testing.allocator, ctx);
    try testing.expectEqual(@as(u32, 1), c.u_aux_not_collected);
    try testing.expectEqual(@as(u32, 0), c.u_bundle_population_absent);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_stamp_unattempted);
}

test "scan: rail-star tier reads the lattice, not an unrelated Sketch" {
    const members = [_]ledger.RailClaimMember{
        .{ .edge = 1, .endpoints = .{ 10, 20 }, .sites = .{ .{ .node = 10, .side = .south, .offset = 1 }, .{ .node = 20, .side = .north, .offset = 1 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .source },
        .{ .edge = 2, .endpoints = .{ 10, 21 }, .sites = .{ .{ .node = 10, .side = .south, .offset = 1 }, .{ .node = 21, .side = .north, .offset = 1 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .source },
    };
    const claims = [_]ledger.RailClaim{.{ .id = 1, .polarity = .out, .members = &members }};
    const lat: lattice.Lattice = .{ .width = 0, .height = 0, .cells = &.{}, .rail_claims = &claims };
    const c = scan.run(testing.allocator, ctxOf(&lat));
    try testing.expectEqual(@as(u32, 1), c.n_rail_claims);
    try testing.expectEqual(@as(u32, 1), c.c_rail_star_valid);
    try testing.expectEqual(@as(u32, 0), c.u_rail_claim_population_absent);
}

test "scan: meta counters record cells and frame notation" {
    var buf: [6]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    const lat = lattice.Lattice{ .width = 3, .height = 2, .cells = &buf, .aux_collection = .{ .state = .complete } };

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
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    buf[0] = .{ .occupant = .{ .label_char = '日' }, .neighbours = .{} };
    buf[1] = .{ .occupant = .{ .label_char = 'a' }, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 3, .height = 1, .cells = &buf, .aux_collection = .{ .state = .complete } };

    const c = scan.run(testing.allocator, ctxOf(&lat));
    try testing.expectEqual(@as(u32, 1), c.m_wide_label_cells);
    try testing.expectEqual(@as(u32, 1), c.m_row_col_overflow);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    buf[0] = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    const narrow = scan.run(testing.allocator, ctxOf(&lat));
    try testing.expectEqual(@as(u32, 0), narrow.m_wide_label_cells);
    try testing.expectEqual(@as(u32, 0), narrow.m_row_col_overflow);
}

test "scan: emit() writes to stderr only and returns the same counts as run()" {
    var buf: [4]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    const lat = lattice.Lattice{ .width = 2, .height = 2, .cells = &buf, .aux_collection = .{ .state = .complete } };
    const c = scan.run(testing.allocator, ctxOf(&lat));

    var line_buf: [counts.line_buf_len]u8 = undefined;
    const line = c.writeLine(&line_buf);
    try testing.expect(std.mem.startsWith(u8, line, counts.line_prefix));
    const v = cell.View.init(&lat);
    try testing.expectEqual(@as(u32, 2), v.width());
}
