//! ON-RUN edge-label placement in a HORIZONTAL private run: the label text
//! sits INLINE in the stroke — `────── label ──────` — interrupting the run
//! for exactly `cellSpanOf(label)` columns on one row. The vertical sibling
//! (labels_onrun.zig) writes the text ACROSS a private dropper; this one
//! writes it ALONG the run, so the interrupted stretch is the whole label
//! span rather than a single cell.
//!
//! The two inviolable laws are the vertical form's, verbatim:
//!
//!   RULE A (edge-only) — every interrupted cell must be this edge's own
//!   PRIVATE horizontal ink: an `edge_segment` carrying this edge's id, a
//!   non-rail role (never a fan crossbar / bus-bar rail cell), and pure
//!   HORIZONTAL neighbour bits (`e and w`, no `n`/`s` — a corner or a
//!   junction carries a vertical arm and is refused). The same DOUBLE
//!   enforcement as the vertical form applies: the occupant role/id test
//!   above plus a Sketch-geometry sweep (`labels_onrun.coveredByOther`)
//!   proving no OTHER edge's polyline, bus-bar stem, crossbar or tap drop
//!   rides any covered cell.
//!
//!   RULE B (flanked resumption) — a full-stroke run cell of the SAME
//!   edge's own kind (`─`/`╌`/`═`) must sit immediately LEFT and
//!   immediately RIGHT of the label on the same row, and must itself pass
//!   the horizontal-run test. Arrowheads (a different occupant) and
//!   corners (vertical bits set) are NOT flanks, which is exactly the
//!   "skip a segment carrying a corner inside the flank cell"
//!   conservatism: a segment's endpoints are corners, so the flank test
//!   refuses them structurally rather than by a special case.
//!
//! Consequences: a segment's strict interior must already hold
//! `label + 2 flanks` cells. There is NO layout stretching this round — an
//! infeasible segment simply refuses and the ordinary labels_edge ladder
//! runs unchanged, byte for byte.
//!
//! Isolation is the shared LAW 2 (`labels_ink.spanIsolated`): the full
//! 8-neighbourhood foreign-ink margin (rows above and below plus the two
//! diagonal ends) and the 2-blank same-row label separation. The own-run
//! seams at both ends of the span are exempt by construction — they
//! classify as OWN ink.
//!
//! Determinism: among a polyline's horizontal segments the LONGEST strict
//! interior is tried first (ties broken by polyline order), and within a
//! segment the label is CENTERED, walking outward from the centered start
//! (`mid - d` before `mid + d`) — the same middle-outward discipline the
//! vertical form uses on rows.
//!
//! Import boundary: std, sketch, lattice, raster siblings only (raster
//! zone; enforced by tools/lint_imports.zig).

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels = @import("labels.zig");
const lw = @import("labels_write.zig");
const aux = @import("aux.zig");
const ink = @import("labels_ink.zig");
const onrun = @import("labels_onrun.zig");

/// Segments considered per polyline. Routed polylines are short (the
/// widest today is the LR skip corridor at 6 points); a longer one simply
/// keeps its first `MAX_SEGS` segments, which stays deterministic.
const MAX_SEGS: usize = 32;

/// Longest strict-interior length among the polyline's horizontal
/// segments, 0 if it has none. Used by the vertical/horizontal tie order
/// in labels_onrun.zig — pure geometry, no lattice reads.
pub fn longestHorizontalInterior(polyline: []const sketch.Point) u32 {
    if (polyline.len < 2) return 0;
    var best: u32 = 0;
    for (polyline[0 .. polyline.len - 1], 0..) |p, i| {
        const q = polyline[i + 1];
        if (p.y != q.y or p.x == q.x) continue;
        const span: u32 = @intCast(@max(p.x, q.x) - @min(p.x, q.x));
        if (span < 1) continue;
        const interior: u32 = span - 1;
        if (interior > best) best = interior;
    }
    return best;
}

/// Try the inline-horizontal on-run candidate for a routed edge. Returns
/// true iff the label was written.
/// guarded-by: labels_onrun_h_test.zig "happy path: the label sits inline in its own horizontal run, flanked both sides"
pub fn tryOnRunEdgeH(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    ep: sketch.EdgePath,
    label: []const u8,
    sink: aux.Sink,
) bool {
    if (ep.polyline.len < 2) return false;
    const cell_count: u32 = labels.cellSpanOf(label);
    if (cell_count == 0) return false;

    var tried = [_]bool{false} ** MAX_SEGS;
    const nsegs = @min(ep.polyline.len - 1, MAX_SEGS);

    // Longest strict interior first, ties by polyline order: the widest
    // stretch is the one most likely to hold label + both flanks with the
    // isolation margin intact.
    var k: usize = 0;
    while (k < nsegs) : (k += 1) {
        var pick: ?usize = null;
        var pick_len: i32 = -1;
        var i: usize = 0;
        while (i < nsegs) : (i += 1) {
            if (tried[i]) continue;
            const p = ep.polyline[i];
            const q = ep.polyline[i + 1];
            if (p.y != q.y or p.x == q.x) continue;
            const len: i32 = @max(p.x, q.x) - @min(p.x, q.x) - 1;
            if (len > pick_len) {
                pick_len = len;
                pick = i;
            }
        }
        const idx = pick orelse return false;
        tried[idx] = true;
        const p = ep.polyline[idx];
        const q = ep.polyline[idx + 1];
        const owner: ink.Owner = .{ .edge_id = ep.id, .polyline = ep.polyline, .seg_a = p, .seg_b = q };
        if (tryRunH(lat, s, ep.id, p.y, @min(p.x, q.x) + 1, @max(p.x, q.x) - 1, label, cell_count, owner, sink)) return true;
    }
    return false;
}

/// Walk candidate start columns inside the strict interior `[x_lo, x_hi]`
/// of one horizontal segment on `row`, centered then outward.
fn tryRunH(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    edge_id: u32,
    row: i32,
    x_lo: i32,
    x_hi: i32,
    label: []const u8,
    cell_count: u32,
    owner: ink.Owner,
    sink: aux.Sink,
) bool {
    const cc: i32 = @intCast(cell_count);
    // Feasibility without any layout stretching: label + one flank cell on
    // each side must already fit in the segment's strict interior.
    // guarded-by: labels_onrun_h_test.zig "a too-short horizontal run falls through to the ordinary ladder"
    if (x_hi - x_lo + 1 < cc + 2) return false;
    const start_lo: i32 = x_lo + 1;
    const start_hi: i32 = x_hi - cc;
    const mid: i32 = @divTrunc(start_lo + start_hi, 2);
    var d: i32 = 0;
    while (mid - d >= start_lo or mid + d <= start_hi) : (d += 1) {
        if (mid - d >= start_lo and tryAtH(lat, s, edge_id, mid - d, row, label, cell_count, owner, sink)) return true;
        if (d > 0 and mid + d <= start_hi and tryAtH(lat, s, edge_id, mid + d, row, label, cell_count, owner, sink)) return true;
    }
    return false;
}

/// One candidate span: RULE A over every interrupted cell, RULE B on the
/// two same-row flanks, LAW 2 isolation, then the write. All-or-nothing.
fn tryAtH(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    edge_id: u32,
    start_x: i32,
    row: i32,
    label: []const u8,
    cell_count: u32,
    owner: ink.Owner,
    sink: aux.Sink,
) bool {
    const cc: i32 = @intCast(cell_count);
    if (row < 0 or @as(i64, row) >= lat.height) return false;
    if (start_x < 1) return false;
    const sx: u32 = @intCast(start_x);
    const urow: u32 = @intCast(row);
    if (sx + cell_count >= lat.width) return false;

    // RULE A, structural half: EVERY interrupted cell is this edge's own
    // private horizontal run ink — never a rail/crossbar/tap cell, never a
    // corner. // guarded-by: labels_onrun_h_test.zig "RULE A: a shared crossbar cell inside the stretch refuses the inline label"
    // RULE A, geometric half: no other edge's Sketch geometry rides here.
    // guarded-by: labels_onrun_h_test.zig "RULE A: a foreign-crossed stretch is refused by the geometry sweep"
    var i: i32 = 0;
    while (i < cc) : (i += 1) {
        const cx = start_x + i;
        if (!privateRunCellH(lat, edge_id, cx, row)) return false;
        if (onrun.coveredByOther(s, edge_id, cx, row)) return false;
    }

    // RULE B: a full-stroke run cell of this edge immediately left AND
    // right, on the same row. An arrowhead or a corner never qualifies.
    // guarded-by: labels_onrun_h_test.zig "RULE B: a corner or an arrowhead in the flank cell refuses the candidate"
    if (!runFlankCellH(lat, edge_id, start_x - 1, row)) return false;
    if (!runFlankCellH(lat, edge_id, start_x + cc, row)) return false;
    if (onrun.coveredByOther(s, edge_id, start_x - 1, row)) return false;
    if (onrun.coveredByOther(s, edge_id, start_x + cc, row)) return false;

    // LAW 2 isolation: foreign-ink margin above/below and at the diagonal
    // ends, plus the 2-blank same-row label separation. The own-run seams
    // are exempt — they classify as own ink.
    // guarded-by: labels_onrun_h_test.zig "foreign ink above the inline span refuses the candidate"
    if (!ink.spanIsolated(lat, owner, start_x, row, cell_count, false)) return false;

    // Writer-contract check (labels_write.zig): the inline writer may
    // legally overwrite exactly the own-edge private run cells verified
    // above, and nothing else.
    var j: i32 = 0;
    while (j < cc) : (j += 1) std.debug.assert(privateRunCellH(lat, edge_id, start_x + j, row));

    var wx: u32 = sx;
    var bi: usize = 0;
    while (bi < label.len) {
        const dc = labels.nextCodepoint(label, bi);
        bi += dc.byte_len;
        const cp = labels.sentinelToSpace(dc.cp);
        const span = labels.cellSpan(cp);
        lw.writeSpan(lat, wx, urow, cp, span, .{ .kind = .edge, .id = edge_id }, sink);
        wx += span;
    }
    return true;
}

/// True iff (x, y) is a private horizontal run cell of `edge_id`:
/// edge_segment, matching id, non-rail role, and pure horizontal
/// neighbour bits (a corner/junction carries a vertical arm and fails).
fn privateRunCellH(lat: *const lattice.Lattice, edge_id: u32, x: i32, y: i32) bool {
    if (x < 0 or y < 0) return false;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= lat.width or uy >= lat.height) return false;
    const cell = lat.atConst(ux, uy);
    switch (cell.occupant) {
        .edge_segment => |seg| {
            if (seg.edge != edge_id) return false;
            switch (seg.role) {
                .fan_out_rail, .fan_in_rail => return false,
                else => {},
            }
        },
        else => return false,
    }
    const n = cell.neighbours;
    return n.e and n.w and !n.n and !n.s;
}

/// RULE B flank. Identical to the interrupt test: a flank is just another
/// cell of the same private horizontal run, left untouched by the write so
/// it keeps painting the edge's own full stroke in its own kind.
fn runFlankCellH(lat: *const lattice.Lattice, edge_id: u32, x: i32, y: i32) bool {
    return privateRunCellH(lat, edge_id, x, y);
}

test {
    _ = @import("labels_onrun_h_test.zig");
}
