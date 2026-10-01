const std = @import("std");
const sketch = @import("../sketch.zig");
const sketch_ports = @import("../sketch_ports.zig");
const ledger = @import("../base/ledger.zig");
const bundle_mod = @import("../base/bundle.zig");
const sharing_mod = @import("../base/sharing.zig");
const bridge_bundle_sets = @import("bridge_bundle_sets.zig");
const bridge_claims = @import("bridge_claims.zig");
const stitch_rails = @import("stitch_rails.zig");
const Final = @import("final_scene.zig").Final;

pub const PieceBundles = struct {
    bundles: ledger.RealizedBundles,
    edge_base: sketch.EdgeId,
};

pub fn merge(a: std.mem.Allocator, pieces: []const PieceBundles) error{OutOfMemory}!ledger.RealizedBundles {
    var selected: std.ArrayListUnmanaged(ledger.SelectedBundle) = .empty;
    var memberships: std.ArrayListUnmanaged(ledger.RealizedEdgeMembership) = .empty;
    var discharged: std.ArrayListUnmanaged(ledger.EdgeId) = .empty;

    for (pieces) |piece| {
        const j = piece.bundles;
        const jid_base: ledger.SelectedBundleId = @intCast(selected.items.len);
        for (j.selected_bundles) |sel| {
            const members = try a.alloc(ledger.EdgeId, sel.members.len);
            for (sel.members, members) |m, *out| out.* = m + piece.edge_base;
            try selected.append(a, .{
                .id = sel.id + jid_base,
                .proposal = sel.proposal,
                .candidate_bundle = sel.candidate_bundle,
                .members = members,
            });
        }
        for (j.memberships) |m| {
            try memberships.append(a, .{
                .edge = m.edge + piece.edge_base,
                .source = shiftDisposition(m.source, jid_base),
                .target = shiftDisposition(m.target, jid_base),
            });
        }
        for (j.discharged) |e| try discharged.append(a, e + piece.edge_base);
    }

    return .{
        .selected_bundles = try selected.toOwnedSlice(a),
        .memberships = try memberships.toOwnedSlice(a),
        .discharged = try discharged.toOwnedSlice(a),
    };
}

fn shiftDisposition(d: ?ledger.MembershipDisposition, jid_base: ledger.SelectedBundleId) ?ledger.MembershipDisposition {
    const disp = d orelse return null;
    return switch (disp) {
        .selected => |jid| .{ .selected = jid + jid_base },
        .independent => disp,
    };
}

pub fn finalize(
    arena: std.mem.Allocator,
    fin: Final,
    claim_sources: []const stitch_rails.ChildSource,
    outer_node_map: []const sketch.NodeId,
    inherited_structural: []const bundle_mod.Bundle,
    realized: ledger.RealizedBundles,
) error{OutOfMemory}!sharing_mod.Sharing {
    const outer_sets = try bridge_bundle_sets.rebuildOuterSets(arena, fin);
    const structural = try bundle_mod.concatBundles(arena, inherited_structural, outer_sets);
    const transported = try stitch_rails.transport(arena, fin.sr, claim_sources, fin.outer, outer_node_map, fin.outer_base);
    return .{
        .realized = realized,
        .bundles = try sketch_ports.rebuildFinalPortShares(arena, structural, fin.paths, fin.rails),
        .claims = try bridge_claims.rebuild(arena, fin, transported),
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
