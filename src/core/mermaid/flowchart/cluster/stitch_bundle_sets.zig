const std = @import("std");
const sketch = @import("../sketch.zig");
const sketch_ports = @import("../sketch_ports.zig");
const rail_star = @import("../base/rail_star.zig");
const bundle_mod = @import("../base/bundle.zig");
const split_mod = @import("split.zig");
const bridge_bundle_sets = @import("bridge_bundle_sets.zig");
const bridge_claims = @import("bridge_claims.zig");
const stitch_rails = @import("stitch_rails.zig");

pub const Authority = struct {
    sets: []const bundle_mod.Bundle,
    claims: []const rail_star.RailClaim,
};

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
    rails_buf: []const sketch.Rail,
    placements: []const sketch.NodePlacement,
    inherited_structural: []const bundle_mod.Bundle,
) error{OutOfMemory}!Authority {
    const outer_sets = try bridge_bundle_sets.rebuildOuterSets(
        arena,
        sr,
        outer,
        outer_base,
        bridge_base,
        paths,
        bridges,
        rails_buf,
    );
    const structural = try bundle_mod.concatBundles(arena, inherited_structural, outer_sets);
    const transported = try stitch_rails.transport(arena, sr, claim_sources, outer, outer_node_map, outer_base);
    return .{
        .sets = try sketch_ports.rebuildFinalPortShares(arena, structural, paths, rails_buf),
        .claims = try bridge_claims.rebuild(
            arena,
            sr,
            outer,
            transported,
            outer_base,
            bridge_base,
            paths,
            bridges,
            rails_buf,
            placements,
        ),
    };
}

pub fn shiftSet(
    arena: std.mem.Allocator,
    cs: bundle_mod.Bundle,
    base: sketch.EdgeId,
    dx: i32,
    dy: i32,
) error{OutOfMemory}!bundle_mod.Bundle {
    const members = try arena.alloc(sketch.EdgeId, cs.members.len);
    for (cs.members, 0..) |m, i| members[i] = m + base;
    var cells: ?[]const bundle_mod.BundleCell = null;
    if (cs.cells) |list| cells = try translateCells(arena, list, dx, dy);
    var pairwise: ?[]const bundle_mod.PairCells = null;
    if (cs.pairwise) |list| {
        const shifted = try arena.alloc(bundle_mod.PairCells, list.len);
        for (list, 0..) |p, i| shifted[i] = .{
            .a = p.a + base,
            .b = p.b + base,
            .cells = try translateCells(arena, p.cells, dx, dy),
        };
        pairwise = shifted;
    }
    return .{ .origin = cs.origin, .members = members, .cells = cells, .pairwise = pairwise };
}

fn translateCells(
    arena: std.mem.Allocator,
    cells: []const bundle_mod.BundleCell,
    dx: i32,
    dy: i32,
) error{OutOfMemory}![]const bundle_mod.BundleCell {
    const out = try arena.alloc(bundle_mod.BundleCell, cells.len);
    for (cells, 0..) |c, i| out[i] = .{ .x = c.x + dx, .y = c.y + dy };
    return out;
}
