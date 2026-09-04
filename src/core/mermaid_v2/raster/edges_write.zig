//! Cell-writer + geometry primitives for `raster/edges.zig`.
//!
//! Split out of `edges.zig` (P2v Slice 1, frame-solid border bridging): the
//! per-cell claim contract (`writeEdgeCell`/`writeArrowCell`/
//! `writeArrowGuarded`) and the pure directional helpers
//! (`straightMask`/`bitMask`/`reverse`/`orMask`/`segmentDir`/`step`/…) live
//! here so the walk driver in `edges.zig` stays under the 500-line cap. These
//! symbols are re-exported from `edges.zig` (`pub const`) so `raster/rails.zig`
//! and the raster tests keep reaching them as `edges.<name>`. The PORT
//! STROKES (`drawPortStroke`/`drawTargetPortStroke`) live one further split
//! out, in `edges_port.zig`, which imports this file for its primitives.
//!
//! Imports: `std`, `sketch.zig`, `lattice.zig`, `edge_roles.zig`,
//! `crossings.zig`, `aux.zig` (all raster-zone siblings).

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const roles = @import("edge_roles.zig");
const crossings = @import("crossings.zig");
const aux = @import("aux.zig");

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
/// the rail rasterizer and the fan polyline walk — so they cannot drift
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

/// The ink-attribution state a fresh single-owner edge cell records: a rail role is
/// bundle-shared ink, anything else is a private stroke. Decided from the
/// caller's own role input — never re-derived from the grid.
pub fn roleState(role: lattice.EdgeRole) lattice.InkState {
    return switch (role) {
        .fan_out_rail, .fan_in_rail => .rail_interior,
        else => .stroke,
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
///   - arrowhead        → the head's own edge ORs its arms (a shipped
///                        lateral arm is the producer's defect, counted
///                        post-raster). Another edge may only RIDE the
///                        head's axis (rail-interior state, no new arm);
///                        a lateral arm is refused: occupant, mask and
///                        state untouched, `cells_lost` and
///                        `counts.arm_into_head` bumped against the
///                        writer, a suppressed carrier filed. A decoration
///                        cell is never a junction (ink attribution).
///   - node_interior/border, label_char → conflict; log + skip.
///
/// The two OR-merge arms drop `edge_id`: the cell keeps the first writer's
/// identity and this edge's ink becomes anonymous there. Each files a
/// `.carrier` record naming it — the one fact the Cell provably cannot
/// express, since it holds a single edge id.
/// A merge onto this edge's OWN ink names nobody new and files nothing.
///
/// `licence` is the merged flavour of `lattice.CarrierKind` the CALLER
/// established for the pair (occupant id, `edge_id`) at this cell — the
/// writer cannot ask, because it holds a `*Cell` and no bundle context.
/// A caller with no context passes `.merged_untested`, which states
/// nothing; it must never pass `.merged_licensed` to mean "did not ask".
/// `counts` receives the head refusal above; every other arm leaves it alone.
/// @guarded-by: aux_test.zig "an OR-merge onto a foreign cell files a merged carrier; onto its own ink, nothing"
/// @guarded-by: edges_write_test.zig "writeEdgeCell files the merged carrier under the licence its caller established"
/// @guarded-by: edges_write_test.zig "a foreign lateral arm into a head is refused and counted against the writer"
/// @guarded-by: edges_write_test.zig "a co-member riding a head's axis keeps the rail-interior residue"
pub fn writeEdgeCell(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    role: lattice.EdgeRole,
    extra: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
    counts: *crossings.CrossingCounts,
    licence: lattice.CarrierKind,
    rec: aux.Recorder,
) void {
    switch (cell.occupant) {
        .empty => {
            cell.occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = kind, .role = role } };
            cell.neighbours = extra;
            cell.stroke_kind = kind;
            cell.state = roleState(role);
        },
        .cluster_border => {
            cell.occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = kind, .role = role } };
            cell.neighbours = orMask(cell.neighbours, extra);
            cell.stroke_kind = kind;
            cell.upgradeState(.junction);
        },
        .edge_segment => |existing| {
            if (existing.edge != edge_id) {
                const grows = (cell.neighbours.toMask() | extra.toMask()) != cell.neighbours.toMask();
                cell.upgradeState(if (grows) .junction else .rail_interior);
            }
            cell.occupant = .{ .edge_segment = .{
                .edge = existing.edge,
                .kind = existing.kind,
                .role = roles.mergeRole(existing.role, role),
            } };
            cell.neighbours = orMask(cell.neighbours, extra);
            if (existing.edge != edge_id) recordCarrier(rec, x, y, edge_id, licence);
        },
        .arrowhead => |head| {
            if (head.edge != edge_id) {
                if (refuseLateral(counts, cells_lost, head.dir, extra)) {
                    recordCarrier(rec, x, y, edge_id, .suppressed);
                    return;
                }
                cell.upgradeState(.rail_interior);
            }
            cell.neighbours = orMask(cell.neighbours, extra);
            if (head.edge != edge_id) recordCarrier(rec, x, y, edge_id, licence);
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

/// The decoration-cell refusal shared by the two writers: a foreign write
/// whose `mask` carries any arm off the head's axis loses the cell. Each
/// lateral arm is tallied against the writer (`arm_into_head`), the cell
/// itself is lost ink (`cells_lost`); the head's edge is not touched.
/// Returns true when the caller must stop without touching the cell.
fn refuseLateral(
    counts: *crossings.CrossingCounts,
    cells_lost: *u32,
    tip: Move,
    mask: lattice.Neighbours,
) bool {
    const lateral: u32 = @popCount(crossings.lateralArms(tip, mask).toMask());
    if (lateral == 0) return false;
    counts.arm_into_head += lateral;
    cells_lost.* += 1;
    return true;
}

/// A refused head is priced separately from a refused run cell: the cell
/// arm bumps BOTH `cells_lost` (the ink cell) and `heads_lost` (the edge's
/// declared decoration never ships — the reader loses the orientation the
/// graph states). `heads_lost` feeds selection via audit → score.
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
/// edge's. `licence` carries the caller's bundle verdict for that pair,
/// exactly as in `writeEdgeCell` — `.merged_untested` where the caller has
/// no bundle context, never `.merged_licensed` to mean "did not ask".
///
/// A head landing on a FOREIGN head shares the cell only when it points the
/// same way — one glyph, truthful for both, rail-interior state. A head
/// pointing any other way is refused: its own edge loses the cell AND its
/// decoration (`cells_lost`, `heads_lost`), a lateral one is also an arm
/// into the held head (`counts.arm_into_head`), and a suppressed carrier
/// names it. The held head is never touched. The head's OWN edge ORs its
/// arms as before; a lateral arm it ships is the producer's defect, read
/// post-raster.
///
/// STATE. A decoration cell is never a junction (constitution, ink
/// attribution): a head stamped over a co-member's run sits on a shared
/// stem and records `rail_interior`, the licence the caller established
/// saying so. A head stamped over ink it does NOT share a bundle with is
/// illegal geometry — transit through a decoration cell — and records
/// `junction`, the state the raster-side pins refuse on a head, so the
/// defect is visible rather than filed as legal sharing.
/// @guarded-by: edges_write_test.zig "a head stamped over a co-member's run is rail-interior; over a stranger's, junction"
/// @guarded-by: edges_write_test.zig "writeArrowCell stamps the edge's own stroke_kind"
/// @guarded-by: edges_write_test.zig "a foreign head pointing another way is refused; one pointing the same way rides"
/// @guarded-by: aux_test.zig "an arrowhead stamped over a foreign run files a carrier for the run it covered"
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
    heads_lost: *u32,
    counts: *crossings.CrossingCounts,
    licence: lattice.CarrierKind,
    rec: aux.Recorder,
) void {
    switch (cell.occupant) {
        .empty, .edge_segment, .cluster_border => {
            switch (cell.occupant) {
                .empty => cell.upgradeState(.stroke),
                .edge_segment => |seg| if (seg.edge != edge_id) cell.upgradeState(if (licence == .merged_licensed) .rail_interior else .junction) else if (cell.state == .none) {
                    cell.state = .stroke;
                },
                .cluster_border => cell.upgradeState(.junction),
                else => unreachable,
            }
            if (cell.occupant == .edge_segment and cell.occupant.edge_segment.edge != edge_id) {
                recordCarrier(rec, x, y, cell.occupant.edge_segment.edge, licence);
            }
            cell.occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge_id, .arrow = arrow } };
            cell.neighbours = orMask(cell.neighbours, along);
            cell.stroke_kind = kind;
        },
        .arrowhead => |head| {
            if (head.edge != edge_id) {
                if (head.dir != dir) {
                    if (!refuseLateral(counts, cells_lost, head.dir, along)) cells_lost.* += 1;
                    heads_lost.* += 1;
                    recordCarrier(rec, x, y, edge_id, .suppressed);
                    return;
                }
                cell.upgradeState(.rail_interior);
            }
            cell.neighbours = orMask(cell.neighbours, along);
            if (head.edge != edge_id) recordCarrier(rec, x, y, edge_id, licence);
        },
        .node_interior, .node_border, .label_char, .label_cont => {
            cells_lost.* += 1;
            heads_lost.* += 1;
            log.debug(
                "mermaid_v2/raster/edges: arrowhead for edge {d} at ({d},{d}) collides; skipping",
                .{ edge_id, x, y },
            );
        },
    }
}

/// Write this edge's OWN terminal arrowhead, but refuse to lay it over a
/// FOREIGN edge's run (arrowhead sanctity): stamping an arrowhead onto a foreign segment reads
/// as a fabricated arrival. When refused, keep the arrowhead pristine (drop the
/// foreign run's bits) and record the violation; otherwise the pre-C write.
/// `kind` is the arrowhead's OWN edge kind, stamped in both the refuse branch
/// and the delegated `writeArrowCell` so the arrowhead cell never carries the
/// foreign run's stroke; `arrow` records the declared head style on both paths.
/// The refuse branch files a SUPPRESSED `.carrier` for the crossed run: its
/// ink runs through this position, and after the refusal neither the mask nor
/// the occupant says so.
///
/// The arrowhead-sanctity gate covers an arrowhead landing on a RUN only. An arrowhead
/// landing on an EXISTING arrowhead falls through to `writeArrowCell`'s
/// `.arrowhead` arm, which the gate never examined — so the licence for
/// THAT pair is LOOKED UP here, off the bundle identity each head's edge
/// carries, and only to fill the record's `detail`. It changes no decision
/// and paints no byte, which is exactly why it may read identity rather
/// than re-derive the relation the ink gate above still derives.
/// @guarded-by: edges_write_test.zig "writeArrowGuarded refuse branch stamps the arrowhead's own stroke_kind"
/// @guarded-by: edges_write_test.zig "an arrowhead landing on a foreign arrowhead files a foreign carrier"
/// @guarded-by: aux_test.zig "a refused arrowhead transit files a suppressed carrier for the crossed run"
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
    heads_lost: *u32,
    ctx: crossings.Ctx,
    rec: aux.Recorder,
) void {
    if (cell.occupant == .edge_segment) {
        const seg = cell.occupant.edge_segment;
        if (crossings.arrowheadTransit(ctx.counts, ctx.bundles, ctx.bundle_sets, seg.edge, edge_id, crossings.cellAt(x, y))) {
            cell.occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge_id, .arrow = arrow } };
            cell.neighbours = along;
            cell.stroke_kind = kind;
            cell.upgradeState(.crossing);
            recordCarrier(rec, x, y, seg.edge, .suppressed);
            return;
        }
    }
    const licence: lattice.CarrierKind = switch (cell.occupant) {
        .edge_segment => .merged_licensed,
        .arrowhead => |h| crossings.licenceFor(h.edge, edge_id, ctx.bundle_sets, ctx.stamp_state, crossings.cellAt(x, y)),
        else => .merged_untested,
    };
    writeArrowCell(cell, edge_id, kind, arrow, dir, along, x, y, cells_lost, heads_lost, ctx.counts, licence, rec);
}

test {
    _ = @import("edges_write_test.zig");
}
