//! Ring ink laws for the report-only structural audit — node outlines
//! (`node_border`) and subgraph frames (`cluster_border`).
//!
//! A ring cell's role fixes which arms belong to the OUTLINE: a north
//! edge cell runs east-west, a north-west corner turns east and south,
//! and so on. That splits its mask in two, and each half gets its own
//! law:
//!
//!   STENCIL  the arms ON the ring must reach the rest of the ring. When
//!            they do not, the question is who took the cell: another
//!            frame, a title band, a terminal arrival — all legal, since
//!            border writes SKIP occupied cells and title bands overwrite
//!            them — or nothing at all, which is a broken outline.
//!   FUSION   the arms OFF the ring are ink the outline itself never
//!            wrote. Some are legal (the arrowhead-base weld, the
//!            source-border merge, the `cross` notation's frame welds);
//!            the rest are ink no run provides.
//!
//! This local stencil, together with the expectation tier's per-node
//! presence check, is what stands in for walking each ring as a cycle:
//! every ring cell verifies its own two links, and `expect.zig` verifies
//! the ring exists at all. Neither module claims to traverse the cycle.
//!
//! Denominator note: the ring axes of the FULL-rect form are used for
//! both halves. The degenerate 1xN/Nx1 forms write a SUBSET of those
//! arms, so using the full form can never invent an "extra" arm.
//!
//! Imports: `std`, `prim`, `lattice.zig`, tiling siblings.

const std = @import("std");
const cell = @import("cell.zig");
const counts = @import("counts.zig");
const lattice = @import("../lattice.zig");

/// True for the four corner roles.
fn isCorner(role: lattice.BorderRole) bool {
    return switch (role) {
        .corner_nw, .corner_ne, .corner_se, .corner_sw => true,
        .edge_n, .edge_e, .edge_s, .edge_w => false,
    };
}

/// The degenerate-node signature: a CORNER whose mask holds fewer than
/// two of its full-rect ring axes. A full rect always writes both corner
/// arms and masks only ever gain bits, so this can only be the collapsed
/// 1xN / Nx1 form, whose corners carry one arm or none.
fn thinSignature(role: lattice.BorderRole, mask: u4, full: u4) bool {
    return isCorner(role) and @popCount(mask & full) < 2;
}

/// Node-outline stencil: every ring arm PRESENT in the mask must reach
/// another cell of the same node's ring.
fn stencilNode(v: cell.View, x: u32, y: u32, t: cell.Typed, full: u4, c: *counts.Counts) void {
    for (cell.dirs) |d| {
        if (t.mask & full & cell.bit(d) == 0) continue;
        const n = v.arm(x, y, d) orelse {
            c.d_ring_node_break += 1;
            continue;
        };
        switch (n.kind) {
            .ring_node => {
                const mine = t.node orelse 0;
                const theirs = n.node orelse 0;
                if (mine != theirs) c.c_ring_node_shadowed += 1;
            },
            // Clusters rasterize first and a border write skips an
            // occupied cell, so a frame (or a neighbouring node's ring)
            // sitting here means this cell was legally never written.
            .ring_frame => c.c_ring_node_shadowed += 1,
            // A title band stamps every cell of its span.
            .glyph => c.c_ring_node_label += 1,
            else => c.d_ring_node_break += 1,
        }
    }
}

/// Frame stencil: same shape, different legal population — a frame is
/// overwritten by title bands and by terminal arrivals, and an inner
/// frame overwrites an outer one at coincident cells.
fn stencilFrame(v: cell.View, x: u32, y: u32, t: cell.Typed, full: u4, c: *counts.Counts) void {
    for (cell.dirs) |d| {
        if (t.mask & full & cell.bit(d) == 0) continue;
        const n = v.arm(x, y, d) orelse {
            c.d_ring_frame_break += 1;
            continue;
        };
        switch (n.kind) {
            .ring_frame => {
                const mine = t.cluster orelse 0;
                const theirs = n.cluster orelse 0;
                if (mine != theirs) c.c_ring_frame_shadowed += 1;
            },
            .glyph => c.c_ring_frame_title += 1,
            // A polyline that TERMINATES on the border replaces the
            // occupant; only through-going segments bridge it.
            .stroke, .arrow, .ghost => c.c_ring_frame_terminal += 1,
            .ring_node, .fill => c.c_ring_frame_shadowed += 1,
            .blank => c.d_ring_frame_break += 1,
        }
    }
}

/// Fusion ladder over the arms that are NOT part of the outline.
///
/// The weld test comes FIRST and deliberately so: the arrowhead-base
/// weld ORs an arm into a node border for ANY tip direction, east and
/// west included, so checking the axis buckets first would misfile every
/// horizontal weld as a defect.
/// guarded-by: rings_test.zig "fusion: a weld-explained east arm is claimed before the axis buckets"
fn fusionArms(v: cell.View, x: u32, y: u32, t: cell.Typed, full: u4, mode_cross: bool, c: *counts.Counts) void {
    const extra = t.ink & ~full;
    for (cell.dirs) |d| {
        if (extra & cell.bit(d) == 0) continue;
        if (v.arm(x, y, d)) |n| {
            // An arrowhead whose tip points along this arm has its BASE
            // on this cell: the arm is the weld that feeds it.
            if (n.kind == .arrow and n.tip == d) {
                c.c_border_arm_weld += 1;
                continue;
            }
            // An off-axis arm into the SAME node's own border is internal
            // structure the node rasterizer synthesized (the subroutine
            // double wall), not an edge attachment.
            // guarded-by: rings_test.zig "fusion: an off-axis arm into the same node's own border is wall structure"
            if (t.kind == .ring_node and n.kind == .ring_node and
                t.node != null and n.node != null and t.node.? == n.node.?)
            {
                c.c_border_arm_wall += 1;
                continue;
            }
        }
        if (t.kind == .ring_node) {
            // Uniform port erasure: an attachment stroke may OR an arm
            // into EITHER end's border on ANY face, and every stroke
            // actually drawn files a `.port` record naming the merged
            // arm. The record is the evidence FOR THAT ARM only: a cell
            // with one recorded departure and one further unexplained
            // arm still reports the stray. An arm with neither weld nor
            // matching record has no known writer.
            // guarded-by: rings_test.zig "fusion: a port-recorded arm is the convention on every face; unrecorded is a defect"
            // guarded-by: rings_test.zig "fusion: a port record excuses only the arm it merged"
            if (t.portArm(d)) {
                c.c_border_arm_port += 1;
            } else {
                c.d_border_arm_unrecorded += 1;
            }
        } else if (mode_cross) {
            c.c_frame_arm_cross_mode += 1;
        } else {
            c.d_frame_arm_foreign += 1;
        }
    }
}

/// All ring laws for ONE cell. Called from `scan.run`'s single ownership
/// dispatch, which guarantees `t.kind` is `.ring_node` or `.ring_frame`.
/// `mode_cross` steers bucketing only: a frame arm is a convention under
/// the `cross` notation and a leak under `bridge`.
pub fn check(v: cell.View, x: u32, y: u32, t: cell.Typed, mode_cross: bool, c: *counts.Counts) void {
    const role = t.role orelse return;
    const full = cell.ringAxes(role, false);

    if (t.kind == .ring_node) {
        if (thinSignature(role, t.mask, full)) {
            c.c_ring_node_thin += 1;
        } else {
            stencilNode(v, x, y, t, full, c);
        }
    } else {
        stencilFrame(v, x, y, t, full, c);
    }

    fusionArms(v, x, y, t, full, mode_cross, c);
}
