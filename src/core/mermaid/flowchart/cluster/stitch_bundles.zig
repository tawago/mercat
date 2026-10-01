const std = @import("std");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");

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
