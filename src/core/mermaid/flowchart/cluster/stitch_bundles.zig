const std = @import("std");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");

pub const PieceBundles = struct {
    bundles: ledger.RealizedBundles,
    edge_base: sketch.EdgeId,
};

pub fn merge(a: std.mem.Allocator, pieces: []const PieceBundles, bridge: ledger.RealizedBundles) error{OutOfMemory}!ledger.RealizedBundles {
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

    const bridge_jid_base: ledger.SelectedBundleId = @intCast(selected.items.len);
    for (bridge.selected_bundles) |sel| {
        try selected.append(a, .{
            .id = sel.id + bridge_jid_base,
            .proposal = sel.proposal,
            .candidate_bundle = sel.candidate_bundle,
            .members = sel.members,
        });
    }
    for (bridge.memberships) |m| {
        try memberships.append(a, .{
            .edge = m.edge,
            .source = shiftDisposition(m.source, bridge_jid_base),
            .target = shiftDisposition(m.target, bridge_jid_base),
        });
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

test "merge renumbers bundles per piece and shifts every edge id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m0 = [_]ledger.EdgeId{ 0, 1 };
    const m1 = [_]ledger.EdgeId{ 2, 3 };
    const piece_a: ledger.RealizedBundles = .{
        .selected_bundles = &.{.{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &m0 }},
        .memberships = &.{
            .{ .edge = 0, .source = .{ .selected = 0 }, .target = null },
            .{ .edge = 1, .source = .{ .selected = 0 }, .target = null },
        },
        .discharged = &.{1},
    };
    const piece_b: ledger.RealizedBundles = .{
        .selected_bundles = &.{.{ .id = 0, .proposal = 1, .candidate_bundle = 2, .members = &m1 }},
        .memberships = &.{
            .{ .edge = 2, .source = null, .target = .{ .selected = 0 } },
        },
    };
    const merged = try merge(a, &.{
        .{ .bundles = piece_a, .edge_base = 0 },
        .{ .bundles = piece_b, .edge_base = 10 },
    }, .{});

    try std.testing.expectEqual(@as(usize, 2), merged.selected_bundles.len);
    try std.testing.expectEqual(@as(ledger.SelectedBundleId, 0), merged.selected_bundles[0].id);
    try std.testing.expectEqual(@as(ledger.SelectedBundleId, 1), merged.selected_bundles[1].id);
    try std.testing.expectEqualSlices(ledger.EdgeId, &.{ 0, 1 }, merged.selected_bundles[0].members);
    try std.testing.expectEqualSlices(ledger.EdgeId, &.{ 12, 13 }, merged.selected_bundles[1].members);
    try std.testing.expectEqual(@as(ledger.EdgeId, 12), merged.memberships[2].edge);
    try std.testing.expectEqual(ledger.MembershipDisposition{ .selected = 1 }, merged.memberships[2].target.?);
    try std.testing.expectEqualSlices(ledger.EdgeId, &.{1}, merged.discharged);
}
