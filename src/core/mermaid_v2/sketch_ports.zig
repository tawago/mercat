//! Port-share co-sets — the geometric half of co-channel membership.
//!
//! A producer may deliberately route several edges through ONE perimeter port
//! of a node: layout's port plan hands two arrivals the same midpoint port,
//! `cluster/bridges.zig` mints two bridge elbows landing on the same placement
//! port, and after `cluster/stitch.zig` a child edge and a bridge can meet at
//! one port across tiers. In every case the edges legally share the approach
//! ink at that port — the stem below a shared north port is ONE run, and the
//! junction there is a real junction, not a transversal.
//!
//! No producer declares that share (each knows only its own edge), so
//! `raster/crossings.sameChannel` reads the stem as foreign overlap and
//! regresses `├` to `│`. This module recovers the declaration from the
//! sketch's OWN geometry: the producers already agreed on a coordinate, and
//! that agreement is the record.
//!
//! INVARIANTS
//!   * Grouping is by PHYSICAL PORT POINT ONLY, never by polarity: an edge
//!     contributes both its first polyline point (its departure port) and its
//!     last (its arrival port), so an in-edge and an out-edge meeting at one
//!     port — a cycle return terminating where a fan departs — group together.
//!   * A set is PAIRWISE and CELL-SCOPED. Two edges that share a port share
//!     the ink of their COMMON APPROACH — the cells both traverse, connected
//!     to the port — and NOTHING else. Where their paths meet again far from
//!     the port they are still strangers and that meeting is still a
//!     transversal. One wide set per port would instead license every later
//!     crossing between its members, fabricating a `┼` on a true transversal.
//!   * No union-find across ports: transitively fusing two ports would license
//!     ink sharing along a run neither producer ever agreed on.
//!   * Pure and total: reads only the passed edges, allocates only the result,
//!     and never inspects node ids, roles, or names.
//!
//! Imports `std`, `prim`, `base/ledger.zig` and `sketch.zig` only (it is an
//! extension of the Sketch IR root; enforced by `tools/lint_imports.zig`).

const std = @import("std");
const sketch = @import("sketch.zig");
const ledger = @import("base/ledger.zig");

const EdgeId = sketch.EdgeId;
const Point = sketch.Point;
const CoCell = ledger.CoCell;

/// A single edge's cell footprint: every integer cell its polyline passes
/// through, in path order.
const Trace = struct {
    id: EdgeId,
    first: Point,
    last: Point,
    cells: []const CoCell,
};

/// One `.port_share` co-set per PAIR of edges terminating on the same
/// coordinate, licensed over their common approach (see the header).
///
/// Skipped: invisible edges (they paint no ink, so they may license none),
/// degenerate polylines (fewer than two points, or a first point equal to the
/// last), and any pair whose common approach comes out empty.
///
/// The result is allocated in `arena`.
/// guarded-by: sketch_ports_test.zig "shared departure port groups its edges"
pub fn portShareCoSets(
    arena: std.mem.Allocator,
    edges: []const sketch.EdgePath,
) error{OutOfMemory}![]const ledger.CoSet {
    var traces: std.ArrayListUnmanaged(Trace) = .empty;
    for (edges) |e| {
        if (e.kind == .invisible) continue;
        if (e.polyline.len < 2) continue;
        const first = e.polyline[0];
        const last = e.polyline[e.polyline.len - 1];
        if (first.x == last.x and first.y == last.y) continue;
        try traces.append(arena, .{
            .id = e.id,
            .first = first,
            .last = last,
            .cells = try traceCells(arena, e.polyline),
        });
    }

    var out: std.ArrayListUnmanaged(ledger.CoSet) = .empty;
    for (traces.items, 0..) |a, i| {
        for (traces.items[i + 1 ..]) |b| {
            if (a.id == b.id) continue;
            const port = sharedTerminal(a, b) orelse continue;
            const cells = try commonApproach(arena, a.cells, b.cells, port);
            if (cells.len == 0) continue;
            const members = try arena.dupe(EdgeId, &[_]EdgeId{ a.id, b.id });
            try out.append(arena, .{ .origin = .port_share, .members = members, .cells = cells });
        }
    }
    return out.toOwnedSlice(arena);
}

/// The coordinate both edges TERMINATE on, or null. Polarity-blind: each
/// edge's two terminals are compared against the other's two.
fn sharedTerminal(a: Trace, b: Trace) ?CoCell {
    for ([2]Point{ a.first, a.last }) |p| {
        for ([2]Point{ b.first, b.last }) |q| {
            if (p.x == q.x and p.y == q.y) return .{ .x = p.x, .y = p.y };
        }
    }
    return null;
}

/// Every cell a polyline passes through, in order. Orthogonal segments are
/// walked cell by cell; a non-orthogonal segment (which routing never emits)
/// contributes only its endpoints, so the trace can never name a cell the
/// edge does not touch.
fn traceCells(arena: std.mem.Allocator, polyline: []const Point) error{OutOfMemory}![]const CoCell {
    var cells: std.ArrayListUnmanaged(CoCell) = .empty;
    try cells.append(arena, .{ .x = polyline[0].x, .y = polyline[0].y });
    for (polyline[1..], polyline[0 .. polyline.len - 1]) |to, from| {
        const dx = std.math.sign(to.x - from.x);
        const dy = std.math.sign(to.y - from.y);
        if (dx != 0 and dy != 0) {
            try cells.append(arena, .{ .x = to.x, .y = to.y });
            continue;
        }
        var cur = from;
        while (cur.x != to.x or cur.y != to.y) {
            cur = .{ .x = cur.x + dx, .y = cur.y + dy };
            try cells.append(arena, .{ .x = cur.x, .y = cur.y });
        }
    }
    return cells.toOwnedSlice(arena);
}

/// The cells BOTH edges occupy that are 4-connected to `port` through the
/// intersection — the shared approach and nothing beyond it. A second, distant
/// overlap between the same two edges is a separate meeting and stays foreign.
fn commonApproach(
    arena: std.mem.Allocator,
    a: []const CoCell,
    b: []const CoCell,
    port: CoCell,
) error{OutOfMemory}![]const CoCell {
    var shared: std.ArrayListUnmanaged(CoCell) = .empty;
    for (a) |c| {
        if (!has(b, c) or has(shared.items, c)) continue;
        try shared.append(arena, c);
    }
    if (!has(shared.items, port)) return &.{};

    // Flood the intersection outward from the port; `reached` doubles as the
    // frontier queue and the result.
    var reached: std.ArrayListUnmanaged(CoCell) = .empty;
    try reached.append(arena, port);
    var i: usize = 0;
    while (i < reached.items.len) : (i += 1) {
        const c = reached.items[i];
        const steps = [4]CoCell{
            .{ .x = c.x + 1, .y = c.y },
            .{ .x = c.x - 1, .y = c.y },
            .{ .x = c.x, .y = c.y + 1 },
            .{ .x = c.x, .y = c.y - 1 },
        };
        for (steps) |n| {
            if (!has(shared.items, n) or has(reached.items, n)) continue;
            try reached.append(arena, n);
        }
    }
    return reached.toOwnedSlice(arena);
}

fn has(cells: []const CoCell, want: CoCell) bool {
    for (cells) |c| {
        if (c.x == want.x and c.y == want.y) return true;
    }
    return false;
}

/// `existing ++ portShareCoSets(edges)` — the ONE way callers wire this in.
/// Port-share sets are APPENDED, never substituted: they record a share the
/// other origins never claimed to know about, and dropping a fan-rail or
/// plan-derived set to make room would silently un-license ink the producer
/// did declare. Duplicate membership between origins is harmless
/// (`ledger.coMembersAt` is a linear scan over all sets), so nothing is deduped.
/// guarded-by: sketch_ports_test.zig "appendPortShares keeps the existing sets ahead of the derived ones"
pub fn appendPortShares(
    arena: std.mem.Allocator,
    existing: []const ledger.CoSet,
    edges: []const sketch.EdgePath,
) error{OutOfMemory}![]const ledger.CoSet {
    return ledger.concatSets(arena, existing, try portShareCoSets(arena, edges));
}
