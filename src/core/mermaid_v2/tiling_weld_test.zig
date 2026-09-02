//! No-repair pin for the report-only structural audit (`tiling/`).
//!
//! WHY THIS EXISTS. The raster used to run a post-walk base weld
//! (`arrow_base.receiveBase`) that ADDED ink after every producer had
//! finished — additive repair, forbidden by the subtractive-repair-only invariant: a downstream stage may
//! remove nonconforming ink, never add ink to patch a gap. The pass is
//! deleted. This pin holds the deletion in place: a 1-cell resume gap
//! under an arrowhead stays on the shipped lattice, the raster validator
//! COUNTS it (pricing it into selection), and the tiling audit reports
//! the same defect on the same bytes the user sees — audit and shipped
//! grid can no longer disagree because nothing mutates between them.
//!
//! It is split from `tiling_crosscheck_test.zig` only to keep both files
//! under the 500-line cap; the two are one instrument.
//!
//! Kept deliberately hand-built: the fixture is the exact shape the old
//! weld fabricated ink for, so a reintroduced repair pass flips these
//! expectations first.

const std = @import("std");
const lattice = @import("lattice.zig");
const arrow_base = @import("raster/arrow_base.zig");
const scan = @import("tiling/scan.zig");

const testing = std.testing;

/// A hand-built lattice needs a context too. The audit reads the graph
/// and the sketch for its census tier only, so empty ones leave every ink
/// law — the subject here — untouched.
fn handCtx(lat: *const lattice.Lattice) scan.Ctx {
    return .{
        .graph = .{
            .direction = .TD,
            .nodes = &.{},
            .edges = &.{},
            .clusters = &.{},
            .classes = &.{},
            .arena = null,
        },
        .sketch = .{
            .bbox = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .direction = .TD,
            .nodes = &.{},
            .clusters = &.{},
            .edges = &.{},
            .diagnostics = &.{},
            .budget = .{ .max_width = 80, .rung = 0 },
        },
        .lat = lat,
        .mode = .bridge,
    };
}

fn nodeFace(node: u32, role: lattice.BorderRole) lattice.Cell {
    return .{ .occupant = .{ .node_border = .{ .node = node, .role = role } }, .neighbours = .{} };
}

test "a 1-cell resume gap ships declared: audit and raster validator agree, no ink is added" {
    var buf: [4]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 4, .cells = &buf };
    lat.at(0, 0).* = nodeFace(1, .edge_s);
    lat.at(0, 2).* = .{
        .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 7 } },
        .neighbours = .{ .n = true, .s = true },
    };
    lat.at(0, 3).* = nodeFace(2, .edge_n);

    try testing.expectEqual(@as(u32, 1), arrow_base.validate(&lat).violations);

    const counts = scan.run(testing.allocator, handCtx(&lat));
    try testing.expectEqual(@as(u32, 1), counts.n_term_abut);
    try testing.expectEqual(@as(u32, 1), counts.c_term_node_ns_arrow);
    try testing.expectEqual(@as(u32, 1), counts.d_base_blank);
    try testing.expectEqual(@as(u32, 1), counts.defectTotal());

    try testing.expect(lat.atConst(0, 1).occupant == .empty);
}
