//! Co-set transport and final-geometry derivation for stitch.
//!
//! Structural child sets shift into merged id space (transport of the piece
//! plans' records — nothing is decided here). Port shares do not pass
//! through this path in production; `finalizeAuthority` derives their whole
//! population from final merged paths (the coordinate agreement IS the
//! declaration), and rebuilds the report-tier claims. `shiftSet` still
//! performs an exact scoped translation for callers and its regression
//! fixture.

const std = @import("std");
const sketch = @import("../sketch.zig");
const sketch_ports = @import("../sketch_ports.zig");
const ledger = @import("../base/ledger.zig");
const split_mod = @import("split.zig");
const bridge_cosets = @import("bridge_cosets.zig");
const bridge_claims = @import("bridge_claims.zig");
const stitch_rails = @import("stitch_rails.zig");

pub const Authority = struct {
    sets: []const ledger.CoSet,
    claims: []const ledger.RailClaim,
};

/// Finalize the two authority rosters after routed bridges have final ids and
/// geometry. All returned co-sets are unstamped; stitch stamps once, last.
pub fn finalizeAuthority(
    arena: std.mem.Allocator,
    sr: split_mod.SplitResult,
    outer: sketch.Sketch,
    claim_sources: []const stitch_rails.ChildSource,
    outer_node_map: []const sketch.NodeId,
    outer_base: sketch.EdgeId,
    bridge_base: sketch.EdgeId,
    paths: []const sketch.EdgePath,
    bridges: []const sketch.EdgePath,
    bars: []const sketch.Rail,
    placements: []const sketch.NodePlacement,
    inherited_structural: []const ledger.CoSet,
) error{OutOfMemory}!Authority {
    const outer_sets = try bridge_cosets.rebuildOuterSets(
        arena,
        sr,
        outer,
        outer_base,
        bridge_base,
        paths,
        bridges,
        bars,
    );
    const structural = try ledger.concatSets(arena, inherited_structural, outer_sets);
    const transported = try stitch_rails.transport(arena, sr, claim_sources, outer, outer_node_map, outer_base);
    return .{
        .sets = try sketch_ports.rebuildFinalPortShares(arena, structural, paths, bars),
        .claims = try bridge_claims.rebuild(
            arena,
            sr,
            outer,
            transported,
            outer_base,
            bridge_base,
            paths,
            bridges,
            bars,
            placements,
        ),
    };
}

/// Copy a co-set with every member shifted into the piece's id window,
/// `.cells`/`.pairwise` translated by (dx, dy) rather than dropped.
/// guarded-by: stitch_cosets.zig "shiftSet carries a port-share set's cell scope and pairwise table across the id shift"
pub fn shiftSet(
    arena: std.mem.Allocator,
    cs: ledger.CoSet,
    base: sketch.EdgeId,
    dx: i32,
    dy: i32,
) error{OutOfMemory}!ledger.CoSet {
    const members = try arena.alloc(sketch.EdgeId, cs.members.len);
    for (cs.members, 0..) |m, i| members[i] = m + base;
    var cells: ?[]const ledger.CoCell = null;
    if (cs.cells) |list| cells = try translateCells(arena, list, dx, dy);
    var pairwise: ?[]const ledger.PairCells = null;
    if (cs.pairwise) |list| {
        const shifted = try arena.alloc(ledger.PairCells, list.len);
        for (list, 0..) |p, i| shifted[i] = .{
            .a = p.a + base,
            .b = p.b + base,
            .cells = try translateCells(arena, p.cells, dx, dy),
        };
        pairwise = shifted;
    }
    return .{ .origin = cs.origin, .members = members, .cells = cells, .pairwise = pairwise };
}

/// `cells`, each translated by (dx, dy) into the merged coordinate space —
/// the same translation `translateEdge` applies to a child's polyline.
fn translateCells(
    arena: std.mem.Allocator,
    cells: []const ledger.CoCell,
    dx: i32,
    dy: i32,
) error{OutOfMemory}![]const ledger.CoCell {
    const out = try arena.alloc(ledger.CoCell, cells.len);
    for (cells, 0..) |c, i| out[i] = .{ .x = c.x + dx, .y = c.y + dy };
    return out;
}

test "shiftSet carries a port-share set's cell scope and pairwise table across the id shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stem = [_]ledger.CoCell{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 8 } };
    const port_only = [_]ledger.CoCell{.{ .x = 5, .y = 3 }};
    const pairwise = [_]ledger.PairCells{
        .{ .a = 0, .b = 1, .cells = &stem },
        .{ .a = 0, .b = 2, .cells = &port_only },
    };
    const cs: ledger.CoSet = .{
        .origin = .port_share,
        .members = &.{ 0, 1, 2 },
        .cells = &stem,
        .pairwise = &pairwise,
    };

    const shifted = try shiftSet(a, cs, 100, 10, 20);
    try std.testing.expectEqualSlices(sketch.EdgeId, &.{ 100, 101, 102 }, shifted.members);
    try std.testing.expect(shifted.cells != null);
    try std.testing.expectEqual(@as(i32, 15), shifted.cells.?[0].x);
    try std.testing.expectEqual(@as(i32, 23), shifted.cells.?[0].y);
    try std.testing.expect(shifted.pairwise != null);
    try std.testing.expectEqual(@as(sketch.EdgeId, 100), shifted.pairwise.?[0].a);
    try std.testing.expectEqual(@as(sketch.EdgeId, 101), shifted.pairwise.?[0].b);
    try std.testing.expectEqual(@as(i32, 15), shifted.pairwise.?[0].cells[0].x);
    try std.testing.expectEqual(@as(sketch.EdgeId, 102), shifted.pairwise.?[1].b);
    try std.testing.expectEqual(@as(usize, 1), shifted.pairwise.?[1].cells.len);
    try std.testing.expectEqual(@as(i32, 15), shifted.pairwise.?[1].cells[0].x);
    try std.testing.expectEqual(@as(i32, 23), shifted.pairwise.?[1].cells[0].y);

    // A set with no cell scope stays scopeless.
    const wide: ledger.CoSet = .{ .origin = .fan_rail, .members = &.{ 5, 6 } };
    const shifted_wide = try shiftSet(a, wide, 0, 1, 1);
    try std.testing.expect(shifted_wide.cells == null);
    try std.testing.expect(shifted_wide.pairwise == null);
}
