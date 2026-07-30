//! Weld-order pin for the report-only structural audit (`tiling/`).
//!
//! WHY THIS EXISTS. The audit's POSITION in the pipeline is a correctness
//! property, not a convenience. `raster/arrow_base.receiveBase` is the last
//! mutation the rasterizer makes, and it CREATES ink: reading the lattice
//! before it would have the audit judging a diagram the user never sees.
//! Nothing in the tiling zone can observe that ordering — it cannot even
//! import the raster stage — so the pin lives at the mermaid_v2 root,
//! where raster privileges are granted by an explicit lint row.
//!
//! It is split from `tiling_crosscheck_test.zig` only to keep both files
//! under the 500-line cap; the two are one instrument.
//!
//! Kept deliberately hand-built rather than driven off a real render: a
//! production lattice arrives already welded, so the BEFORE state this
//! test needs cannot be observed there at all.

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
    // No ring arms: the fixture is one column wide, so a north/south face
    // carrying its east-west outline arms would report broken ring links
    // that have nothing to do with the weld.
    return .{ .occupant = .{ .node_border = .{ .node = node, .role = role } }, .neighbours = .{} };
}

test "weld order: the terminal buckets are read AFTER arrow_base.receiveBase, and move" {
    // The fixture is the blank-base bridge: an arrowhead two cells below a
    // node's south face with nothing between them. `receiveBase` fills the gap
    // with a straight stroke, and that stroke's north arm is a terminal
    // pair which did not exist a moment earlier.
    var buf: [4]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 4, .cells = &buf };
    lat.at(0, 0).* = nodeFace(1, .edge_s);
    // (0,1) is the blank base.
    lat.at(0, 2).* = .{
        .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 7 } },
        .neighbours = .{ .n = true, .s = true },
    };
    lat.at(0, 3).* = nodeFace(2, .edge_n);

    const before = scan.run(testing.allocator, handCtx(&lat));
    // The arrowhead's tip already abuts the target face — one pair, a
    // convention. Its BASE is background, which is the defect weld exists
    // to repair, and the only thing the audit complains about.
    try testing.expectEqual(@as(u32, 1), before.n_term_abut);
    try testing.expectEqual(@as(u32, 1), before.c_term_node_ns_arrow);
    try testing.expectEqual(@as(u32, 1), before.d_base_blank);
    try testing.expectEqual(@as(u32, 1), before.defectTotal());

    try testing.expectEqual(@as(u32, 1), arrow_base.receiveBase(&lat));

    const after = scan.run(testing.allocator, handCtx(&lat));
    // The bridged stroke adds a departure pair off the source face, and
    // the arrival pair is untouched...
    try testing.expectEqual(@as(u32, 2), after.n_term_abut);
    try testing.expectEqual(@as(u32, 1), after.c_term_node_ns_bare);
    try testing.expectEqual(@as(u32, 1), after.c_term_node_ns_arrow);
    // ... and the base the audit complained about is now fed, so the whole
    // fixture goes silent. Read one stage earlier, this render would have
    // been reported as defective.
    try testing.expectEqual(@as(u32, 0), after.d_base_blank);
    try testing.expectEqual(@as(u32, 0), after.defectTotal());
}
