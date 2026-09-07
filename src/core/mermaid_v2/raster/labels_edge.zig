//! Edge and rail tap label placement: anchors at the edge's mid-segment,
//! then falls back through a bounded, deterministic ladder.
//!
//! The ladder is a three-pass priority over one fixed candidate order
//! (primary anchor, own-segment walk, remaining polyline segments):
//!
//!   own_adjacent (relocate-before-reroute) — only positions whose nearest ink within
//!      Chebyshev distance 2 is the label's OWN edge's ink (the primary
//!      anchor is tried first, so unpressured seeds stay put);
//!   own_nearest (unambiguous ownership) — positions strictly nearer (Chebyshev, up
//!      to distance 4) to the own edge's ink than to any other edge's ink;
//!   any (far displacement) — the remaining candidates, ownership-blind.
//!
//! Every pass additionally enforces the ISOLATION LAW (label-region isolation)
//! (labels_ink.spanIsolated): a full 8-neighbourhood margin against all
//! FOREIGN ink, own-edge ink exempt, plus >= 2 blank cells of same-row
//! separation between label runs. Dropped (edge_label_no_space) only when
//! every candidate fails every pass.
//!
//! Import boundary: std, prim, sketch, lattice, raster siblings only (same
//! zone as labels.zig; enforced by tools/lint_imports.zig).

const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels = @import("labels.zig");
const lw = @import("labels_write.zig");
const aux = @import("aux.zig");
const ink = @import("labels_ink.zig");

const log = std.log.scoped(.@"mermaid_v2.raster.labels");

/// RELOCATION LAW ladder pass, in priority order. `own_adjacent` = nearest ink
/// within OWN_ADJ_RADIUS is the label's own edge; `own_nearest` = own ink
/// within OWN_NEAR_RADIUS and strictly nearer than any foreign edge's ink;
/// `any` = no ownership requirement (full isolation still enforced);
/// `any_solid` = last resort before the drop path — ownership-blind AND
/// waives only the node/cluster-border half of the isolation margin
/// (spanIsolated `allow_solid`), so a label abuts a border rather than
/// vanishing. The foreign-EDGE margin is never waived in any pass.
const Pass = enum { own_adjacent, own_nearest, any, any_solid };
const passes = [4]Pass{ .own_adjacent, .own_nearest, .any, .any_solid };

/// own_adjacent: how far (Chebyshev) the span may sit from its own edge's ink and
/// still count as "adjacent" — 2 keeps the vertical-rail convention anchor
/// (mid_x + 2) an own_adjacent position.
const OWN_ADJ_RADIUS: u32 = 2;
/// own_nearest: the bounded search horizon for "strictly nearer to own ink".
const OWN_NEAR_RADIUS: u32 = 4;

pub const SegPair = struct { a: sketch.Point, b: sketch.Point };

pub fn pickMidSegment(poly: []const sketch.Point) ?SegPair {
    var count: usize = 0;
    for (poly[0 .. poly.len - 1], 0..) |p, i| {
        const q = poly[i + 1];
        if (p.x != q.x or p.y != q.y) count += 1;
    }
    if (count == 0) return null;
    const target = count / 2;
    var seen: usize = 0;
    for (poly[0 .. poly.len - 1], 0..) |p, i| {
        const q = poly[i + 1];
        if (p.x == q.x and p.y == q.y) continue;
        if (seen == target) return .{ .a = p, .b = q };
        seen += 1;
    }
    return null;
}

/// Outcome of one label's ladder walk. `displaced` (placed, but not at
/// the primary anchor) is a cheaper shipped defect than `dropped` — the
/// raster report counts both so the candidate score can price the
/// difference (a fold whose labels only fit at far fallbacks must not
/// score identically to a layout whose labels sit at convention anchors).
pub const Placement = enum { at_anchor, displaced, dropped };

pub fn placeEdgeLabel(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(labels.LabelDiagnostic),
    lat: *lattice.Lattice,
    ep: sketch.EdgePath,
    run: lw.Run,
    sink: aux.Sink,
) labels.RasterError!Placement {
    if (ep.polyline.len < 2) return .dropped;

    const seg_pair = pickMidSegment(ep.polyline) orelse return .dropped;
    return placeLabelAtSeg(allocator, diags, lat, ep.id, run, seg_pair.a, seg_pair.b, ep.label_left_of_run, ep.polyline, sink);
}

/// Shared anchored-placement body for edge and rail tap labels.
/// `polyline` supplies the fallback segments for the tail of the ladder;
/// rail taps pass `&.{}` (the tap segment is the only geometry they own).
pub fn placeLabelAtSeg(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(labels.LabelDiagnostic),
    lat: *lattice.Lattice,
    edge_id: u32,
    run: lw.Run,
    a: sketch.Point,
    b: sketch.Point,
    left_of_run: bool,
    polyline: []const sketch.Point,
    sink: aux.Sink,
) labels.RasterError!Placement {
    // Lattice cells the label occupies (`run.cell_count`), counted the way
    // it is written: one per grapheme head, two for an East-Asian-Wide
    // one. Probe, bounds test, flank test, emptiness scan and the write
    // loop all share this single number, so a wide label can never reserve
    // less space than it paints. Anchors use `run.width`, the display
    // columns the layout reserved. // @guarded-by: labels_eaw_test.zig "edge-label probe reserves display cells: a wide label no longer overwrites the ink beside it"
    const owner: ink.Owner = .{ .edge_id = edge_id, .polyline = polyline, .seg_a = a, .seg_b = b };

    // Three-pass priority (RELOCATION LAW) over one fixed candidate order per pass:
    // primary anchor, own-segment walk, ladder tail. A position accepted by
    // an earlier pass is never reconsidered — the passes only weaken the
    // ownership requirement, so the walk is deterministic.
    // @guarded-by: labels_ladder_test.zig "the own_adjacent pass beats the primary anchor: the label relocates to sit by its own edge's ink"
    const anchor = anchorFor(a, b, left_of_run, run.width);
    for (passes) |pass| {
        // Candidate #1: legacy anchor recorded by layout on ep.label_left_of_run (clusters.computeBbox). @guarded-by: labels_test.zig "edge label fits above midpoint"
        if (tryWrite(lat, run, anchor.x, anchor.y, owner, pass, sink)) return .at_anchor;

        if (trySegment(lat, run, a, b, left_of_run, owner, pass, sink)) return .displaced;

        if (polyline.len >= 2) {
            for (polyline[0 .. polyline.len - 1], 0..) |p, i| {
                const q = polyline[i + 1];
                if (p.x == q.x and p.y == q.y) continue;
                if (p.x == a.x and p.y == a.y and q.x == b.x and q.y == b.y) continue;
                if (trySegment(lat, run, p, q, left_of_run, owner, pass, sink)) return .displaced;
            }
        }
    }

    _ = try emitEdgeNoSpace(allocator, diags, edge_id, run.width);
    return .dropped;
}

/// The primary (legacy) anchor for a segment: right-of-rail / above-the-
/// line convention, or the LEFT-of-rail width-lever anchor when layout
/// chose it.
fn anchorFor(a: sketch.Point, b: sketch.Point, left_of_run: bool, label_w: u32) prim.LabelAnchor {
    return if (left_of_run)
        prim.leftOfRailAnchor(a.x, a.y, b.x, b.y, label_w)
    else
        prim.edgeLabelAnchor(a.x, a.y, b.x, b.y, label_w, .{});
}

/// Try every fallback position this segment offers, in ladder order:
/// convention side first, walking outward from the midpoint. The primary
/// anchor for the FIRST segment is tried by the caller before this; for
/// ladder-tail segments the anchor cell recurs as the d=0 walk position.
fn trySegment(
    lat: *lattice.Lattice,
    run: lw.Run,
    a: sketch.Point,
    b: sketch.Point,
    left_of_run: bool,
    owner: ink.Owner,
    pass: Pass,
    sink: aux.Sink,
) bool {
    const orig_len: u32 = run.width;

    if (a.y == b.y) {
        // Horizontal segment: rows above then below the line, walked outward from the midpoint. @guarded-by: labels_test.zig "edge label falls back below the segment when above is out of bounds"
        const mid_x: i32 = @divTrunc(a.x + b.x, 2);
        const min_x = @min(a.x, b.x);
        const max_x = @max(a.x, b.x);
        const rows = [2]i32{ a.y - 1, a.y + 1 };
        for (rows) |row| {
            var d: i32 = 0;
            while (mid_x - d >= min_x or mid_x + d <= max_x) : (d += 1) {
                if (mid_x - d >= min_x and tryWrite(lat, run, mid_x - d, row, owner, pass, sink)) return true;
                if (d > 0 and mid_x + d <= max_x and tryWrite(lat, run, mid_x + d, row, owner, pass, sink)) return true;
            }
        }
        return false;
    }

    const mid_x: i32 = @divTrunc(a.x + b.x, 2);
    const mid_y: i32 = @divTrunc(a.y + b.y, 2);
    const min_y = @min(a.y, b.y);
    const max_y = @max(a.y, b.y);
    const right_x: i32 = mid_x + 2;
    const left_x: i32 = mid_x - 1 - @as(i32, @intCast(orig_len));
    const sides = if (left_of_run) [2]i32{ left_x, right_x } else [2]i32{ right_x, left_x };
    for (sides) |x| {
        var d: i32 = 0;
        while (mid_y - d >= min_y or mid_y + d <= max_y) : (d += 1) {
            if (mid_y - d >= min_y and tryWrite(lat, run, x, mid_y - d, owner, pass, sink)) return true;
            if (d > 0 and mid_y + d <= max_y and tryWrite(lat, run, x, mid_y + d, owner, pass, sink)) return true;
        }
    }
    return false;
}

/// RELOCATION LAW pass gate for one candidate span. `.any` is ownership-blind; the
/// two ownership passes measure nearest-ink Chebyshev distances and demand
/// the own edge's ink win (strictly, so a tie never yields an ambiguous
/// owner). // @guarded-by: labels_ladder_test.zig "the own_nearest pass walks the label toward its own edge's ink when own_adjacent positions are blocked"
fn passAllows(
    lat: *const lattice.Lattice,
    owner: ink.Owner,
    pass: Pass,
    start_x: i32,
    row: i32,
    cell_count: u32,
) bool {
    if (pass == .any or pass == .any_solid) return true;
    const d = ink.inkDistances(lat, owner, start_x, row, cell_count, OWN_NEAR_RADIUS);
    const own = d.own orelse return false;
    const limit: u32 = if (pass == .own_adjacent) OWN_ADJ_RADIUS else OWN_NEAR_RADIUS;
    if (own > limit) return false;
    if (d.foreign_edge) |f| {
        if (own >= f) return false;
    }
    return true;
}

/// Bounds-check the span, enforce the ISOLATION LAW (foreign-ink margin +
/// same-row run separation, labels_ink.spanIsolated), require every cell
/// empty, apply the RELOCATION LAW pass gate, then write one label_char cell per
/// grapheme head. All-or-nothing per candidate.
fn tryWrite(
    lat: *lattice.Lattice,
    run: lw.Run,
    lx: i32,
    ly: i32,
    owner: ink.Owner,
    pass: Pass,
    sink: aux.Sink,
) bool {
    if (ly < 0 or @as(i64, ly) >= lat.height) return false;
    if (lx < 0) return false;
    const cell_count = run.cell_count;
    const start_x: u32 = @intCast(lx);
    const row: u32 = @intCast(ly);
    if (start_x + cell_count > lat.width) return false;

    // ISOLATION LAW: a candidate touching FOREIGN ink anywhere in the span's
    // 8-neighbourhood is rejected (own-edge ink may abut, so convention
    // anchors beside the label's own run stay legal), and two label runs on
    // the same row keep >= 2 blank cells apart — a continuation column
    // counts as a label neighbour. The final `any_solid` pass tolerates
    // node/cluster-border abutment only.
    // @guarded-by: labels_test.zig "edge-label runs on the same row keep two blank cells apart"
    // @guarded-by: labels_eaw_test.zig "blank-flank rule treats a continuation as a label neighbour"
    if (!ink.spanIsolated(lat, owner, lx, ly, cell_count, pass == .any_solid)) return false;

    // Any non-empty cell is a genuine collision (edges/earlier labels are rasterized first) — reject the candidate. // @guarded-by: labels_test.zig "tryWrite rejects a pre-occupied primary-anchor cell as a real collision, not an OOB miss"
    var i: u32 = 0;
    while (i < cell_count) : (i += 1) {
        const cell = lat.atConst(start_x + i, row);
        switch (cell.occupant) {
            .empty => {},
            else => return false,
        }
    }

    if (!passAllows(lat, owner, pass, lx, ly, cell_count)) return false;

    lw.writeRun(lat, start_x, row, run, .{ .kind = .edge, .id = owner.edge_id }, sink);
    return true;
}

fn emitEdgeNoSpace(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(labels.LabelDiagnostic),
    edge_id: u32,
    orig_len: u32,
) labels.RasterError!bool {
    log.debug(
        "raster/labels: edge {d} has no space for label (len={d}); skipping",
        .{ edge_id, orig_len },
    );
    try diags.append(allocator, .{
        .kind = .edge_label_no_space,
        .node_or_edge_or_cluster_id = edge_id,
        .original_len = orig_len,
        .placed_len = 0,
    });
    return false;
}
