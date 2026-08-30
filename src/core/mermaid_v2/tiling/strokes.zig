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
//! Allowed imports (tools/lint_imports.zig): the tiling zone — `std`,
//! `prim`, the `base/` no-deps tier, `../lattice.zig`, and tiling siblings
//! (never sem_graph or sketch: those are granted per-file to expect/scan
//! only). Actually imports `std`, `../lattice.zig`, `cell.zig`,
//! `counts.zig` — the lattice one purely for `CarrierKind`, the alphabet
//! the side table's carrier records are written in.

const std = @import("std");
const lattice = @import("../lattice.zig");
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
                // Measurement only, and deliberately unguarded: every
                // half-open pair the shipped mask holds is reported, on no
                // theory of which side meant it. No pass closes such a
                // pair, so this reads the picture as drawn.
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
/// FULL straight pair of the shared axis — that excludes the rail
/// shape, where a rail cell holds one drop arm above a tap's straight
/// dropper and the rail id differs from the tap's by design. And
/// neither cell may be a JUNCTION (three or four arms): where runs
/// genuinely meet, the cell's id is whichever run arrived first and says
/// nothing about fusion.
///
/// Documented bias: first-writer-wins gives fully overlapping runs a
/// single id, so this UNDER-counts — the safe direction for a defect
/// bucket.
///
/// The junction branch is DECOMPOSED, not judged wholesale. "The runs
/// genuinely meet there" only holds when the two edges legally share a
/// bundle at that position; where they do not, the junction glyph asserts
/// an adjacency no source declares. `licence` below reads that verdict off
/// the carrier records, and the parent bucket keeps counting the whole
/// population so the three verdicts stay auditable against it.
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
        if (isJunction(t) or isJunction(n)) {
            c.c_run_fused_crossing += 1;
            switch (licence(t, be, n, ae)) {
                .unlicensed => c.d_run_fused_foreign += 1,
                .licensed => c.c_run_fused_licensed += 1,
                .unevidenced => c.u_run_fused_unevidenced += 1,
            }
        } else {
            c.d_run_fused_collinear += 1;
        }
    }
}

/// The junction question, answered from the RECORDED ink-attribution state (cell-grid boundary): the
/// producer wrote `.junction` at the moment it merged an owner-set change;
/// this consumer reads it instead of re-deriving it from arm arity. An
/// UNTAGGED cell (state `.none` — a hand-built lattice with no producer)
/// falls back to the retired arity heuristic so fixtures stay
/// expressible; production renders never reach the fallback
/// (`m_state_untagged` is pinned to zero there), and every divergence
/// between the two answers is counted by `state.zig`.
fn isJunction(t: cell.Typed) bool {
    return switch (t.state) {
        .junction => true,
        .none => @popCount(t.ink) > 2,
        else => false,
    };
}

/// What the recorded facts say about the junction the pair paints.
const Verdict = enum { unlicensed, licensed, unevidenced };

/// The verdict for one junction pair, from carrier records ALONE.
///
/// The authoritative positions are the JUNCTION cells of the pair — per
/// the recorded ink-attribution state (`isJunction`) — because a licence CAN be position-scoped (a
/// `.port_share` bundle answers only on its own cells; a structural one
/// answers everywhere), and the only position whose answer certainly bears
/// on the disputed glyph is the one the glyph occupies. Reading only there
/// is the conservative choice, not a derivation: the non-junction cell's
/// records answer a question about a different position and are not a
/// fallback.
///
/// At such a cell, a carrier record naming the OTHER cell's edge is the
/// transcript of one crossing decision: the record says "the edge named by
/// `value` has ink here that this Cell does not name", and the Cell's own
/// surviving id supplies the other half of the pair the producer handed to
/// the crossing rule. Any FOREIGN record decides, from either end.
/// guarded-by: strokes_test.zig "fusion: only a JUNCTION cell's records answer, and either junction may"
/// guarded-by: strokes_test.zig "fusion: precedence — any foreign record outranks a licensed one, in either order"
fn licence(t: cell.Typed, b: u32, n: cell.Typed, a: u32) Verdict {
    var seen_licensed = false;
    if (isJunction(t) and tally(t, b, &seen_licensed)) return .unlicensed;
    if (isJunction(n) and tally(n, a, &seen_licensed)) return .unlicensed;
    return if (seen_licensed) .licensed else .unevidenced;
}

/// One junction cell's records about `other`: true when any of them states
/// FOREIGN. `licensed` is raised by any that states LICENSED. A record of
/// an unknown or untested kind raises neither — it states nothing, and
/// nothing is never consent.
fn tally(t: cell.Typed, other: u32, licensed: *bool) bool {
    var foreign = false;
    for (t.carriers()) |r| {
        if (r.value != other) continue;
        const kind = std.meta.intToEnum(lattice.CarrierKind, r.detail) catch continue;
        switch (kind) {
            .suppressed, .merged_foreign => foreign = true,
            .merged_licensed => licensed.* = true,
            .merged_untested => {},
        }
    }
    return foreign;
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
