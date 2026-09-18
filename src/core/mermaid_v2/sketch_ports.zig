//! Port-share bundles — the geometric half of bundle membership.
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
//! `raster/crossings.sameBundle` reads the stem as foreign overlap and
//! regresses `├` to `│`. This module recovers the declaration from the
//! sketch's OWN geometry: the producers already agreed on a coordinate, and
//! that agreement is the record.
//!
//! INVARIANTS
//!   * Grouping is by PHYSICAL PORT POINT ONLY, never by polarity: an edge
//!     contributes both its first polyline point (its departure port) and its
//!     last (its arrival port), so an in-edge and an out-edge meeting at one
//!     port — a cycle return terminating where a fan departs — group together.
//!   * A set is ONE PER PORT and CELL-SCOPED, and members grouped
//!     transitively (A shares B's port and B shares C's, so all three name
//!     ONE bundle) do NOT thereby share cell scope: the set's `.pairwise`
//!     table records each PAIR's own common approach separately, and
//!     `bundleMembersAt`/`bundleOf` consult that pair-specific entry, never a
//!     flat union over every pair. A member with no direct overlap with
//!     another stays a named member (the group is one bundle for identity
//!     purposes) but licenses no cell between the two of them. Where two
//!     members' paths meet again far from the port they are still strangers
//!     there and that meeting is still a transversal — a third member's own
//!     agreement with each of them separately licenses nothing between the
//!     two that never agreed with each other. (The flat `.cells` field is
//!     kept as the union anyway, purely so a reader can ask "is this a
//!     narrower-than-a-rail set at all" without walking `.pairwise`; no
//!     licensing decision reads it when `.pairwise` is present.)
//!   * No union-find across ports: transitively fusing two ports would license
//!     ink sharing along a run neither producer ever agreed on.
//!   * Final stitch reconstruction also includes first-class rail members. A
//!     rail member contributes only its two real terminal approaches: the
//!     pivot stem and its own tap dropper. It never connects those components
//!     through the crossbar or claims another member's stretch.
//!   * Pure and total: reads only final geometry, allocates only the result,
//!     and never inspects names or layout intent.
//!
//! Allowed imports (tools/lint_imports.zig): `std`, `prim`, the `base/`
//! no-deps tier, `sketch.zig`, and `sketch_ports_test.zig`. Actually imports
//! `std`, `sketch.zig` and `base/ledger.zig` (it is an extension of the
//! Sketch IR root).

const std = @import("std");
const sketch = @import("sketch.zig");
const ledger = @import("base/ledger.zig");

const EdgeId = sketch.EdgeId;
const Point = sketch.Point;
const BundleCell = ledger.BundleCell;

/// A single edge's cell footprint: every integer cell its polyline passes
/// through, in path order.
pub const CarrierTrace = struct {
    id: EdgeId,
    first: Point,
    last: Point,
    cells: []const BundleCell,
    rail: bool,
};

/// One `.port_share` bundle per DISTINCT PORT COORDINATE, gathering EVERY
/// edge terminating there (transitively: A-shares-B and B-shares-C at the
/// same physical point are ONE group, ONE bundle — never two overlapping
/// pairwise sets over the same trio). No union-find across DIFFERENT ports
/// happens: an edge with two distinct shared terminals still lands in two
/// separate sets (see the header's no-fusing invariant and the
/// "an edge sharing two ports lands in two sets" test) because grouping keys
/// on the literal coordinate value, which is transitive by equality alone
/// and never chains through an intermediate edge to a second point.
///
/// Set order is by PORT COORDINATE (x then y), never by edge id or input
/// position: the bundle sets this feeds are renumbered positionally
/// (`ledger.numberBundles`), and a stitch or re-plan can renumber and
/// reorder edges freely, so the group boundaries and the order sets are
/// discovered in must be a function of the sketch's own geometry alone.
///
/// Skipped: invisible edges (they paint no ink, so they may license none),
/// degenerate polylines (fewer than two points, or a first point equal to the
/// last). The `cells.items.len == 0` guard below is dead in practice — every
/// member's trace contains the port cell itself by construction, so the
/// union is never empty once two members are present — kept only as a
/// defensive floor, not a real skip path.
///
/// The result is allocated in `arena`.
/// @guarded-by: sketch_ports_test.zig "shared departure port groups its edges"
pub fn portShareBundles(
    arena: std.mem.Allocator,
    edges: []const sketch.EdgePath,
) error{OutOfMemory}![]const ledger.Bundle {
    return portShareBundlesFromTraces(arena, try finalCarrierTraces(arena, edges, &.{}));
}

/// Final carrier population for stitch: ordinary paths plus one exact trace
/// per first-class rail tap. EdgePath geometry wins if malformed input names
/// one semantic edge in both forms; no edge can enter the population twice.
pub fn finalCarrierTraces(
    arena: std.mem.Allocator,
    edges: []const sketch.EdgePath,
    rails_buf: []const sketch.Rail,
) error{OutOfMemory}![]const CarrierTrace {
    var traces: std.ArrayListUnmanaged(CarrierTrace) = .empty;
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
            .rail = false,
        });
    }

    for (rails_buf) |rail| {
        if (rail.kind == .invisible or rail.stem.len < 2) continue;
        const fan_in = rail.role == .fan_in_dropper or rail.role == .fan_in_rail;
        for (rail.taps) |tap| {
            if (traceById(traces.items, tap.edge) != null) continue;
            const first = if (fan_in) tap.landing else rail.stem[0];
            const last = if (fan_in) rail.stem[0] else tap.landing;
            if (pointEqual(first, last)) continue;
            var cells: std.ArrayListUnmanaged(BundleCell) = .empty;
            for (try traceCells(arena, rail.stem)) |cell| {
                if (!has(cells.items, cell)) try cells.append(arena, cell);
            }
            const dropper = try traceCells(arena, &.{ tap.at, tap.landing });
            for (dropper[1..]) |cell| {
                if (!has(cells.items, cell)) try cells.append(arena, cell);
            }
            try traces.append(arena, .{
                .id = tap.edge,
                .first = first,
                .last = last,
                .cells = try cells.toOwnedSlice(arena),
                .rail = true,
            });
        }
    }
    return traces.toOwnedSlice(arena);
}

fn portShareBundlesFromTraces(
    arena: std.mem.Allocator,
    traces: []const CarrierTrace,
) error{OutOfMemory}![]const ledger.Bundle {
    var ports: std.ArrayListUnmanaged(BundleCell) = .empty;
    for (traces) |t| {
        for ([2]Point{ t.first, t.last }) |pt| {
            const c: BundleCell = .{ .x = pt.x, .y = pt.y };
            if (!has(ports.items, c)) try ports.append(arena, c);
        }
    }
    std.mem.sort(BundleCell, ports.items, {}, portLess);

    var out: std.ArrayListUnmanaged(ledger.Bundle) = .empty;
    for (ports.items) |port| {
        var rail_source = false;
        var rail_target = false;
        for (traces) |t| {
            if (!t.rail) continue;
            rail_source = rail_source or terminalAt(t, port, .source);
            rail_target = rail_target or terminalAt(t, port, .target);
        }
        if (!rail_source and !rail_target) {
            try appendPortSet(arena, &out, traces, port, .any);
        } else {
            try appendPortSet(arena, &out, traces, port, .paths);
            if (rail_source) try appendPortSet(arena, &out, traces, port, .source);
            if (rail_target) try appendPortSet(arena, &out, traces, port, .target);
        }
    }
    return out.toOwnedSlice(arena);
}

const TerminalFilter = enum { any, paths, source, target };

fn appendPortSet(
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(ledger.Bundle),
    traces: []const CarrierTrace,
    port: BundleCell,
    filter: TerminalFilter,
) error{OutOfMemory}!void {
    var members: std.ArrayListUnmanaged(EdgeId) = .empty;
    for (traces) |trace| {
        if (terminalAt(trace, port, filter)) try members.append(arena, trace.id);
    }
    if (members.items.len < 2) return;

    var cells: std.ArrayListUnmanaged(BundleCell) = .empty;
    var pairwise: std.ArrayListUnmanaged(ledger.PairCells) = .empty;
    for (traces, 0..) |a, i| {
        if (!terminalAt(a, port, filter)) continue;
        for (traces[i + 1 ..]) |b| {
            if (!terminalAt(b, port, filter)) continue;
            var pair_cells = try commonApproachCells(arena, a.cells, b.cells, port);
            if (a.rail != b.rail and pair_cells.len <= 1) pair_cells = &.{};
            try pairwise.append(arena, .{ .a = a.id, .b = b.id, .cells = pair_cells });
            for (pair_cells) |cell| {
                if (!has(cells.items, cell)) try cells.append(arena, cell);
            }
        }
    }
    if (cells.items.len == 0) return;
    try out.append(arena, .{
        .origin = .port_share,
        .members = try members.toOwnedSlice(arena),
        .cells = try cells.toOwnedSlice(arena),
        .pairwise = try pairwise.toOwnedSlice(arena),
    });
}

fn terminalAt(trace: CarrierTrace, port: BundleCell, filter: TerminalFilter) bool {
    const source = trace.first.x == port.x and trace.first.y == port.y;
    const target = trace.last.x == port.x and trace.last.y == port.y;
    return switch (filter) {
        .any => source or target,
        .paths => !trace.rail and (source or target),
        .source => source,
        .target => target,
    };
}

fn traceById(traces: []const CarrierTrace, id: EdgeId) ?CarrierTrace {
    for (traces) |trace| if (trace.id == id) return trace;
    return null;
}

fn pointEqual(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn portLess(_: void, a: BundleCell, b: BundleCell) bool {
    if (a.x != b.x) return a.x < b.x;
    return a.y < b.y;
}

/// Every cell a polyline passes through, in order. Orthogonal segments are
/// walked cell by cell; a non-orthogonal segment (which routing never emits)
/// contributes only its endpoints, so the trace can never name a cell the
/// edge does not touch.
fn traceCells(arena: std.mem.Allocator, polyline: []const Point) error{OutOfMemory}![]const BundleCell {
    var cells: std.ArrayListUnmanaged(BundleCell) = .empty;
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
pub fn commonApproachCells(
    arena: std.mem.Allocator,
    a: []const BundleCell,
    b: []const BundleCell,
    port: BundleCell,
) error{OutOfMemory}![]const BundleCell {
    var shared: std.ArrayListUnmanaged(BundleCell) = .empty;
    for (a) |c| {
        if (!has(b, c) or has(shared.items, c)) continue;
        try shared.append(arena, c);
    }
    if (!has(shared.items, port)) return &.{};

    var reached: std.ArrayListUnmanaged(BundleCell) = .empty;
    try reached.append(arena, port);
    var i: usize = 0;
    while (i < reached.items.len) : (i += 1) {
        const c = reached.items[i];
        const steps = [4]BundleCell{
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

fn has(cells: []const BundleCell, want: BundleCell) bool {
    for (cells) |c| {
        if (c.x == want.x and c.y == want.y) return true;
    }
    return false;
}

/// Replace the existing `.port_share` population with the one derived from
/// `edges`, while retaining every structural set in order. This is the one way
/// a finalizer wires port shares in: stale geometry and duplicate first-match
/// identities cannot survive a second finalization.
/// @guarded-by: sketch_ports_test.zig "appendPortShares keeps the existing sets ahead of the derived ones"
pub fn appendPortShares(
    arena: std.mem.Allocator,
    existing: []const ledger.Bundle,
    edges: []const sketch.EdgePath,
) error{OutOfMemory}![]const ledger.Bundle {
    var structural: std.ArrayListUnmanaged(ledger.Bundle) = .empty;
    for (existing) |set| {
        if (set.origin != .port_share) try structural.append(arena, set);
    }
    return ledger.concatBundles(arena, try structural.toOwnedSlice(arena), try portShareBundles(arena, edges));
}

/// Stitch finalizer variant. Scoped port shares come first so a rail member
/// can temporarily ride the port bundle where a bridge joins it, then fall
/// back to its structural rail bundle everywhere outside that exact scope.
pub fn rebuildFinalPortShares(
    arena: std.mem.Allocator,
    existing: []const ledger.Bundle,
    edges: []const sketch.EdgePath,
    rails_buf: []const sketch.Rail,
) error{OutOfMemory}![]const ledger.Bundle {
    var structural: std.ArrayListUnmanaged(ledger.Bundle) = .empty;
    for (existing) |set| {
        if (set.origin != .port_share) try structural.append(arena, set);
    }
    const traces = try finalCarrierTraces(arena, edges, rails_buf);
    var mixed: std.ArrayListUnmanaged(ledger.Bundle) = .empty;
    var path_only: std.ArrayListUnmanaged(ledger.Bundle) = .empty;
    for (try portShareBundlesFromTraces(arena, traces)) |share| {
        var has_path = false;
        var has_rail = false;
        for (share.members) |member| {
            if (traceById(traces, member)) |trace| {
                if (trace.rail) has_rail = true else has_path = true;
            }
        }
        if (has_rail and has_path) {
            try mixed.append(arena, share);
        } else if (has_path) try path_only.append(arena, share);
    }
    const with_structural = try ledger.concatBundles(
        arena,
        try mixed.toOwnedSlice(arena),
        try structural.toOwnedSlice(arena),
    );
    return ledger.concatBundles(arena, with_structural, try path_only.toOwnedSlice(arena));
}
