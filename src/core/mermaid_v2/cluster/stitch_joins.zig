//! Realized-join transport for stitch: piece RealizedJoins records merge
//! into the one record the merged Sketch carries, rewritten into merged id
//! spaces — edge ids by the piece's stitch offset, node ids through the
//! piece's node map, selected-join ids renumbered across the merge. Group
//! and proposal ids stay piece-plan-internal (their plans do not survive
//! the piece); no merged-sketch consumer dereferences them.

const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");

pub const PieceJoins = struct {
    joins: ledger.RealizedJoins,
    edge_base: sketch.EdgeId,
    /// Piece sketch node id -> merged node id (SENTINEL where unmapped).
    node_map: []const sketch.NodeId,
};

/// Merge piece records in order. Selected-join ids are renumbered to one
/// ascending sequence and every `.selected` disposition follows its join.
pub fn merge(a: std.mem.Allocator, pieces: []const PieceJoins) error{OutOfMemory}!ledger.RealizedJoins {
    var selected: std.ArrayListUnmanaged(ledger.SelectedJoin) = .empty;
    var memberships: std.ArrayListUnmanaged(ledger.RealizedEdgeMembership) = .empty;
    var terminals: std.ArrayListUnmanaged(ledger.TerminalPort) = .empty;
    var co_realized: std.ArrayListUnmanaged(ledger.EdgeId) = .empty;

    for (pieces) |piece| {
        const j = piece.joins;
        const jid_base: ledger.RealizedJoinId = @intCast(selected.items.len);
        for (j.selected_joins) |sel| {
            const members = try a.alloc(ledger.EdgeId, sel.members.len);
            for (sel.members, members) |m, *out| out.* = m + piece.edge_base;
            try selected.append(a, .{
                .id = sel.id + jid_base,
                .proposal = sel.proposal,
                .permission_group = sel.permission_group,
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
        for (j.terminal_ports) |t| {
            if (t.node >= piece.node_map.len) continue;
            const mapped = piece.node_map[t.node];
            if (mapped == sg.SENTINEL) continue;
            try terminals.append(a, .{
                .node = mapped,
                .edge = t.edge + piece.edge_base,
                .endpoint_side = t.endpoint_side,
                .port = t.port,
            });
        }
        for (j.co_realized) |e| try co_realized.append(a, e + piece.edge_base);
    }

    return .{
        .selected_joins = try selected.toOwnedSlice(a),
        .memberships = try memberships.toOwnedSlice(a),
        .terminal_ports = try terminals.toOwnedSlice(a),
        .co_realized = try co_realized.toOwnedSlice(a),
    };
}

fn shiftDisposition(d: ?ledger.MembershipDisposition, jid_base: ledger.RealizedJoinId) ?ledger.MembershipDisposition {
    const disp = d orelse return null;
    return switch (disp) {
        .selected => |jid| .{ .selected = jid + jid_base },
        .independent => disp,
    };
}

test "merge renumbers joins per piece and shifts every edge id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m0 = [_]ledger.EdgeId{ 0, 1 };
    const m1 = [_]ledger.EdgeId{ 2, 3 };
    const piece_a: ledger.RealizedJoins = .{
        .selected_joins = &.{.{ .id = 0, .proposal = 0, .permission_group = 0, .members = &m0 }},
        .memberships = &.{
            .{ .edge = 0, .source = .{ .selected = 0 }, .target = null },
            .{ .edge = 1, .source = .{ .selected = 0 }, .target = null },
        },
        .co_realized = &.{1},
    };
    const piece_b: ledger.RealizedJoins = .{
        .selected_joins = &.{.{ .id = 0, .proposal = 1, .permission_group = 2, .members = &m1 }},
        .memberships = &.{
            .{ .edge = 2, .source = null, .target = .{ .selected = 0 } },
        },
    };
    const node_map = [_]sketch.NodeId{ 7, 8 };

    const merged = try merge(a, &.{
        .{ .joins = piece_a, .edge_base = 0, .node_map = &node_map },
        .{ .joins = piece_b, .edge_base = 10, .node_map = &node_map },
    });

    try std.testing.expectEqual(@as(usize, 2), merged.selected_joins.len);
    try std.testing.expectEqual(@as(ledger.RealizedJoinId, 0), merged.selected_joins[0].id);
    try std.testing.expectEqual(@as(ledger.RealizedJoinId, 1), merged.selected_joins[1].id);
    try std.testing.expectEqualSlices(ledger.EdgeId, &.{ 0, 1 }, merged.selected_joins[0].members);
    try std.testing.expectEqualSlices(ledger.EdgeId, &.{ 12, 13 }, merged.selected_joins[1].members);
    try std.testing.expectEqual(@as(ledger.EdgeId, 12), merged.memberships[2].edge);
    try std.testing.expectEqual(ledger.MembershipDisposition{ .selected = 1 }, merged.memberships[2].target.?);
    try std.testing.expectEqualSlices(ledger.EdgeId, &.{1}, merged.co_realized);
}

test "merge drops a terminal port whose node did not survive the stitch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const joins: ledger.RealizedJoins = .{
        .terminal_ports = &.{
            .{ .node = 0, .edge = 0, .endpoint_side = .source_exit, .port = 2 },
            .{ .node = 1, .edge = 1, .endpoint_side = .target_entry, .port = 0 },
        },
    };
    const node_map = [_]sketch.NodeId{ 5, sg.SENTINEL };
    const merged = try merge(a, &.{.{ .joins = joins, .edge_base = 4, .node_map = &node_map }});
    try std.testing.expectEqual(@as(usize, 1), merged.terminal_ports.len);
    try std.testing.expectEqual(@as(sketch.NodeId, 5), merged.terminal_ports[0].node);
    try std.testing.expectEqual(@as(ledger.EdgeId, 4), merged.terminal_ports[0].edge);
}
