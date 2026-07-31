//! PORT STROKES: how a run attaches to the wall it starts from or lands on.
//!
//! Split out of `edges_write.zig` (500-line cap). This file owns the two
//! symmetric writers `drawPortStroke` (departure) and `drawTargetPortStroke`
//! (arrival) and their shared tail `mergePortBit` — uniform port erasure on
//! all four faces, both ends of every run — plus the two rules that decide
//! what the attachment looks like: the port-tee FACING rule and the 1-cell
//! gap probe with its painted approach. The per-cell claim contract and the
//! directional primitives stay in `edges_write.zig`, which this file imports.
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
/// THE GAP APPROACH. When the probe below crosses a 1-cell port gap, the
/// merge alone would leave `├ ◀` — a tee, a blank, a head — an arm reading
/// into nothing. So the gap cell is PAINTED with this edge's own stroke:
/// `├─◀` runs contiguous from wall to head. The cell is empty by definition
/// of the probe (it is the only condition under which the probe fires), so
/// the write claims background and can lose nothing; anything occupying it
/// refuses the probe and the whole stroke upstream.
/// guarded-by: edges_port_test.zig "a gap arrival paints the gap cell so wall, run and head run contiguous"
fn mergePortBit(
    lat: *lattice.Lattice,
    p: sketch.Point,
    arm: Move,
    kind: lattice.EdgeKind,
    edge_id: u32,
    end: PortEnd,
    sink: aux.Sink,
) void {
    if (!pointInBounds(p, lat)) return;
    var q = p;
    var gap: ?sketch.Point = null;
    // Port-gap probe: a polyline may stop one cell SHORT of the border
    // (the 1-cell gap convention `reconcile.zig` reprieves — back-edge
    // arrivals do this routinely). The border then sits one further step
    // AWAY from the merged arm (`reverse(arm)` points along the run's
    // travel toward the node), and skipping it would leave gap arrivals
    // as the one un-erased port class. Probe exactly one cell, and only
    // across an EMPTY endpoint, so the stroke never jumps a real occupant.
    // guarded-by: edges_port_test.zig "a gap arrival merges its port bit across the 1-cell reprieve"
    if (lat.at(toCoord(q).x, toCoord(q).y).occupant == .empty) {
        gap = q;
        q = step(q, reverse(arm));
        if (!pointInBounds(q, lat)) return;
    }
    // The facing gate, applied to the border cell the probe RESOLVED (not
    // the polyline endpoint): a gap arrival's head sits two cells from the
    // wall, so its tip faces the gap, not the wall, and the bit merges.
    if (end.head) |h| {
        if (tipFaces(h, q)) return;
    }
    const c = toCoord(q);
    const cell = lat.at(c.x, c.y);
    if (cell.occupant != .node_border) return;
    // Corner refusal: ports are issued as FACE offsets, so ink on a
    // corner is a routing defect — merging there would morph the
    // corner glyph AND file the `.port` that excuses the landing from
    // the terminal audit's corner bucket. Leave the cell pristine so
    // the defect stays visible to the report. The gap cell is left
    // unpainted too: no port stroke was drawn, so nothing approaches.
    // guarded-by: edges_port_test.zig "a corner landing is refused: no merge, no record"
    switch (cell.occupant.node_border.role) {
        .corner_nw, .corner_ne, .corner_se, .corner_sw => return,
        else => {},
    }
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
            aux.Recorder.init(sink, lat),
        );
        std.debug.assert(lost == 0);
    }
}

test {
    _ = @import("edges_port_test.zig");
}
