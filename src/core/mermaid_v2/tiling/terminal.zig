//! Terminal-abutment law for the report-only structural audit: what
//! happens where a run STOPS against a ring.
//!
//! Every edge ends on something. The interesting question is not whether
//! ink touches a border — it always does — but WHICH border cell it
//! touches and whether that touch is one the rasterizer knows how to
//! make. So this walks the pairs (ink cell, direction, ring cell reached)
//! and files each one:
//!
//!   DEPARTURE      the ring cell holds a `.port` record: an edge attached
//!                  a departure stroke to it (`drawPortStroke` files one
//!                  for every stroke it actually merges). This is the one
//!                  verdict that used to be an INFERENCE — "the ring
//!                  carries the arm back, and only a departure could have
//!                  put it there". It could not: the arrowhead-base weld
//!                  ORs an arm into a border cell too. The record says
//!                  which, so the pair is now classified on evidence and
//!                  the residual arms get their own bucket.
//!   NODE FACE      the standard arrival. All four combinations — vertical
//!                  or horizontal face, bare stroke or arrowhead — are
//!                  conventions, because nothing in the rasterizer ever
//!                  writes a reciprocal bit into a TARGET border. A defect
//!                  bucket here would fire on every plain `A --> B`.
//!   NODE CORNER    a defect: ports are issued as face offsets only, so a
//!                  run that lands on a corner missed the face it aimed at.
//!   FRAME BARE     frame-solid: a stroke abutting a subgraph border is
//!                  how a bridge crosses it.
//!   FRAME + ARROW  a defect: a genuine arrival INTO a cluster replaces the
//!                  frame cell with the arrowhead, so an arrowhead still
//!                  sitting against untouched frame stopped one cell short.
//!
//! OWNERSHIP (see `scan.zig`). This family owns exactly the directions no
//! other check claims: for an arrowhead, the TIP direction (the laterals
//! belong to `arrows.checkLateral`, the base cell to `arrows.checkBase`);
//! for a stroke, the arms whose target is a RING (`strokes.armPass` files
//! ring targets under no bucket, because a ring is real and the dangling
//! law is silent there).
//!
//! GHOSTS never enter: an invisible edge is `.ghost`, not `.stroke`, so it
//! is not an ink cell and its cells cannot start a pair. A ghost reached
//! by someone else's arm is not a ring, so it ends no pair either.
//!
//! Imports: `std`, `prim`, `lattice.zig`, tiling siblings.

const std = @import("std");
const cell = @import("cell.zig");
const counts = @import("counts.zig");
const lattice = @import("../lattice.zig");

/// True for the four corner roles — the ring positions a perimeter port
/// can never name.
fn isCorner(role: lattice.BorderRole) bool {
    return switch (role) {
        .corner_nw, .corner_ne, .corner_se, .corner_sw => true,
        .edge_n, .edge_e, .edge_s, .edge_w => false,
    };
}

/// True when the face `role` runs horizontally (a north or south side),
/// i.e. the run reaching it arrives along the VERTICAL axis.
fn isVerticalFace(role: lattice.BorderRole) bool {
    return switch (role) {
        .edge_n, .edge_s => true,
        else => false,
    };
}

/// File one abutting (ink, ring) pair that is NOT reciprocated and NOT
/// reached across a gap. `is_arrow` distinguishes an arrowhead's tip from
/// a bare stroke arm — the distinction that separates a legal frame
/// crossing from an arrival that stopped short.
fn bucket(r: cell.Typed, is_arrow: bool, c: *counts.Counts) void {
    const role = r.role orelse return;
    if (r.kind == .ring_frame) {
        if (is_arrow) {
            c.d_term_frame_arrow += 1;
        } else if (isCorner(role)) {
            c.c_term_frame_corner += 1;
        } else {
            c.c_term_frame_bare += 1;
        }
        return;
    }
    if (isCorner(role)) {
        c.d_term_node_corner += 1;
        return;
    }
    if (isVerticalFace(role)) {
        if (is_arrow) c.c_term_node_ns_arrow += 1 else c.c_term_node_ns_bare += 1;
    } else {
        if (is_arrow) c.c_term_node_ew_arrow += 1 else c.c_term_node_ew_bare += 1;
    }
}

/// Follow ONE direction out of an ink cell and, when it ends on a ring,
/// file the pair. Directions that end on anything else belong to another
/// check family and are left untouched here.
fn abutment(v: cell.View, x: u32, y: u32, d: cell.Dir4, is_arrow: bool, c: *counts.Counts) void {
    const n = v.arm(x, y, d) orelse return;
    switch (n.kind) {
        .ring_node, .ring_frame => {
            c.n_term_abut += 1;
            // Departure first, and from the record rather than the mask:
            // `drawPortStroke` files a `.port` for every stroke it merges
            // into a source border, so a pair whose ring cell holds one is
            // a departure by evidence.
            // guarded-by: terminal_test.zig "departure: a port record claims the pair before any face verdict"
            if (n.ports().len != 0) {
                c.c_term_departure_recorded += 1;
                return;
            }
            // An arm pointing back with nothing recorded behind it belongs
            // to another writer (the arrowhead-base weld). It is not a
            // departure, and drawing an ARRIVAL verdict from a cell whose
            // mask another pass edited would be the same inference in
            // reverse — so this family stays silent about it.
            // guarded-by: terminal_test.zig "an unrecorded ring arm is neither a departure nor a face verdict"
            if (n.mask & cell.bit(cell.reverse(d)) != 0) {
                c.c_term_ring_arm_unrecorded += 1;
                return;
            }
            bucket(n, is_arrow, c);
        },
        .blank => {
            // The port-padding reprieve: a run may resume one cell further
            // along the axis. A ring reached that way is still a terminal
            // pair, but the gap itself is the rasterizer's convention, so
            // no face/corner verdict is drawn from it. When the walk is
            // NOT reprieved the arm is simply dangling — that is the
            // stroke family's property, and this check stays silent.
            if (!v.gapReprieve(x, y, d)) return;
            const two = cell.step(x, y, d, v.width(), v.height()) orelse return;
            const beyond = cell.step(two.x, two.y, d, v.width(), v.height()) orelse return;
            const t = v.at(beyond.x, beyond.y) orelse return;
            if (t.kind != .ring_node and t.kind != .ring_frame) return;
            c.n_term_abut += 1;
            c.c_term_gap_reprieved += 1;
        },
        else => {},
    }
}

/// Terminal law for ONE cell. Called from `scan.run`'s single ownership
/// dispatch for stroke and arrowhead cells; every other kind is inert.
pub fn check(v: cell.View, x: u32, y: u32, t: cell.Typed, c: *counts.Counts) void {
    switch (t.kind) {
        // An arrowhead's run IS its tip axis, and the tip is the only
        // direction this family owns on such a cell.
        .arrow => {
            const tip = t.tip orelse return;
            abutment(v, x, y, tip, true, c);
        },
        .stroke => for (cell.dirs) |d| {
            if (t.ink & cell.bit(d) == 0) continue;
            abutment(v, x, y, d, false, c);
        },
        else => {},
    }
}
