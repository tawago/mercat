//! PORT STROKES: how a run attaches to the wall it starts from or lands on.
//!
//! Split out of `edges_write.zig` (500-line cap). This file owns the two
//! symmetric writers `drawPortStroke` (departure) and `drawTargetPortStroke`
//! (arrival) and their shared tail `mergePortBit` — uniform port erasure on
//! all four faces, both ends of every run — plus the two rules that decide
//! what the attachment looks like: the port-tee FACING rule and the 1-cell
//! gap probe, whose approach is closed by PAINTING the gap at an
//! undecorated end and by SLIDING the arrowhead onto it at a decorated one
//! (`slideHead` — an arrowhead is terminal, so its tip side may carry no
//! ink). The per-cell claim contract and the directional primitives stay in
//! `edges_write.zig`, which this file imports.
//!
//! Imports: `std`, `sketch.zig`, `lattice.zig`, `edges_write.zig`, `aux.zig`.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ew = @import("edges_write.zig");
const aux = @import("aux.zig");

const Move = ew.Move;
const step = ew.step;
const reverse = ew.reverse;
const bitMask = ew.bitMask;
const orMask = ew.orMask;
const straightMask = ew.straightMask;
const segmentDir = ew.segmentDir;
const toCoord = ew.toCoord;
const pointInBounds = ew.pointInBounds;
const writeEdgeCell = ew.writeEdgeCell;

/// One end's arrowhead, as the port writers need to see it: the cell the
/// head was stamped on AND the direction its tip points. Both, because the
/// port-tee rule is about FACING, not mere nearness — a head beside the wall
/// pointing along the run past it is not the redundant `▼`-on-`┴` case.
/// The producer of a head must derive `cell` and `dir` from the same
/// geometry it hands the arrowhead stamp, so the gate and the glyph cannot
/// disagree about where the tip looks.
pub const Head = struct {
    cell: sketch.Point,
    dir: Move,
};

/// Everything a port stroke needs about the end it serves beyond the
/// polyline itself: the head (null for an undecorated end) and the routing
/// role to stamp on a painted gap cell.
pub const PortEnd = struct {
    head: ?Head = null,
    role: lattice.EdgeRole = .forward,
};

/// Draw the departure PORT: OR-merge the outgoing bit into the source
/// border cell on whichever face the polyline leaves through — all four
/// faces, symmetric with `drawTargetPortStroke` (uniform port erasure).
/// When the merging edge is non-solid, also stamp the border cell's
/// `stroke_kind` so the painter can pick variants like `╥`/`╨` for
/// thick edges meeting a solid node frame.
/// An invisible (`~~~`) edge draws no ink, so it must not tee the source
/// border: return before touching the cell.
/// `end.head` is this end's arrowhead, or null when the end carries no
/// head. Suppression is keyed to the head's FACING (see `mergePortBit`):
/// the bit is dropped only when the tip points AT the border cell, where
/// the tee behind it would be redundant.
/// guarded-by: edges_port_test.zig "a decorated source end whose head faces the wall leaves it pristine"
/// Every stroke actually drawn also files a `.port` record for `edge_id`
/// on the side table: the border cell keeps the merged arm but not the
/// identity of the edge that merged it, so the record adds a fact the
/// Cell cannot express (lattice.zig's anti-desync law). Refused strokes
/// (invisible edge, non-border cell) file nothing —
/// the channel records what was drawn, never what was intended.
/// guarded-by: edges_port_test.zig "drawPortStroke: an invisible edge leaves the source node border untouched"
/// guarded-by: aux_test.zig "drawPortStroke files a port record only for a stroke it actually draws"
pub fn drawPortStroke(
    lat: *lattice.Lattice,
    pts: []const sketch.Point,
    kind: lattice.EdgeKind,
    edge_id: u32,
    end: PortEnd,
    sink: aux.Sink,
) void {
    if (kind == .invisible) return;
    var first_dir_opt: ?Move = null;
    var fi: usize = 0;
    while (fi + 1 < pts.len) : (fi += 1) {
        if (segmentDir(pts[fi], pts[fi + 1])) |fd| {
            first_dir_opt = fd;
            break;
        }
    }
    const fd = first_dir_opt orelse return;
    mergePortBit(lat, pts[0], fd, kind, edge_id, end, sink);
}

/// Draw the arrival PORT: OR-merge the incoming arm into the TARGET border
/// cell at the polyline's final point — the perimeter cell the walk
/// deliberately skips (the arrowhead stamps the last INTERIOR cell). The
/// merged bit is `reverse(last_dir)`: it points back along the run, so the
/// border glyph becomes the tee facing the arriving stroke (`┴` on a
/// box-top TD arrival, `┤`/`├` on LR/RL). Same refusals and `.port` record
/// discipline as `drawPortStroke` — the two are the uniform port-erasure
/// pair, symmetric on all four faces, and both drop the bit only for a head
/// whose TIP FACES the border (`end.head`), so a `▼` never sits on a `┴`
/// while every other head still gets its wall attachment.
/// guarded-by: edges_port_test.zig "drawTargetPortStroke: arrival arms merge on all four faces"
/// guarded-by: edges_port_test.zig "a decorated arrival whose head faces the wall leaves it pristine"
/// guarded-by: edges_port_test.zig "a head adjacent to the wall but pointing ALONG the route still tees it"
pub fn drawTargetPortStroke(
    lat: *lattice.Lattice,
    pts: []const sketch.Point,
    kind: lattice.EdgeKind,
    edge_id: u32,
    end: PortEnd,
    sink: aux.Sink,
) void {
    if (kind == .invisible) return;
    var last_dir_opt: ?Move = null;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        if (segmentDir(pts[i], pts[i + 1])) |d| last_dir_opt = d;
    }
    const ld = last_dir_opt orelse return;
    mergePortBit(lat, pts[pts.len - 1], reverse(ld), kind, edge_id, end, sink);
}

/// Same cell, by value. `sketch.Point` is a plain integer pair, so identity
/// is coordinate equality.
fn samePoint(a: sketch.Point, b: sketch.Point) bool {
    return a.x == b.x and a.y == b.y;
}

/// True when `h`'s TIP faces `q`: one step from the head cell along the
/// head's own direction lands exactly on `q`. This — not mere nearness — is
/// the redundancy test. A head orthogonally ADJACENT to the wall but
/// pointing ALONG the route (a `◀` one row below a bottom wall, travelling
/// west) does not face it, and the wall still needs its tap or the run
/// floats detached beside a closed box.
/// guarded-by: edges_port_test.zig "a head adjacent to the wall but pointing ALONG the route still tees it"
fn tipFaces(h: Head, q: sketch.Point) bool {
    return samePoint(step(h.cell, h.dir), q);
}

/// Resolve what an end's polyline endpoint `p` actually attaches to, given
/// the direction `travel` in which the wall lies (the run's travel toward
/// the node at an arrival, the reverse of the departure direction at a
/// source). Returns null unless the attachment is a MERGEABLE node border —
/// a non-corner face — because that is the only landing the port writers
/// act on, and the head slide below must fire under exactly the same
/// condition or gate and glyph would disagree.
/// `gap` is the endpoint itself when the polyline stopped one cell short of
/// the wall (the 1-cell reprieve), null when the endpoint IS the wall.
const Attach = struct { border: sketch.Point, gap: ?sketch.Point };

fn attachment(lat: *const lattice.Lattice, p: sketch.Point, travel: Move) ?Attach {
    if (!pointInBounds(p, lat)) return null;
    var q = p;
    var gap: ?sketch.Point = null;
    // Probe exactly one cell, and only across an EMPTY endpoint, so the
    // stroke never jumps a real occupant.
    if (lat.atConst(toCoord(q).x, toCoord(q).y).occupant == .empty) {
        gap = q;
        q = step(q, travel);
        if (!pointInBounds(q, lat)) return null;
    }
    const c = toCoord(q);
    const cell = lat.atConst(c.x, c.y);
    if (cell.occupant != .node_border) return null;
    switch (cell.occupant.node_border.role) {
        .corner_nw, .corner_ne, .corner_se, .corner_sw => return null,
        else => {},
    }
    return .{ .border = q, .gap = gap };
}

/// THE HEAD SLIDE. An arrowhead cell is TERMINAL: its base side is fed by
/// its own collinear run, its laterals are empty, and its TIP side must
/// abut the attachment DIRECTLY. Ink on the tip side is never legal — so a
/// decorated end that stops one cell short of the wall must not paint the
/// gap behind its head (`├─◀`, a run cell between tip and border). Instead
/// the HEAD moves forward onto the gap cell, and the cell it vacates keeps
/// the ordinary run ink the walk already wrote there — a base-side
/// extension, which is legal: `│◀────┐`.
///
/// Returns `head` unchanged unless every part of the shape holds: the end
/// really attaches to a mergeable face, the endpoint really is a 1-cell
/// gap, and the head really sits one step behind that gap along its own
/// tip direction. `head.dir` IS the travel toward the wall at both ends
/// (an arrival's head points along the run; a departure's points back at
/// its source wall), so it serves as the probe direction too.
///
/// Once slid, the head's tip FACES the border, so `mergePortBit`'s facing
/// gate suppresses the tee (plain wall, no tap — the abutting-decorated
/// convention) and the gap-paint below is unreachable for it. The paint
/// therefore survives only for UNDECORATED gap ends, which have no head and
/// no tip-side constraint.
/// guarded-by: edges_slide_test.zig "a decorated gap arrival slides its head onto the border-adjacent cell"
/// guarded-by: edges_slide_test.zig "an occupied gap cell leaves the head where it is"
pub fn slideHead(lat: *const lattice.Lattice, endpoint: sketch.Point, head: Head) Head {
    const at = attachment(lat, endpoint, head.dir) orelse return head;
    const g = at.gap orelse return head;
    if (!samePoint(step(head.cell, head.dir), g)) return head;
    return .{ .cell = g, .dir = head.dir };
}

/// Shared tail of the two port-stroke writers: OR one directional arm into
/// a node-border cell (refusing every other occupant), stamp a non-solid
/// stroke, file the `.port` record for the stroke actually drawn.
///
/// THE PORT-TEE RULE. The bit is suppressed iff this end is decorated AND
/// the head's TIP FACES the port border cell — one step from the head cell
/// along the head's own direction IS the border, so the tee behind it is
/// redundant ink asserting a continuation past the border that does not
/// exist (`▼` sitting on `┴`, `▶` on `┤`). NEITHER DECORATION NOR MERE
/// ADJACENCY IS THE KEY. A head that sits beside the wall while pointing
/// ALONG the route (a `◀` one row under a bottom border, travelling west)
/// is not the redundant case at all: suppressing there leaves the wall
/// with no tap, and the arrowheads of a bidirectional pair float detached
/// below a closed box. Every non-facing head merges, exactly as uniform
/// erasure requires.
/// guarded-by: edges_port_test.zig "a head adjacent to the wall but pointing ALONG the route still tees it"
///
/// THE GAP APPROACH, FOR UNDECORATED ENDS ONLY. When the probe below
/// crosses a 1-cell port gap, the merge alone would leave `├ ` — a tee, a
/// blank — an arm reading into nothing. So the gap cell is PAINTED with
/// this edge's own stroke and the run comes out contiguous from wall to
/// run. The cell is empty by definition of the probe (it is the only
/// condition under which the probe fires), so the write claims background
/// and can lose nothing; anything occupying it refuses the probe and the
/// whole stroke upstream.
///
/// A DECORATED end never reaches the paint: `slideHead` has already moved
/// its arrowhead onto that gap cell, so the head's tip faces the border and
/// the facing gate above returns first. That is the point — painting behind
/// a head would put ink on its TIP side (`├─◀`), which the arrowhead
/// contract forbids. Undecorated ends have no head and no tip side, so the
/// paint is theirs alone.
/// guarded-by: edges_port_test.zig "an UNDECORATED gap arrival also gets tee, painted gap and run"
/// guarded-by: edges_slide_test.zig "a decorated gap arrival slides its head onto the border-adjacent cell"
fn mergePortBit(
    lat: *lattice.Lattice,
    p: sketch.Point,
    arm: Move,
    kind: lattice.EdgeKind,
    edge_id: u32,
    end: PortEnd,
    sink: aux.Sink,
) void {
    // Port-gap probe: a polyline may stop one cell SHORT of the border
    // (the 1-cell gap convention `reconcile.zig` reprieves — back-edge
    // arrivals do this routinely). The border then sits one further step
    // AWAY from the merged arm (`reverse(arm)` points along the run's
    // travel toward the node), and skipping it would leave gap arrivals
    // as the one un-erased port class. `attachment` owns that probe AND
    // the mergeability test (a non-corner node border), so the head slide
    // and this merge fire under one condition and cannot drift.
    // A corner landing is refused there: ports are issued as FACE offsets,
    // so ink on a corner is a routing defect — merging would morph the
    // corner glyph AND file the `.port` that excuses the landing from the
    // terminal audit's corner bucket. Nothing is drawn, the gap cell
    // included: no port stroke, nothing approaching.
    // guarded-by: edges_port_test.zig "a gap arrival merges its port bit across the 1-cell reprieve"
    // guarded-by: edges_port_test.zig "a corner landing is refused: no merge, no record"
    const at = attachment(lat, p, reverse(arm)) orelse return;
    const gap = at.gap;
    // The facing gate, applied to the border cell the probe RESOLVED (not
    // the polyline endpoint). A gap end's head has already been slid ONTO
    // the gap by `slideHead`, so its tip faces this border and the tee is
    // suppressed; a head that did not slide does not face it and merges.
    if (end.head) |h| {
        if (tipFaces(h, at.border)) return;
    }
    const c = toCoord(at.border);
    const cell = lat.at(c.x, c.y);
    cell.neighbours = orMask(cell.neighbours, bitMask(arm));
    if (kind != .solid and cell.stroke_kind == .solid) {
        cell.stroke_kind = kind;
    }
    aux.record(sink, lat.cellIndex(c.x, c.y), .port, edge_id, lattice.portArmDetail(arm));

    // The approach stroke, drawn only now that the wall actually teed: a
    // run cell on the port axis joining border to head/run. `straightMask`
    // is axis-symmetric, so the arm direction serves either end.
    if (gap) |g| {
        const gc = toCoord(g);
        // Empty by the probe's own condition, so `writeEdgeCell` takes its
        // `.empty` arm: it claims background, files no record and cannot
        // reach the loss counters. `lost` is therefore provably untouched —
        // the port path stays neutral for `audit.collect`.
        // guarded-by: edges_port_test.zig "painting the gap cell costs no lost cells"
        var lost: u32 = 0;
        writeEdgeCell(
            lat.at(gc.x, gc.y),
            edge_id,
            kind,
            end.role,
            straightMask(arm),
            gc.x,
            gc.y,
            &lost,
            .merged_untested, // the `.empty` arm files no carrier at all
            aux.Recorder.init(sink, lat),
        );
        std.debug.assert(lost == 0);
    }
}

test {
    _ = @import("edges_port_test.zig");
    _ = @import("edges_slide_test.zig");
}
