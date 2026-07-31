//! ON-RUN edge-label placement for fan members: a horizontal label written
//! OVER the member's own PRIVATE vertical dropper, interrupting the stroke
//! for exactly one row. Tried BEFORE the labels_edge ladder (top priority);
//! any refusal falls through to that ladder unchanged.
//!
//! Two inviolable laws (owner directive):
//!
//!   RULE A (edge-only) — the label may interrupt ONLY the edge's own
//!   private ink. The interrupted cell must be an `edge_segment` carrying
//!   this edge's id with a `fan_*_dropper` role and pure vertical
//!   neighbour bits (never a rail/crossbar/trunk/junction cell), and no
//!   OTHER edge's Sketch geometry (polyline, bus-bar stem/crossbar, or a
//!   sibling tap's drop) may cover it. A reader must never wonder which
//!   member of a shared run a label names.
//!
//!   RULE B (flanked resumption) — the interrupted run must show a LINE
//!   GLYPH cell of the SAME edge's run directly above AND below the label
//!   row. A flank is an `edge_segment` of this edge, non-rail role, with
//!   collinear vertical neighbour bits (n and s, no e/w). An ARROWHEAD is
//!   NOT a flank: the canonical decorated column reads
//!   `│` (run), label, `│` (run), `▼` (head), border — the head sits BELOW
//!   the lower flank, never adjacent to the text. If either flank is
//!   missing the candidate is illegal. A decorated member therefore needs
//!   a private interior of >= 4 cells (flank, label, flank, head) where an
//!   undecorated one needs 3; `layout/fan.zig`'s LABEL_RUN_EXTRA_ROWS
//!   reserves for that, and a run that still cannot host the full sandwich
//!   simply refuses and falls to the ordinary labels_edge ladder.
//!
//!   HALF-STROKE LEADS — the two flank cells are the run's lead-in and
//!   lead-out to the text, so they paint as HALF strokes: the cell ABOVE
//!   the label becomes `╵` (U+2575, upper half — the run continues from
//!   above and stops short of the text) and the cell BELOW becomes `╷`
//!   (U+2577, lower half). This is expressed in the Cell, never in the
//!   painter: the flank loses the neighbour bit facing the label row
//!   (truthfully — there is no stroke there any more) so the junction
//!   table's single-bit entries pick `╵`/`╷` on their own, and its
//!   `stroke_kind` is forced to `.solid` so the same two glyphs are used
//!   for dotted and thick edges too. That last part is a DELIBERATE
//!   FALLBACK: Unicode has no dashed or double-line half-stroke, so a
//!   `┊`/`║` run leads into its label with a solid half tick.
//!
//! Everything lateral keeps the ordinary LAW 2 isolation
//! (labels_ink.spanIsolated): the own-run seams are exempt because the
//! flanks classify as own ink; foreign ink margins and the 2-blank
//! same-row separation are enforced untouched.
//!
//! SCOPE: vertical droppers only (TD fans). Horizontal runs / LR graphs
//! are out of scope and never match (the role + vertical-bits gate).
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

/// Try the on-run candidate for a routed fan-member edge: every vertical
/// polyline segment offers its strict interior rows, walked from the
/// middle outward. Returns true iff the label was written.
pub fn tryOnRunEdge(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    ep: sketch.EdgePath,
    label: []const u8,
    sink: aux.Sink,
) bool {
    if (ep.polyline.len < 2) return false;
    for (ep.polyline[0 .. ep.polyline.len - 1], 0..) |p, i| {
        const q = ep.polyline[i + 1];
        if (p.x != q.x or p.y == q.y) continue; // vertical, non-degenerate only
        const owner: ink.Owner = .{ .edge_id = ep.id, .polyline = ep.polyline, .seg_a = p, .seg_b = q };
        if (tryRun(lat, s, ep.id, p.x, @min(p.y, q.y) + 1, @max(p.y, q.y) - 1, label, owner, sink)) return true;
    }
    return false;
}

/// Try the on-run candidate for a bus-bar tap: the run is the tap's own
/// drop, `tap.at` (crossbar cell, shared — never interruptible) exclusive
/// to `tap.landing` (node border) exclusive.
pub fn tryOnRunTap(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    tap: sketch.Tap,
    label: []const u8,
    sink: aux.Sink,
) bool {
    if (tap.at.x != tap.landing.x or tap.at.y == tap.landing.y) return false;
    const owner: ink.Owner = .{ .edge_id = tap.edge, .polyline = &.{}, .seg_a = tap.at, .seg_b = tap.landing };
    return tryRun(lat, s, tap.edge, tap.at.x, @min(tap.at.y, tap.landing.y) + 1, @max(tap.at.y, tap.landing.y) - 1, label, owner, sink);
}

/// Walk candidate interruption rows `[y_lo, y_hi]` on column `x` from the
/// middle outward (deterministic) and place at the first legal row.
fn tryRun(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    edge_id: u32,
    x: i32,
    y_lo: i32,
    y_hi: i32,
    label: []const u8,
    owner: ink.Owner,
    sink: aux.Sink,
) bool {
    if (y_lo > y_hi) return false;
    const cell_count: u32 = labels.cellSpanOf(label);
    if (cell_count == 0) return false;
    const mid: i32 = @divTrunc(y_lo + y_hi, 2);
    var d: i32 = 0;
    while (mid - d >= y_lo or mid + d <= y_hi) : (d += 1) {
        if (mid - d >= y_lo and tryAt(lat, s, edge_id, x, mid - d, label, cell_count, owner, sink)) return true;
        if (d > 0 and mid + d <= y_hi and tryAt(lat, s, edge_id, x, mid + d, label, cell_count, owner, sink)) return true;
    }
    return false;
}

/// One candidate row: RULE A on the interrupted cell, RULE B on the two
/// flanks, emptiness on every other span cell, LAW 2 isolation laterally,
/// then the write. All-or-nothing.
fn tryAt(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    edge_id: u32,
    x: i32,
    row: i32,
    label: []const u8,
    cell_count: u32,
    owner: ink.Owner,
    sink: aux.Sink,
) bool {
    // RULE A, structural half: the interrupted cell is this edge's own
    // private dropper ink — a straight vertical stroke, never a junction.
    // guarded-by: labels_onrun_test.zig "RULE A: a rail/crossbar cell is never interrupted"
    if (!privateDropperCell(lat, edge_id, x, row)) return false;
    // RULE A, geometric half: no other edge's Sketch geometry rides here.
    // guarded-by: labels_onrun_test.zig "RULE A: a cell another tap's drop covers is refused"
    if (coveredByOther(s, edge_id, x, row)) return false;
    // RULE B: a LINE GLYPH cell of this edge's own run directly above AND
    // below. An arrowhead does not qualify — the head must sit below the
    // lower flank, not against the text.
    // guarded-by: labels_onrun_test.zig "RULE B: an arrowhead is not a flank, so the head-adjacent row is refused"
    if (!runFlankCell(lat, edge_id, x, row - 1)) return false;
    if (!runFlankCell(lat, edge_id, x, row + 1)) return false;

    // Center the span on the dropper column.
    const cc: i32 = @intCast(cell_count);
    const start_x: i32 = x - @divTrunc(cc - 1, 2);
    if (row < 0 or @as(i64, row) >= lat.height) return false;
    if (start_x < 0) return false;
    const sx: u32 = @intCast(start_x);
    const urow: u32 = @intCast(row);
    if (sx + cell_count > lat.width) return false;

    // Every span cell other than the interrupted one must be empty.
    var i: u32 = 0;
    while (i < cell_count) : (i += 1) {
        const cx: i32 = start_x + @as(i32, @intCast(i));
        if (cx == x) continue;
        switch (lat.atConst(@intCast(cx), urow).occupant) {
            .empty => {},
            else => return false,
        }
    }

    // LAW 2 lateral isolation: full foreign-ink margin + 2-blank same-row
    // separation. The own-run seams are exempt by construction — the flank
    // cells classify as own ink. guarded-by: labels_onrun_test.zig "foreign ink beside the span still refuses the on-run candidate"
    if (!ink.spanIsolated(lat, owner, start_x, row, cell_count, false)) return false;

    // Writer-contract check (labels_write.zig): the on-run writer may
    // legally overwrite exactly the ONE own-edge dropper cell it verified
    // above; every other covered cell was proven empty.
    std.debug.assert(privateDropperCell(lat, edge_id, x, row));

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

    // Half-stroke leads: the two flank cells stop short of the text.
    // guarded-by: labels_onrun_test.zig "half-stroke leads: the flanks lose the bit facing the label and go solid"
    markHalfStroke(lat, x, row - 1, .toward_south);
    markHalfStroke(lat, x, row + 1, .toward_north);
    return true;
}

/// Which side of a flank cell faces the label row.
const TowardLabel = enum { toward_south, toward_north };

/// Turn a full `│` flank into the half stroke that leads into the label:
/// drop the neighbour bit facing the label row (there is no stroke there
/// any more, so the junction table's single-arm entries yield `╵` / `╷`)
/// and force the cell's stroke to `.solid`, so those same two glyphs are
/// used for a dotted or thick edge as well — the dotted/thick tables map
/// a lone vertical arm back to the FULL `┊` / `║`, and Unicode offers no
/// dashed or double-line half-stroke to use instead. The caller has
/// already proven the cell is this edge's own run flank.
///
/// Both the occupant's `kind` and the Cell's `stroke_kind` are set: the
/// painter reads the former for an `edge_segment`, and leaving the two
/// disagreeing would strand a stale second opinion on the same cell.
fn markHalfStroke(lat: *lattice.Lattice, x: i32, y: i32, toward: TowardLabel) void {
    const cell = lat.at(@intCast(x), @intCast(y));
    switch (toward) {
        .toward_south => cell.neighbours.s = false,
        .toward_north => cell.neighbours.n = false,
    }
    switch (cell.occupant) {
        .edge_segment => |*seg| seg.kind = .solid,
        else => unreachable, // runFlankCell proved this is an edge_segment
    }
    cell.stroke_kind = .solid;
}

/// True iff the cell at (x, y) is a private dropper cell of `edge_id`:
/// edge_segment, matching id, fan dropper role, and pure vertical
/// neighbour bits (a junction/corner has a horizontal arm and is refused).
fn privateDropperCell(lat: *const lattice.Lattice, edge_id: u32, x: i32, y: i32) bool {
    if (x < 0 or y < 0) return false;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= lat.width or uy >= lat.height) return false;
    const cell = lat.atConst(ux, uy);
    switch (cell.occupant) {
        .edge_segment => |seg| {
            if (seg.edge != edge_id) return false;
            switch (seg.role) {
                .fan_out_dropper, .fan_in_dropper => {},
                else => return false,
            }
        },
        else => return false,
    }
    const n = cell.neighbours;
    return n.n and n.s and !n.e and !n.w;
}

/// RULE B flank: a LINE GLYPH cell of this edge's own run at (x, y) — an
/// `edge_segment` of this edge, non-rail role, with collinear vertical
/// neighbour bits. An arrowhead, a shared rail cell, a corner (which
/// carries a horizontal arm) and any foreign occupant all fail.
fn runFlankCell(lat: *const lattice.Lattice, edge_id: u32, x: i32, y: i32) bool {
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
    return n.n and n.s and !n.e and !n.w;
}

/// RULE A cross-check against the Sketch: true iff any OTHER edge's
/// geometry covers (x, y) — another EdgePath's polyline, or any bus-bar's
/// stem, crossbar, or a DIFFERENT tap's drop. The bus-bar shared run is
/// shared even for its own members, so it is never exempt.
fn coveredByOther(s: sketch.Sketch, edge_id: u32, x: i32, y: i32) bool {
    for (s.edges) |other| {
        if (other.id == edge_id) continue;
        if (other.polyline.len < 2) continue;
        for (other.polyline[0 .. other.polyline.len - 1], 0..) |p, i| {
            if (onSeg(p, other.polyline[i + 1], x, y)) return true;
        }
    }
    for (s.busbars) |bb| {
        for (bb.stem[0 .. bb.stem.len - 1], 0..) |p, i| {
            if (onSeg(p, bb.stem[i + 1], x, y)) return true;
        }
        if (onSeg(bb.crossbar[0], bb.crossbar[1], x, y)) return true;
        for (bb.taps) |tap| {
            if (tap.edge == edge_id) continue;
            if (onSeg(tap.at, tap.landing, x, y)) return true;
        }
    }
    return false;
}

fn onSeg(a: sketch.Point, b: sketch.Point, x: i32, y: i32) bool {
    if (a.x != b.x and a.y != b.y) return false;
    return x >= @min(a.x, b.x) and x <= @max(a.x, b.x) and
        y >= @min(a.y, b.y) and y <= @max(a.y, b.y);
}

test {
    _ = @import("labels_onrun_test.zig");
}
