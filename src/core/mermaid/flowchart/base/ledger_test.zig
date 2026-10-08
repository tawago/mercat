const std = @import("std");
const pb = @import("ledger.zig");
const bundle_plan = @import("bundle_plan.zig");
const tie_break = @import("tie_break.zig");
const bundle_mod = @import("bundle.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "bundles from a plan name one bundle per selected bundle" {
    var bundle_members = [_]pb.EdgeId{ 7, 8 };
    var other_members = [_]pb.EdgeId{ 20, 21, 22 };
    var sel = [_]pb.SelectedBundle{
        .{ .id = 0, .candidate_bundle = 0, .members = &bundle_members },
        .{ .id = 1, .candidate_bundle = 1, .members = &other_members },
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

test "tie-break comparators order field by field, with no label first" {
    const Ord = std.math.Order;
    // null sorts before every label, even the empty one.
    const labels = [_]struct { ?[]const u8, ?[]const u8, Ord }{
        .{ null, null, .eq }, .{ null, "", .lt }, .{ null, "x", .lt },
        .{ "x", null, .gt },  .{ "a", "b", .lt }, .{ "a", "a", .eq },
    };
    for (labels) |r| try expectEqual(r[2], tie_break.labelOrder(r[0], r[1]));

    const E = tie_break.EdgeKey;
    const e: E = .{ .from = "S", .to = "T", .kind = 0, .arrow_from = 0, .arrow_to = 2, .label = null };
    const edge_rows = [_]struct { E, Ord }{
        .{ e, .eq },
        // An earlier field dominates a later label.
        .{ .{ .from = "R", .to = "T", .kind = 0, .arrow_from = 0, .arrow_to = 2, .label = "zzz" }, .gt },
        .{ .{ .from = "S", .to = "U", .kind = 0, .arrow_from = 0, .arrow_to = 2, .label = null }, .lt },
        .{ .{ .from = "S", .to = "T", .kind = 1, .arrow_from = 0, .arrow_to = 2, .label = null }, .lt },
        .{ .{ .from = "S", .to = "T", .kind = 0, .arrow_from = 2, .arrow_to = 2, .label = null }, .lt },
        .{ .{ .from = "S", .to = "T", .kind = 0, .arrow_from = 0, .arrow_to = 0, .label = null }, .gt },
        .{ .{ .from = "S", .to = "T", .kind = 0, .arrow_from = 0, .arrow_to = 2, .label = "hit" }, .lt },
    };
    for (edge_rows) |r| try expectEqual(r[1], tie_break.edgeKeyOrder(e, r[0]));

    const K = tie_break.AttachmentKey;
    const k: K = .{ .opposite = "T", .endpoint_side = .source_exit, .kind = 0, .arrow_from = 0, .arrow_to = 2, .label = null };
    const attachment_rows = [_]struct { K, Ord }{
        .{ k, .eq },
        .{ .{ .opposite = "A", .endpoint_side = .source_exit, .kind = 0, .arrow_from = 0, .arrow_to = 2, .label = null }, .gt },
        .{ .{ .opposite = "T", .endpoint_side = .target_entry, .kind = 0, .arrow_from = 0, .arrow_to = 2, .label = null }, .lt },
        .{ .{ .opposite = "T", .endpoint_side = .source_exit, .kind = 3, .arrow_from = 0, .arrow_to = 2, .label = null }, .lt },
        .{ .{ .opposite = "T", .endpoint_side = .source_exit, .kind = 0, .arrow_from = 4, .arrow_to = 2, .label = null }, .lt },
        .{ .{ .opposite = "T", .endpoint_side = .source_exit, .kind = 0, .arrow_from = 0, .arrow_to = 1, .label = null }, .gt },
        .{ .{ .opposite = "T", .endpoint_side = .source_exit, .kind = 0, .arrow_from = 0, .arrow_to = 2, .label = "w" }, .lt },
    };
    for (attachment_rows) |r| try expectEqual(r[1], tie_break.attachmentKeyOrder(k, r[0]));
}

test "a cell-scoped bundle answers only inside its licensed cells" {
    const licensed = [_]bundle_mod.BundleCell{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 3 } };
    const sets = [_]bundle_mod.Bundle{.{ .origin = .port_share, .members = &.{ 1, 2 }, .cells = &licensed }};
    try expect(bundle_mod.bundleMembersAt(&sets, 1, 2, .{ .x = 4, .y = 2 }));
    try expect(!bundle_mod.bundleMembersAt(&sets, 1, 2, .{ .x = 9, .y = 9 }));
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

test {
    _ = @import("rail_star_test.zig");
}
