//! Cell-writer + geometry primitives for `raster/edges.zig`.
//!
//! Split out of `edges.zig` (P2v Slice 1, frame-solid border bridging): the
//! per-cell claim contract (`writeEdgeCell`/`writeArrowCell`/
//! `writeArrowGuarded`/`drawPortStroke`) and the pure directional helpers
//! (`straightMask`/`bitMask`/`reverse`/`orMask`/`segmentDir`/`step`/…) live
//! here so the walk driver in `edges.zig` stays under the 500-line cap. These
//! symbols are re-exported from `edges.zig` (`pub const`) so `raster/busbars.zig`
//! and the raster tests keep reaching them as `edges.<name>`.
//!
//! Imports: `std`, `sketch.zig`, `lattice.zig`, `edge_roles.zig`,
//! `crossings.zig`, `aux.zig` (all raster-zone siblings).

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const roles = @import("edge_roles.zig");
const crossings = @import("crossings.zig");
const aux = @import("aux.zig");

// Scoped logger: collision/skip diagnostics stay .debug (silent in release
// unless a developer opts in via `-Dlog_level=debug` or a debug build).
const log = std.log.scoped(.@"mermaid_v2.raster.edges");

pub const Move = lattice.Dir4;

/// Both-end bit mask for a straight cell on a segment moving `dir`.
/// East-moving segment cells have BOTH .e and .w set (each connects
/// to its east and west neighbour).
pub fn straightMask(dir: Move) lattice.Neighbours {
    return switch (dir) {
        .north, .south => .{ .n = true, .s = true },
        .east, .west => .{ .e = true, .w = true },
    };
}

pub fn bitMask(dir: Move) lattice.Neighbours {
    return switch (dir) {
        .north => .{ .n = true },
        .east => .{ .e = true },
        .south => .{ .s = true },
        .west => .{ .w = true },
    };
}

pub fn reverse(dir: Move) Move {
    return switch (dir) {
        .north => .south,
        .south => .north,
        .east => .west,
        .west => .east,
    };
}

pub fn orMask(a: lattice.Neighbours, b: lattice.Neighbours) lattice.Neighbours {
    return lattice.Neighbours.fromMask(a.toMask() | b.toMask());
}

/// Direction from `a` to `b`. Null for zero-length or non-orthogonal.
pub fn segmentDir(a: sketch.Point, b: sketch.Point) ?Move {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    if (dx == 0 and dy == 0) return null;
    if (dx != 0 and dy != 0) return null;
    if (dx > 0) return .east;
    if (dx < 0) return .west;
    if (dy > 0) return .south;
    return .north;
}

pub fn step(p: sketch.Point, dir: Move) sketch.Point {
    return switch (dir) {
        .north => .{ .x = p.x, .y = p.y - 1 },
        .south => .{ .x = p.x, .y = p.y + 1 },
        .east => .{ .x = p.x + 1, .y = p.y },
        .west => .{ .x = p.x - 1, .y = p.y },
    };
}

pub fn pointInBounds(p: sketch.Point, lat: *const lattice.Lattice) bool {
    return p.x >= 0 and p.y >= 0 and
        p.x < @as(i32, @intCast(lat.width)) and
        p.y < @as(i32, @intCast(lat.height));
}

pub const Coord = struct { x: u32, y: u32 };

/// File one `.carrier` record: `edge` has ink at (x, y) that the Cell does
/// not name. The single spelling of the record, so the four writer arms
/// here, the walk's own corner merge in `edges.zig`, and the crossing
/// refusals cannot drift in how they describe the same event.
pub fn recordCarrier(
    rec: aux.Recorder,
    x: u32,
    y: u32,
    edge: u32,
    how: lattice.CarrierKind,
) void {
    rec.at(x, y, .carrier, edge, @intFromEnum(how));
}

/// File one `.rail_member` record: fan member `edge` rides the shared run
/// at (x, y). The single spelling for both producers of shared fan ink —
/// the bus-bar rasterizer and the fan polyline walk — so they cannot drift
/// in how they describe the same membership.
pub fn recordRailMember(
    rec: aux.Recorder,
    x: u32,
    y: u32,
    edge: u32,
    polarity: lattice.RailPolarity,
) void {
    rec.at(x, y, .rail_member, edge, @intFromEnum(polarity));
}

/// File one `.tap` record: `edge` branches off (fan-OUT) or onto (fan-IN)
/// the shared run at its branch cell (x, y).
pub fn recordTap(
    rec: aux.Recorder,
    x: u32,
    y: u32,
    edge: u32,
    polarity: lattice.RailPolarity,
) void {
    rec.at(x, y, .tap, edge, @intFromEnum(polarity));
}

/// File one `.intrusion` record: `edge` met a subgraph frame border at
/// (x, y) and the frame-solid ruling resolved it as `how`.
pub fn recordIntrusion(
    rec: aux.Recorder,
    x: u32,
    y: u32,
    edge: u32,
    how: lattice.IntrusionKind,
) void {
    rec.at(x, y, .intrusion, edge, @intFromEnum(how));
}

/// The fan family a routing role belongs to, or null for a role that is
/// not fan ink at all. The rail/dropper distinction is a Cell field
/// (`EdgeRole`); the family is what a membership record has to carry.
pub fn railPolarity(role: lattice.EdgeRole) ?lattice.RailPolarity {
    return switch (role) {
        .fan_out_rail, .fan_out_dropper => .out,
        .fan_in_rail, .fan_in_dropper => .in,
        else => null,
    };
}

pub fn toCoord(p: sketch.Point) Coord {
    std.debug.assert(p.x >= 0 and p.y >= 0);
    return .{ .x = @intCast(p.x), .y = @intCast(p.y) };
}

/// Cell-claim contract:
///   - empty            → claim with edge_segment + mask.
///   - cluster_border   → a TERMINAL arrival into the cluster (the final
///                        cell of a polyline that ends on the border) keeps
///                        the pre-ruling merge: overwrite as edge_segment,
///                        OR-ing bits. THROUGH-GOING segments never reach
///                        here — the caller (`walkPolyline`) bridges the
///                        frame before calling (frame-solid, D-CROSS owner
///                        ruling 2026-07-19).
///   - edge_segment     → OR neighbours; first writer's edge id wins
///                        (informational; paint resolves crossings via
///                        the 4-bit mask). Role merges per `mergeRole`.
///   - arrowhead        → leave occupant; OR neighbours.
///   - node_interior/border, label_char → conflict; log + skip.
///
/// The two OR-merge arms drop `edge_id`: the cell keeps the first writer's
/// identity and this edge's ink becomes anonymous there. Each files a
/// `.carrier` record naming it (`lattice.CarrierKind.merged`) — the one
/// fact the Cell provably cannot express, since it holds a single edge id.
/// A merge onto this edge's OWN ink names nobody new and files nothing.
/// guarded-by: aux_test.zig "an OR-merge onto a foreign cell files a merged carrier; onto its own ink, nothing"
pub fn writeEdgeCell(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    role: lattice.EdgeRole,
    extra: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
    rec: aux.Recorder,
) void {
    switch (cell.occupant) {
        .empty => {
            cell.occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = kind, .role = role } };
            cell.neighbours = extra;
            cell.stroke_kind = kind;
        },
        .cluster_border => {
            cell.occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = kind, .role = role } };
            cell.neighbours = orMask(cell.neighbours, extra);
            cell.stroke_kind = kind;
        },
        .edge_segment => |existing| {
            cell.occupant = .{ .edge_segment = .{
                .edge = existing.edge,
                .kind = existing.kind,
                .role = roles.mergeRole(existing.role, role),
            } };
            cell.neighbours = orMask(cell.neighbours, extra);
            if (existing.edge != edge_id) recordCarrier(rec, x, y, edge_id, .merged);
        },
        .arrowhead => |head| {
            cell.neighbours = orMask(cell.neighbours, extra);
            if (head.edge != edge_id) recordCarrier(rec, x, y, edge_id, .merged);
        },
        .node_interior, .node_border => {
            cells_lost.* += 1;
            log.debug(
                "mermaid_v2/raster/edges: edge {d} at ({d},{d}) collides with node-owned cell; skipping",
                .{ edge_id, x, y },
            );
        },
        .label_char, .label_cont => {
            cells_lost.* += 1;
            log.debug(
                "mermaid_v2/raster/edges: edge {d} at ({d},{d}) collides with label_char; skipping",
                .{ edge_id, x, y },
            );
        },
    }
}

/// `kind` is the arrowhead's OWN edge kind. It is stamped onto the cell's
/// `stroke_kind` so an arrowhead landing on a FOREIGN edge's run no longer
/// inherits that run's stroke — the arrowhead cell's stroke agrees with the
/// edge that owns the arrowhead.
/// `arrow` is the head style the producing edge declared; it is recorded on
/// the cell but does not (yet) reach the painter, which still picks the head
/// glyph from `dir` alone.
/// Both id-dropping arms file a merged `.carrier` for the edge whose name the
/// cell loses: stamping over a foreign run drops the RUN's id (its bits stay
/// in the mask), and landing on an existing arrowhead drops the incoming
/// edge's.
/// guarded-by: edges_write_test.zig "writeArrowCell stamps the edge's own stroke_kind"
/// guarded-by: aux_test.zig "an arrowhead stamped over a foreign run files a carrier for the run it covered"
pub fn writeArrowCell(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    arrow: lattice.ArrowKind,
    dir: Move,
    along: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
    rec: aux.Recorder,
) void {
    switch (cell.occupant) {
        // An arrowhead may stamp onto a cluster_border: an arrival AT the
        // cluster (terminal), which the frame-solid ruling preserves.
        .empty, .edge_segment, .cluster_border => {
            if (cell.occupant == .edge_segment and cell.occupant.edge_segment.edge != edge_id) {
                recordCarrier(rec, x, y, cell.occupant.edge_segment.edge, .merged);
            }
            cell.occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge_id, .arrow = arrow } };
            cell.neighbours = orMask(cell.neighbours, along);
            cell.stroke_kind = kind;
        },
        .arrowhead => |head| {
            cell.neighbours = orMask(cell.neighbours, along);
            if (head.edge != edge_id) recordCarrier(rec, x, y, edge_id, .merged);
        },
        .node_interior, .node_border, .label_char, .label_cont => {
            cells_lost.* += 1;
            log.debug(
                "mermaid_v2/raster/edges: arrowhead for edge {d} at ({d},{d}) collides; skipping",
                .{ edge_id, x, y },
            );
        },
    }
}

/// Draw the departure PORT: OR-merge the outgoing bit into the source
/// border cell on whichever face the polyline leaves through — all four
/// faces, symmetric with `drawTargetPortStroke` (uniform port erasure).
/// When the merging edge is non-solid, also stamp the border cell's
/// `stroke_kind` so the painter can pick variants like `╥`/`╨` for
/// thick edges meeting a solid node frame.
/// An invisible (`~~~`) edge draws no ink, so it must not tee the source
/// border: return before touching the cell.
/// `head` is the cell this end's arrowhead was stamped on, or null when the
/// end carries no head. Suppression is keyed to ADJACENCY, not to decoration
/// alone (see `mergePortBit`): the bit is dropped only when the head abuts
/// the border cell, where the tee behind it would be redundant.
/// guarded-by: edges_write_test.zig "a decorated source end whose head abuts the wall leaves it pristine"
/// Every stroke actually drawn also files a `.port` record for `edge_id`
/// on the side table: the border cell keeps the merged arm but not the
/// identity of the edge that merged it, so the record adds a fact the
/// Cell cannot express (lattice.zig's anti-desync law). Refused strokes
/// (invisible edge, non-border cell) file nothing —
/// the channel records what was drawn, never what was intended.
/// guarded-by: edges_write_test.zig "drawPortStroke: an invisible edge leaves the source node border untouched"
/// guarded-by: aux_test.zig "drawPortStroke files a port record only for a stroke it actually draws"
pub fn drawPortStroke(
    lat: *lattice.Lattice,
    pts: []const sketch.Point,
    kind: lattice.EdgeKind,
    edge_id: u32,
    head: ?sketch.Point,
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
    mergePortBit(lat, pts[0], fd, kind, edge_id, head, sink);
}

/// Draw the arrival PORT: OR-merge the incoming arm into the TARGET border
/// cell at the polyline's final point — the perimeter cell the walk
/// deliberately skips (the arrowhead stamps the last INTERIOR cell). The
/// merged bit is `reverse(last_dir)`: it points back along the run, so the
/// border glyph becomes the tee facing the arriving stroke (`┴` on a
/// box-top TD arrival, `┤`/`├` on LR/RL). Same refusals and `.port` record
/// discipline as `drawPortStroke` — the two are the uniform port-erasure
/// pair, symmetric on all four faces, and both drop the bit only for a head
/// that ABUTS the border (`head`, the arrowhead's cell), so a `▼` never sits
/// on a `┴` while a detached head still gets its wall attachment.
/// guarded-by: edges_write_test.zig "drawTargetPortStroke: arrival arms merge on all four faces"
/// guarded-by: edges_write_test.zig "a decorated arrival whose head abuts the wall leaves it pristine"
/// guarded-by: edges_write_test.zig "a decorated arrival whose head is DETACHED still tees the wall"
pub fn drawTargetPortStroke(
    lat: *lattice.Lattice,
    pts: []const sketch.Point,
    kind: lattice.EdgeKind,
    edge_id: u32,
    head: ?sketch.Point,
    sink: aux.Sink,
) void {
    if (kind == .invisible) return;
    var last_dir_opt: ?Move = null;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        if (segmentDir(pts[i], pts[i + 1])) |d| last_dir_opt = d;
    }
    const ld = last_dir_opt orelse return;
    mergePortBit(lat, pts[pts.len - 1], reverse(ld), kind, edge_id, head, sink);
}

/// Orthogonal (4-neighbour) adjacency: exactly one cell of separation on one
/// axis and none on the other. Diagonal neighbours are NOT adjacent — a head
/// kitty-corner to the wall does not face it across a seam.
fn orthoAdjacent(a: sketch.Point, b: sketch.Point) bool {
    const dx = if (a.x > b.x) a.x - b.x else b.x - a.x;
    const dy = if (a.y > b.y) a.y - b.y else b.y - a.y;
    return dx + dy == 1;
}

/// Shared tail of the two port-stroke writers: OR one directional arm into
/// a node-border cell (refusing every other occupant), stamp a non-solid
/// stroke, file the `.port` record for the stroke actually drawn.
///
/// THE PORT-TEE RULE. The bit is suppressed iff this end is decorated AND
/// its head cell is orthogonally adjacent to the port border cell — the
/// head's tip faces the wall across one seam, so the tee behind it is
/// redundant ink asserting a continuation past the border that does not
/// exist (`▼` sitting on `┴`, `▶` on `┤`). DECORATION ALONE IS NOT THE
/// KEY: when the head is separated from the wall by one or more cells (a
/// gap arrival, or a run that ends short), the wall shows no tap at all and
/// the edge visually never attaches to the node — the return leg of a
/// bidirectional pair appears to circulate from nowhere. In that case the
/// bit MERGES, exactly as uniform erasure requires.
/// guarded-by: edges_write_test.zig "a decorated arrival whose head is DETACHED still tees the wall"
fn mergePortBit(
    lat: *lattice.Lattice,
    p: sketch.Point,
    arm: Move,
    kind: lattice.EdgeKind,
    edge_id: u32,
    head: ?sketch.Point,
    sink: aux.Sink,
) void {
    if (!pointInBounds(p, lat)) return;
    var q = p;
    // Port-gap probe: a polyline may stop one cell SHORT of the border
    // (the 1-cell gap convention `reconcile.zig` reprieves — back-edge
    // arrivals do this routinely). The border then sits one further step
    // AWAY from the merged arm (`reverse(arm)` points along the run's
    // travel toward the node), and skipping it would leave gap arrivals
    // as the one un-erased port class. Probe exactly one cell, and only
    // across an EMPTY endpoint, so the stroke never jumps a real occupant.
    // guarded-by: edges_write_test.zig "a gap arrival merges its port bit across the 1-cell reprieve"
    if (lat.at(toCoord(q).x, toCoord(q).y).occupant == .empty) {
        q = step(q, reverse(arm));
        if (!pointInBounds(q, lat)) return;
    }
    // The head-adjacency gate, applied to the border cell the probe
    // RESOLVED (not the polyline endpoint): a gap arrival's head sits two
    // cells from the wall, so it is not adjacent and the bit merges.
    //
    // JUDGED TRADE-OFF (decorated gap arrival, `border, blank, head`).
    // Merging here re-creates the `├ ◀` shape — a tee, a blank, then the
    // head — which an earlier judgment flagged as an arm pointing into
    // nothing. That judgment was made before the wall-attachment defect
    // was visible; against it, the later evidence is that an unattached
    // arrival is strictly worse: with no tap on the wall the edge reads as
    // circulating from nowhere and the reader cannot tell WHICH node the
    // return leg lands on. Attachment wins. The blank between tee and head
    // is a legible one-cell approach; a wall with no tap is a missing fact.
    if (head) |h| {
        if (orthoAdjacent(h, q)) return;
    }
    const c = toCoord(q);
    const cell = lat.at(c.x, c.y);
    if (cell.occupant == .node_border) {
        // Corner refusal: ports are issued as FACE offsets, so ink on a
        // corner is a routing defect — merging there would morph the
        // corner glyph AND file the `.port` that excuses the landing from
        // the terminal audit's corner bucket. Leave the cell pristine so
        // the defect stays visible to the report.
        // guarded-by: edges_write_test.zig "a corner landing is refused: no merge, no record"
        switch (cell.occupant.node_border.role) {
            .corner_nw, .corner_ne, .corner_se, .corner_sw => return,
            else => {},
        }
        cell.neighbours = orMask(cell.neighbours, bitMask(arm));
        if (kind != .solid and cell.stroke_kind == .solid) {
            cell.stroke_kind = kind;
        }
        aux.record(sink, lat.cellIndex(c.x, c.y), .port, edge_id, lattice.portArmDetail(arm));
    }
}

/// Write this edge's OWN terminal arrowhead, but refuse to lay it over a
/// FOREIGN edge's run (C2): stamping an arrowhead onto a foreign segment reads
/// as a fabricated arrival. When refused, keep the arrowhead pristine (drop the
/// foreign run's bits) and record the violation; otherwise the pre-C write.
/// `kind` is the arrowhead's OWN edge kind, stamped in both the refuse branch
/// and the delegated `writeArrowCell` so the arrowhead cell never carries the
/// foreign run's stroke; `arrow` records the declared head style on both paths.
/// The refuse branch files a SUPPRESSED `.carrier` for the crossed run: its
/// ink runs through this position, and after the refusal neither the mask nor
/// the occupant says so.
/// guarded-by: edges_write_test.zig "writeArrowGuarded refuse branch stamps the arrowhead's own stroke_kind"
/// guarded-by: aux_test.zig "a refused arrowhead transit files a suppressed carrier for the crossed run"
pub fn writeArrowGuarded(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    arrow: lattice.ArrowKind,
    dir: Move,
    along: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
    ctx: crossings.Ctx,
    rec: aux.Recorder,
) void {
    if (cell.occupant == .edge_segment) {
        const seg = cell.occupant.edge_segment;
        if (crossings.arrowheadTransit(ctx.counts, ctx.joins, ctx.co_sets, seg.edge, edge_id, crossings.cellAt(x, y))) {
            cell.occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge_id, .arrow = arrow } };
            cell.neighbours = along; // pristine: no foreign junction bits
            cell.stroke_kind = kind;
            recordCarrier(rec, x, y, seg.edge, .suppressed);
            return;
        }
    }
    writeArrowCell(cell, edge_id, kind, arrow, dir, along, x, y, cells_lost, rec);
}

test {
    _ = @import("edges_write_test.zig");
}
