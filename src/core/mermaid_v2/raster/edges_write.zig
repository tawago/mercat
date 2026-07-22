//! Cell-writer + geometry primitives for `raster/edges.zig`.
//!
//! Split out of `edges.zig` (P2v Slice 1, frame-solid border bridging): the
//! per-cell claim contract (`writeEdgeCell`/`writeArrowCell`/
//! `writeArrowGuarded`/`mergeSourceBorder`) and the pure directional helpers
//! (`straightMask`/`bitMask`/`reverse`/`orMask`/`segmentDir`/`step`/…) live
//! here so the walk driver in `edges.zig` stays under the 500-line cap. These
//! symbols are re-exported from `edges.zig` (`pub const`) so `raster/busbars.zig`
//! and the raster tests keep reaching them as `edges.<name>`.
//!
//! Imports: `std`, `sketch.zig`, `lattice.zig`, `edge_roles.zig`,
//! `crossings.zig` (all raster-zone siblings).

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const roles = @import("edge_roles.zig");
const crossings = @import("crossings.zig");

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
pub fn writeEdgeCell(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    role: lattice.EdgeRole,
    extra: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
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
        },
        .arrowhead => {
            cell.neighbours = orMask(cell.neighbours, extra);
        },
        .node_interior, .node_border => {
            cells_lost.* += 1;
            log.debug(
                "mermaid_v2/raster/edges: edge {d} at ({d},{d}) collides with node-owned cell; skipping",
                .{ edge_id, x, y },
            );
        },
        .label_char => {
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
/// guarded-by: edges_write_test.zig "writeArrowCell stamps the edge's own stroke_kind"
pub fn writeArrowCell(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    dir: Move,
    along: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
) void {
    switch (cell.occupant) {
        // An arrowhead may stamp onto a cluster_border: an arrival AT the
        // cluster (terminal), which the frame-solid ruling preserves.
        .empty, .edge_segment, .cluster_border => {
            cell.occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge_id } };
            cell.neighbours = orMask(cell.neighbours, along);
            cell.stroke_kind = kind;
        },
        .arrowhead => {
            cell.neighbours = orMask(cell.neighbours, along);
        },
        .node_interior, .node_border, .label_char => {
            cells_lost.* += 1;
            log.debug(
                "mermaid_v2/raster/edges: arrowhead for edge {d} at ({d},{d}) collides; skipping",
                .{ edge_id, x, y },
            );
        },
    }
}

/// OR-merge the outgoing bit into the source border cell when the
/// polyline leaves a node vertically (east/west skipped so LR/RL
/// flows keep a clean `│` source border).
/// When the merging edge is non-solid, also stamp the border cell's
/// `stroke_kind` so the painter can pick variants like `╥`/`╨` for
/// thick edges meeting a solid node frame.
/// An invisible (`~~~`) edge draws no ink, so it must not tee the source
/// border: return before touching the cell.
/// guarded-by: edges_write_test.zig "mergeSourceBorder: an invisible edge leaves the source node border untouched"
pub fn mergeSourceBorder(
    lat: *lattice.Lattice,
    pts: []const sketch.Point,
    kind: lattice.EdgeKind,
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
    if (fd != .north and fd != .south) return;
    const p0 = pts[0];
    if (!pointInBounds(p0, lat)) return;
    const c = toCoord(p0);
    const cell = lat.at(c.x, c.y);
    if (cell.occupant == .node_border) {
        cell.neighbours = orMask(cell.neighbours, bitMask(fd));
        if (kind != .solid and cell.stroke_kind == .solid) {
            cell.stroke_kind = kind;
        }
    }
}

/// Write this edge's OWN terminal arrowhead, but refuse to lay it over a
/// FOREIGN edge's run (C2): stamping an arrowhead onto a foreign segment reads
/// as a fabricated arrival. When refused, keep the arrowhead pristine (drop the
/// foreign run's bits) and record the violation; otherwise the pre-C write.
/// `kind` is the arrowhead's OWN edge kind, stamped in both the refuse branch
/// and the delegated `writeArrowCell` so the arrowhead cell never carries the
/// foreign run's stroke.
/// guarded-by: edges_write_test.zig "writeArrowGuarded refuse branch stamps the arrowhead's own stroke_kind"
pub fn writeArrowGuarded(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    dir: Move,
    along: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
    ctx: crossings.Ctx,
) void {
    if (cell.occupant == .edge_segment) {
        const seg = cell.occupant.edge_segment;
        if (crossings.arrowheadTransit(ctx.counts, ctx.joins, ctx.active, seg.edge, edge_id)) {
            cell.occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge_id } };
            cell.neighbours = along; // pristine: no foreign junction bits
            cell.stroke_kind = kind;
            return;
        }
    }
    writeArrowCell(cell, edge_id, kind, dir, along, x, y, cells_lost);
}

test {
    _ = @import("edges_write_test.zig");
}
