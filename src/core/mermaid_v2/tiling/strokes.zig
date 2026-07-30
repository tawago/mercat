//! Stroke ink laws for the report-only structural audit.
//!
//! A stroke cell's `ink` mask is a CLAIM: "a run continues in each of
//! these directions". These checks ask whether the lattice makes good on
//! it. Four families, disjoint by construction (see `scan.zig`'s
//! ownership table):
//!
//!   ARITY      one bucket per cell, keyed on popcount. A one-armed cell
//!              goes to the stub ladder and NOWHERE else; the per-arm
//!              pass below starts at two arms.
//!   ARMS       one bucket per set arm, on cells with >= 2 arms.
//!   INTERIOR   one CELL-level verdict; when it fires it suppresses that
//!              cell's per-arm into-fill increments, so ink crossing a box
//!              counts once rather than twice.
//!   FUSION     a pair check over cells that are HEALTHY in the arm pass
//!              (both reciprocate), so no arm is consumed twice.
//!
//! The arity quartet (`m_corner/straight/tee/cross_cells`) plus
//! `d_run_fused_collinear` and `m_arm_asym` are the path-simplicity
//! proxies: they say how convoluted the ink is without judging it.
//!
//! Expected steady state: `d_arm_dangling` is ZERO, because the raster's
//! reconcile pass clears exactly this class — but it runs BEFORE labels
//! and before the arrowhead-base weld, so a nonzero value localises the
//! regression to those two later stages.
//!
//! Imports: `std`, `prim`, `lattice.zig`, tiling siblings.

const std = @import("std");
const cell = @import("cell.zig");
const counts = @import("counts.zig");

/// The two straight arms of the axis `d` lies on.
fn axisPair(d: cell.Dir4) u4 {
    return switch (d) {
        .north, .south => cell.bit(.north) | cell.bit(.south),
        .east, .west => cell.bit(.east) | cell.bit(.west),
    };
}

/// Cell-level verdict: ink with the SAME node's fill on two OPPOSITE
/// sides is ink crossing that box's interior. Same-id AND opposite-sides
/// is the false-positive guard — a gutter between two boxes has different
/// ids on its two sides, and a run alongside one box has fill on one side
/// only.
/// guarded-by: strokes_test.zig "interior: opposite-side fill of the same node fires, one side or two ids do not"
pub fn inkInInterior(v: cell.View, x: u32, y: u32) bool {
    const pairs = [2][2]cell.Dir4{ .{ .north, .south }, .{ .east, .west } };
    for (pairs) |p| {
        const a = v.arm(x, y, p[0]) orelse continue;
        const b = v.arm(x, y, p[1]) orelse continue;
        if (a.kind != .fill or b.kind != .fill) continue;
        const an = a.node orelse continue;
        const bn = b.node orelse continue;
        if (an == bn) return true;
    }
    return false;
}

/// One-armed stroke: the run stops here. Legitimate when something
/// terminal sits beside the cell (an arrowhead, a ring it arrived at, a
/// label that interrupted it); otherwise the ink simply ends in space.
fn stubLadder(v: cell.View, x: u32, y: u32, c: *counts.Counts) void {
    for (cell.dirs) |d| {
        const n = v.arm(x, y, d) orelse continue;
        switch (n.kind) {
            .arrow, .ring_node, .ring_frame, .glyph => {
                c.c_stub_terminal += 1;
                return;
            },
            else => {},
        }
    }
    c.d_stroke_stub += 1;
}

/// Arity census for a cell with two or more arms.
fn census(ink: u4, c: *counts.Counts) void {
    switch (@popCount(ink)) {
        2 => {
            const ns = cell.bit(.north) | cell.bit(.south);
            const ew = cell.bit(.east) | cell.bit(.west);
            if (ink == ns or ink == ew) c.m_straight_cells += 1 else c.m_corner_cells += 1;
        },
        3 => c.m_tee_cells += 1,
        else => c.m_cross_cells += 1,
    }
}

/// Per-arm ladder for a cell with two or more arms. First match wins, so
/// every set arm lands in exactly one bucket (or none, when it is
/// healthy). `interior` is this cell's interior verdict: when it holds,
/// the into-fill increments are suppressed because the crossing was
/// already counted once at cell level.
fn armPass(v: cell.View, x: u32, y: u32, t: cell.Typed, interior: bool, c: *counts.Counts) void {
    for (cell.dirs) |d| {
        if (t.ink & cell.bit(d) == 0) continue;
        const n = v.arm(x, y, d) orelse {
            // Off-grid: reconcile clears exactly this, so a survivor is a
            // post-reconcile regression, not an unrepaired upstream mask.
            c.d_arm_dangling += 1;
            continue;
        };
        switch (n.kind) {
            .fill => if (!interior) {
                c.d_arm_into_fill += 1;
            },
            .ghost => c.c_arm_into_ghost += 1,
            .blank => if (v.gapReprieve(x, y, d)) {
                c.c_arm_gap_reprieved += 1;
            } else {
                c.d_arm_dangling += 1;
            },
            .stroke => if (n.mask & cell.bit(cell.reverse(d)) == 0) {
                // Measurement only: the reciprocity-repair pass has its
                // own guards (straight-run, popcount, occupant) and this
                // deliberately does not reproduce them.
                c.m_arm_asym += 1;
            },
            .arrow, .glyph, .ring_node, .ring_frame => {},
        }
    }
}

/// Collinear double-write: two ADJACENT straight-through stroke cells of
/// different edges, reciprocating along their shared axis. Visually the
/// two runs are one line, and nothing in the render says otherwise.
///
/// Scanned east and south only, so each ordered pair is visited once.
///
/// Two gates keep the legal populations out. Both cells must carry the
/// FULL straight pair of the shared axis — that excludes the bus-bar
/// shape, where a rail cell holds one drop arm above a tap's straight
/// dropper and the trunk id differs from the tap's by design. And
/// neither cell may be a JUNCTION (three or four arms): where runs
/// genuinely meet, the cell's id is whichever run arrived first and says
/// nothing about fusion.
///
/// Documented bias: first-writer-wins gives fully overlapping runs a
/// single id, so this UNDER-counts — the safe direction for a defect
/// bucket.
fn fusion(v: cell.View, x: u32, y: u32, t: cell.Typed, c: *counts.Counts) void {
    const ae = t.edge orelse return;
    for ([2]cell.Dir4{ .east, .south }) |d| {
        const axis = axisPair(d);
        if (t.ink & axis != axis) continue;
        const n = v.arm(x, y, d) orelse continue;
        if (n.kind != .stroke) continue;
        if (n.ink & axis != axis) continue;
        const be = n.edge orelse continue;
        if (ae == be) continue;
        if (@popCount(t.ink) > 2 or @popCount(n.ink) > 2) {
            c.c_run_fused_crossing += 1;
        } else {
            c.d_run_fused_collinear += 1;
        }
    }
}

/// All stroke laws for ONE cell. Called from `scan.run`'s single
/// ownership dispatch, which guarantees `t.kind == .stroke`.
pub fn check(v: cell.View, x: u32, y: u32, t: cell.Typed, c: *counts.Counts) void {
    const interior = inkInInterior(v, x, y);
    if (interior) c.d_ink_in_interior += 1;

    switch (@popCount(t.ink)) {
        0 => c.d_stroke_armless += 1,
        1 => stubLadder(v, x, y, c),
        else => {
            census(t.ink, c);
            armPass(v, x, y, t, interior, c);
            fusion(v, x, y, t, c);
        },
    }
}
