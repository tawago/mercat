const std = @import("std");
const prim = @import("prim");
const pb = @import("ledger.zig");
const bundle_plan = @import("bundle_plan.zig");
const tie_break = @import("tie_break.zig");
const bundle_mod = @import("bundle.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "V-D-POLICY-01: BundlePolicy has exactly one variant, named joined" {
    const info = @typeInfo(pb.BundlePolicy).@"enum";
    try expectEqual(@as(usize, 1), info.fields.len);
    try expectEqualStrings("joined", info.fields[0].name);
}

fn expectJoined(policy: anytype) !void {
    try expect(std.mem.eql(u8, @tagName(policy), "joined"));
}

test "V-D-POLICY-05: joined invariants hold without switching on the policy enum" {
    try expectJoined(pb.BundlePolicy.joined);
    const ShadowPolicy = enum { joined, separate };
    try expectJoined(ShadowPolicy.joined);
    try std.testing.expectError(error.TestUnexpectedResult, expectJoined(ShadowPolicy.separate));
}

test "identity handles match prim's" {
    try expect(pb.NodeId == prim.NodeId);
    try expect(pb.EdgeId == prim.EdgeId);
}

test "empty RealizedBundles is default-constructible with all-empty fields" {
    const plan: pb.RealizedBundles = .{};
    try expectEqual(@as(usize, 0), plan.selected_bundles.len);
    try expectEqual(@as(usize, 0), plan.rejected_proposals.len);
    try expectEqual(@as(usize, 0), plan.memberships.len);
    try expectEqual(@as(usize, 0), plan.terminal_ports.len);
}

test "co-membership needs both edges inside one set" {
    var left = [_]pb.EdgeId{ 1, 2 };
    var right = [_]pb.EdgeId{ 3, 4 };
    const sets = [_]bundle_mod.Bundle{
        .{ .origin = .selected_bundle, .members = &left },
        .{ .origin = .fan_rail, .members = &right },
    };

    try expect(bundle_mod.bundleMembersAt(&sets, 1, 2, null));
    try expect(bundle_mod.bundleMembersAt(&sets, 4, 3, null));
    try expect(!bundle_mod.bundleMembersAt(&sets, 2, 3, null));
    try expect(!bundle_mod.bundleMembersAt(&sets, 1, 9, null));
    try expect(!bundle_mod.bundleMembersAt(&.{}, 1, 2, null));
}

test "bundles from a plan name one bundle per selected bundle" {
    var bundle_members = [_]pb.EdgeId{ 7, 8 };
    var other_members = [_]pb.EdgeId{ 20, 21, 22 };
    var sel = [_]pb.SelectedBundle{
        .{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &bundle_members },
        .{ .id = 1, .proposal = 1, .candidate_bundle = 1, .members = &other_members },
    };

    const sets = try bundle_plan.bundlesFromPlan(std.testing.allocator, .{ .selected_bundles = &sel });
    defer std.testing.allocator.free(sets);

    try expectEqual(@as(usize, 2), sets.len);
    try expectEqual(bundle_mod.BundleOrigin.selected_bundle, sets[0].origin);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 7, 8 }, sets[0].members);
    try expectEqual(bundle_mod.BundleOrigin.selected_bundle, sets[1].origin);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 20, 21, 22 }, sets[1].members);

    try expectEqual(@as(usize, 0), (try bundle_plan.bundlesFromPlan(std.testing.allocator, .{})).len);
}

test "D-PORT clause 4: every EdgeKind name→ordinal pair is pinned" {
    try expectEqual(@as(usize, 4), tie_break.edge_kind_ordinals.len);
    try expectEqual(@as(?u8, 0), tie_break.ordinalByName(&tie_break.edge_kind_ordinals, "solid"));
    try expectEqual(@as(?u8, 1), tie_break.ordinalByName(&tie_break.edge_kind_ordinals, "dotted"));
    try expectEqual(@as(?u8, 2), tie_break.ordinalByName(&tie_break.edge_kind_ordinals, "thick"));
    try expectEqual(@as(?u8, 3), tie_break.ordinalByName(&tie_break.edge_kind_ordinals, "invisible"));
    try expectEqual(@as(u8, 0), tie_break.edgeKindOrdinal(prim.EdgeKind.solid));
    try expectEqual(@as(u8, 1), tie_break.edgeKindOrdinal(prim.EdgeKind.dotted));
    try expectEqual(@as(u8, 2), tie_break.edgeKindOrdinal(prim.EdgeKind.thick));
    try expectEqual(@as(u8, 3), tie_break.edgeKindOrdinal(prim.EdgeKind.invisible));
}

test "D-PORT clause 4: every ArrowEnd name→ordinal pair is pinned" {
    try expectEqual(@as(usize, 5), tie_break.arrow_end_ordinals.len);
    try expectEqual(@as(?u8, 0), tie_break.ordinalByName(&tie_break.arrow_end_ordinals, "none"));
    try expectEqual(@as(?u8, 1), tie_break.ordinalByName(&tie_break.arrow_end_ordinals, "open"));
    try expectEqual(@as(?u8, 2), tie_break.ordinalByName(&tie_break.arrow_end_ordinals, "filled"));
    try expectEqual(@as(?u8, 3), tie_break.ordinalByName(&tie_break.arrow_end_ordinals, "circle"));
    try expectEqual(@as(?u8, 4), tie_break.ordinalByName(&tie_break.arrow_end_ordinals, "cross"));
    const ArrowEndMirror = enum { none, open, filled, circle, cross };
    try expectEqual(@as(u8, 0), tie_break.arrowEndOrdinal(ArrowEndMirror.none));
    try expectEqual(@as(u8, 1), tie_break.arrowEndOrdinal(ArrowEndMirror.open));
    try expectEqual(@as(u8, 2), tie_break.arrowEndOrdinal(ArrowEndMirror.filled));
    try expectEqual(@as(u8, 3), tie_break.arrowEndOrdinal(ArrowEndMirror.circle));
    try expectEqual(@as(u8, 4), tie_break.arrowEndOrdinal(ArrowEndMirror.cross));
    try expectEqual(@as(?u8, null), tie_break.ordinalByName(&tie_break.arrow_end_ordinals, "bidirectional"));
}

test "node key comparator is bytewise total order" {
    try expectEqual(std.math.Order.eq, tie_break.nodeKeyOrder("Hub", "Hub"));
    try expectEqual(std.math.Order.lt, tie_break.nodeKeyOrder("A", "B"));
    try expectEqual(std.math.Order.gt, tie_break.nodeKeyOrder("B", "A"));
    try expectEqual(std.math.Order.lt, tie_break.nodeKeyOrder("A", "AB"));
    try expectEqual(std.math.Order.lt, tie_break.nodeKeyOrder("A10", "A9"));
}

test "label component orders no-label-first" {
    try expectEqual(std.math.Order.eq, tie_break.labelOrder(null, null));
    try expectEqual(std.math.Order.lt, tie_break.labelOrder(null, ""));
    try expectEqual(std.math.Order.lt, tie_break.labelOrder(null, "x"));
    try expectEqual(std.math.Order.gt, tie_break.labelOrder("x", null));
    try expectEqual(std.math.Order.lt, tie_break.labelOrder("a", "b"));
    try expectEqual(std.math.Order.eq, tie_break.labelOrder("a", "a"));
}

const base_edge_key = tie_break.EdgeKey{
    .from = "S",
    .to = "T",
    .kind = 0,
    .arrow_from = 0,
    .arrow_to = 2,
    .label = null,
};

test "edge key comparator orders field-by-field with no-label-first" {
    try expectEqual(std.math.Order.eq, tie_break.edgeKeyOrder(base_edge_key, base_edge_key));

    var b = base_edge_key;
    b.from = "R";
    b.label = "zzz";
    try expectEqual(std.math.Order.gt, tie_break.edgeKeyOrder(base_edge_key, b));

    b = base_edge_key;
    b.to = "U";
    try expectEqual(std.math.Order.lt, tie_break.edgeKeyOrder(base_edge_key, b));

    b = base_edge_key;
    b.kind = 1;
    try expectEqual(std.math.Order.lt, tie_break.edgeKeyOrder(base_edge_key, b));

    b = base_edge_key;
    b.arrow_from = 2;
    try expectEqual(std.math.Order.lt, tie_break.edgeKeyOrder(base_edge_key, b));
    b = base_edge_key;
    b.arrow_to = 0;
    try expectEqual(std.math.Order.gt, tie_break.edgeKeyOrder(base_edge_key, b));

    b = base_edge_key;
    b.label = "hit";
    try expectEqual(std.math.Order.lt, tie_break.edgeKeyOrder(base_edge_key, b));
}

const base_attachment_key = tie_break.AttachmentKey{
    .opposite = "T",
    .endpoint_side = .source_exit,
    .kind = 0,
    .arrow_from = 0,
    .arrow_to = 2,
    .label = null,
};

test "attachment key K orders field-by-field with pinned ordinals" {
    try expectEqual(@as(u1, 0), @intFromEnum(pb.EndpointSide.source_exit));
    try expectEqual(@as(u1, 1), @intFromEnum(pb.EndpointSide.target_entry));

    try expectEqual(std.math.Order.eq, tie_break.attachmentKeyOrder(base_attachment_key, base_attachment_key));

    var b = base_attachment_key;
    b.opposite = "A";
    try expectEqual(std.math.Order.gt, tie_break.attachmentKeyOrder(base_attachment_key, b));

    b = base_attachment_key;
    b.endpoint_side = .target_entry;
    try expectEqual(std.math.Order.lt, tie_break.attachmentKeyOrder(base_attachment_key, b));

    b = base_attachment_key;
    b.kind = 3;
    try expectEqual(std.math.Order.lt, tie_break.attachmentKeyOrder(base_attachment_key, b));

    b = base_attachment_key;
    b.arrow_from = 4;
    try expectEqual(std.math.Order.lt, tie_break.attachmentKeyOrder(base_attachment_key, b));
    b = base_attachment_key;
    b.arrow_to = 1;
    try expectEqual(std.math.Order.gt, tie_break.attachmentKeyOrder(base_attachment_key, b));

    b = base_attachment_key;
    b.label = "w";
    try expectEqual(std.math.Order.lt, tie_break.attachmentKeyOrder(base_attachment_key, b));
}

fn expectSemanticFieldsOnly(comptime T: type) !void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const ok = f.type == []const u8 or f.type == ?[]const u8 or
            f.type == u8 or f.type == pb.EndpointSide;
        try expect(ok);
    }
}

test "comparator keys carry no numeric ids by construction" {
    try expectSemanticFieldsOnly(tie_break.EdgeKey);
    try expectSemanticFieldsOnly(tie_break.AttachmentKey);
}

test "concatBundles joins two populations and keeps the head first" {
    const shares = [_]bundle_mod.Bundle{
        .{ .origin = .port_share, .members = &.{ 2, 3 } },
        .{ .origin = .port_share, .members = &.{ 6, 7 } },
    };
    const head = [_]bundle_mod.Bundle{.{ .origin = .selected_bundle, .members = &.{ 8, 9 } }};
    const joined = try bundle_mod.concatBundles(std.testing.allocator, &head, &shares);
    defer std.testing.allocator.free(joined);
    try expectEqual(@as(usize, 3), joined.len);
    try expectEqual(bundle_mod.BundleOrigin.selected_bundle, joined[0].origin);
    try expect(bundle_mod.bundleMembersAt(joined, 8, 9, null));
    try expect(bundle_mod.bundleMembersAt(joined, 2, 3, null));
    try expect(bundle_mod.bundleMembersAt(joined, 6, 7, null));

    try expectEqual(@as(usize, 1), (try bundle_mod.concatBundles(std.testing.allocator, &head, &.{})).len);
    try expectEqual(@as(usize, 2), (try bundle_mod.concatBundles(std.testing.allocator, &.{}, &shares)).len);
}

test "a cell-scoped bundle answers only inside its licensed cells" {
    const licensed = [_]bundle_mod.BundleCell{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 3 } };
    const sets = [_]bundle_mod.Bundle{.{ .origin = .port_share, .members = &.{ 1, 2 }, .cells = &licensed }};
    try expect(bundle_mod.bundleMembersAt(&sets, 1, 2, .{ .x = 4, .y = 2 }));
    try expect(!bundle_mod.bundleMembersAt(&sets, 1, 2, .{ .x = 9, .y = 9 }));
    try expect(bundle_mod.bundleMembersAt(&sets, 1, 2, null));
    try expect(bundle_mod.bundleMembersAt(&sets, 1, 2, null));
    const wide = [_]bundle_mod.Bundle{.{ .origin = .fan_rail, .members = &.{ 1, 2 } }};
    try expect(bundle_mod.bundleMembersAt(&wide, 1, 2, .{ .x = 9, .y = 9 }));
}

test "a pairwise-scoped set licenses only a pair's own common approach, never a third member's" {
    const stem = [_]bundle_mod.BundleCell{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 8 } };
    const port_only = [_]bundle_mod.BundleCell{.{ .x = 5, .y = 3 }};
    const pairwise = [_]bundle_mod.PairCells{
        .{ .a = 0, .b = 1, .cells = &stem },
        .{ .a = 0, .b = 2, .cells = &port_only },
        .{ .a = 1, .b = 2, .cells = &port_only },
    };
    const union_cells = [_]bundle_mod.BundleCell{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 8 } };
    const sets = [_]bundle_mod.Bundle{.{
        .origin = .port_share,
        .members = &.{ 0, 1, 2 },
        .cells = &union_cells,
        .pairwise = &pairwise,
    }};

    try expect(bundle_mod.bundleMembersAt(&sets, 0, 1, null));
    try expect(bundle_mod.bundleMembersAt(&sets, 0, 2, null));
    try expect(bundle_mod.bundleMembersAt(&sets, 1, 2, null));

    try expect(bundle_mod.bundleMembersAt(&sets, 0, 1, .{ .x = 5, .y = 8 }));
    try expect(!bundle_mod.bundleMembersAt(&sets, 0, 2, .{ .x = 5, .y = 8 }));
    try expect(!bundle_mod.bundleMembersAt(&sets, 1, 2, .{ .x = 5, .y = 8 }));
    try expect(bundle_mod.bundleMembersAt(&sets, 0, 2, .{ .x = 5, .y = 3 }));
    try expect(bundle_mod.bundleMembersAt(&sets, 1, 2, .{ .x = 5, .y = 3 }));
}

test "derived sameness follows declared membership and licensed cells" {
    const members = [_]pb.EdgeId{ 4, 5 };
    const declared = [_]bundle_mod.Bundle{.{ .origin = .fan_rail, .members = &members }};
    try expect(bundle_plan.derivedSameBundle(.{}, &declared, 4, 5, null));
    try expect(!bundle_plan.derivedSameBundle(.{}, &declared, 4, 6, null));

    const here = [_]bundle_mod.BundleCell{.{ .x = 2, .y = 2 }};
    const scoped = [_]bundle_mod.Bundle{.{ .origin = .port_share, .members = &members, .cells = &here }};
    try expect(bundle_plan.derivedSameBundle(.{}, &scoped, 4, 5, .{ .x = 2, .y = 2 }));
    try expect(!bundle_plan.derivedSameBundle(.{}, &scoped, 4, 5, .{ .x = 7, .y = 7 }));
}

test {
    _ = @import("rail_star_test.zig");
}
