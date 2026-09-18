//! Unit tests for ledger.zig (P2v Step 1 vectors). Aggregated into the
//! test build from entry.zig's `test {}` block — NOT imported by
//! ledger.zig itself — so the module keeps D-IR item 1's literal
//! `&.{}` lint allowlist.

const std = @import("std");
const prim = @import("prim");
const pb = @import("ledger.zig");
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
    const sets = [_]pb.Bundle{
        .{ .origin = .selected_bundle, .members = &left },
        .{ .origin = .fan_rail, .members = &right },
    };

    try expect(pb.bundleMembersAt(&sets, 1, 2, null));
    try expect(pb.bundleMembersAt(&sets, 4, 3, null));
    try expect(!pb.bundleMembersAt(&sets, 2, 3, null));
    try expect(!pb.bundleMembersAt(&sets, 1, 9, null));
    try expect(!pb.bundleMembersAt(&.{}, 1, 2, null));
}

test "bundles from a plan name one bundle per selected bundle" {
    var bundle_members = [_]pb.EdgeId{ 7, 8 };
    var other_members = [_]pb.EdgeId{ 20, 21, 22 };
    var sel = [_]pb.SelectedBundle{
        .{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &bundle_members },
        .{ .id = 1, .proposal = 1, .candidate_bundle = 1, .members = &other_members },
    };

    const sets = try pb.bundlesFromPlan(std.testing.allocator, .{ .selected_bundles = &sel });
    defer std.testing.allocator.free(sets);

    try expectEqual(@as(usize, 2), sets.len);
    try expectEqual(bundle_mod.BundleOrigin.selected_bundle, sets[0].origin);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 7, 8 }, sets[0].members);
    try expectEqual(bundle_mod.BundleOrigin.selected_bundle, sets[1].origin);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 20, 21, 22 }, sets[1].members);

    try expectEqual(@as(usize, 0), (try pb.bundlesFromPlan(std.testing.allocator, .{})).len);
}

test "D-PORT clause 4: every EdgeKind name→ordinal pair is pinned" {
    try expectEqual(@as(usize, 4), pb.edge_kind_ordinals.len);
    try expectEqual(@as(?u8, 0), pb.ordinalByName(&pb.edge_kind_ordinals, "solid"));
    try expectEqual(@as(?u8, 1), pb.ordinalByName(&pb.edge_kind_ordinals, "dotted"));
    try expectEqual(@as(?u8, 2), pb.ordinalByName(&pb.edge_kind_ordinals, "thick"));
    try expectEqual(@as(?u8, 3), pb.ordinalByName(&pb.edge_kind_ordinals, "invisible"));
    try expectEqual(@as(u8, 0), pb.edgeKindOrdinal(prim.EdgeKind.solid));
    try expectEqual(@as(u8, 1), pb.edgeKindOrdinal(prim.EdgeKind.dotted));
    try expectEqual(@as(u8, 2), pb.edgeKindOrdinal(prim.EdgeKind.thick));
    try expectEqual(@as(u8, 3), pb.edgeKindOrdinal(prim.EdgeKind.invisible));
}

test "D-PORT clause 4: every ArrowEnd name→ordinal pair is pinned" {
    try expectEqual(@as(usize, 5), pb.arrow_end_ordinals.len);
    try expectEqual(@as(?u8, 0), pb.ordinalByName(&pb.arrow_end_ordinals, "none"));
    try expectEqual(@as(?u8, 1), pb.ordinalByName(&pb.arrow_end_ordinals, "open"));
    try expectEqual(@as(?u8, 2), pb.ordinalByName(&pb.arrow_end_ordinals, "filled"));
    try expectEqual(@as(?u8, 3), pb.ordinalByName(&pb.arrow_end_ordinals, "circle"));
    try expectEqual(@as(?u8, 4), pb.ordinalByName(&pb.arrow_end_ordinals, "cross"));
    const ArrowEndMirror = enum { none, open, filled, circle, cross };
    try expectEqual(@as(u8, 0), pb.arrowEndOrdinal(ArrowEndMirror.none));
    try expectEqual(@as(u8, 1), pb.arrowEndOrdinal(ArrowEndMirror.open));
    try expectEqual(@as(u8, 2), pb.arrowEndOrdinal(ArrowEndMirror.filled));
    try expectEqual(@as(u8, 3), pb.arrowEndOrdinal(ArrowEndMirror.circle));
    try expectEqual(@as(u8, 4), pb.arrowEndOrdinal(ArrowEndMirror.cross));
    try expectEqual(@as(?u8, null), pb.ordinalByName(&pb.arrow_end_ordinals, "bidirectional"));
}

test "node key comparator is bytewise total order" {
    try expectEqual(std.math.Order.eq, pb.nodeKeyOrder("Hub", "Hub"));
    try expectEqual(std.math.Order.lt, pb.nodeKeyOrder("A", "B"));
    try expectEqual(std.math.Order.gt, pb.nodeKeyOrder("B", "A"));
    try expectEqual(std.math.Order.lt, pb.nodeKeyOrder("A", "AB"));
    try expectEqual(std.math.Order.lt, pb.nodeKeyOrder("A10", "A9"));
}

test "label component orders no-label-first" {
    try expectEqual(std.math.Order.eq, pb.labelOrder(null, null));
    try expectEqual(std.math.Order.lt, pb.labelOrder(null, ""));
    try expectEqual(std.math.Order.lt, pb.labelOrder(null, "x"));
    try expectEqual(std.math.Order.gt, pb.labelOrder("x", null));
    try expectEqual(std.math.Order.lt, pb.labelOrder("a", "b"));
    try expectEqual(std.math.Order.eq, pb.labelOrder("a", "a"));
}

const base_edge_key = pb.EdgeKey{
    .from = "S",
    .to = "T",
    .kind = 0,
    .arrow_from = 0,
    .arrow_to = 2,
    .label = null,
};

test "edge key comparator orders field-by-field with no-label-first" {
    try expectEqual(std.math.Order.eq, pb.edgeKeyOrder(base_edge_key, base_edge_key));

    var b = base_edge_key;
    b.from = "R";
    b.label = "zzz";
    try expectEqual(std.math.Order.gt, pb.edgeKeyOrder(base_edge_key, b));

    b = base_edge_key;
    b.to = "U";
    try expectEqual(std.math.Order.lt, pb.edgeKeyOrder(base_edge_key, b));

    b = base_edge_key;
    b.kind = 1;
    try expectEqual(std.math.Order.lt, pb.edgeKeyOrder(base_edge_key, b));

    b = base_edge_key;
    b.arrow_from = 2;
    try expectEqual(std.math.Order.lt, pb.edgeKeyOrder(base_edge_key, b));
    b = base_edge_key;
    b.arrow_to = 0;
    try expectEqual(std.math.Order.gt, pb.edgeKeyOrder(base_edge_key, b));

    b = base_edge_key;
    b.label = "hit";
    try expectEqual(std.math.Order.lt, pb.edgeKeyOrder(base_edge_key, b));
}

const base_attachment_key = pb.AttachmentKey{
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

    try expectEqual(std.math.Order.eq, pb.attachmentKeyOrder(base_attachment_key, base_attachment_key));

    var b = base_attachment_key;
    b.opposite = "A";
    try expectEqual(std.math.Order.gt, pb.attachmentKeyOrder(base_attachment_key, b));

    b = base_attachment_key;
    b.endpoint_side = .target_entry;
    try expectEqual(std.math.Order.lt, pb.attachmentKeyOrder(base_attachment_key, b));

    b = base_attachment_key;
    b.kind = 3;
    try expectEqual(std.math.Order.lt, pb.attachmentKeyOrder(base_attachment_key, b));

    b = base_attachment_key;
    b.arrow_from = 4;
    try expectEqual(std.math.Order.lt, pb.attachmentKeyOrder(base_attachment_key, b));
    b = base_attachment_key;
    b.arrow_to = 1;
    try expectEqual(std.math.Order.gt, pb.attachmentKeyOrder(base_attachment_key, b));

    b = base_attachment_key;
    b.label = "w";
    try expectEqual(std.math.Order.lt, pb.attachmentKeyOrder(base_attachment_key, b));
}

fn expectSemanticFieldsOnly(comptime T: type) !void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const ok = f.type == []const u8 or f.type == ?[]const u8 or
            f.type == u8 or f.type == pb.EndpointSide;
        try expect(ok);
    }
}

test "comparator keys carry no numeric ids by construction" {
    try expectSemanticFieldsOnly(pb.EdgeKey);
    try expectSemanticFieldsOnly(pb.AttachmentKey);
}

test "keepOrigin selects exactly one origin's sets" {
    const sets = [_]pb.Bundle{
        .{ .origin = .fan_rail, .members = &.{ 0, 1 } },
        .{ .origin = .port_share, .members = &.{ 2, 3 } },
        .{ .origin = .selected_bundle, .members = &.{ 4, 5 } },
        .{ .origin = .port_share, .members = &.{ 6, 7 } },
    };
    const shares = try pb.keepOrigin(std.testing.allocator, &sets, .port_share);
    defer std.testing.allocator.free(shares);
    try expectEqual(@as(usize, 2), shares.len);
    try expect(pb.bundleMembersAt(shares, 2, 3, null));
    try expect(pb.bundleMembersAt(shares, 6, 7, null));
    try expect(!pb.bundleMembersAt(shares, 0, 1, null));

    const head = [_]pb.Bundle{.{ .origin = .selected_bundle, .members = &.{ 8, 9 } }};
    const joined = try pb.concatBundles(std.testing.allocator, &head, shares);
    defer std.testing.allocator.free(joined);
    try expectEqual(@as(usize, 3), joined.len);
    try expectEqual(bundle_mod.BundleOrigin.selected_bundle, joined[0].origin);
    try expect(pb.bundleMembersAt(joined, 8, 9, null));
    try expect(pb.bundleMembersAt(joined, 6, 7, null));

    const no_joins = [_]pb.Bundle{.{ .origin = .fan_rail, .members = &.{ 0, 1 } }};
    try expectEqual(@as(usize, 0), (try pb.keepOrigin(std.testing.allocator, &no_joins, .selected_bundle)).len);
    try expectEqual(@as(usize, 1), (try pb.concatBundles(std.testing.allocator, &head, &.{})).len);
}

test "a cell-scoped bundle answers only inside its licensed cells" {
    const licensed = [_]pb.BundleCell{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 3 } };
    const sets = [_]pb.Bundle{.{ .origin = .port_share, .members = &.{ 1, 2 }, .cells = &licensed }};
    try expect(pb.bundleMembersAt(&sets, 1, 2, .{ .x = 4, .y = 2 }));
    try expect(!pb.bundleMembersAt(&sets, 1, 2, .{ .x = 9, .y = 9 }));
    try expect(pb.bundleMembersAt(&sets, 1, 2, null));
    try expect(pb.bundleMembersAt(&sets, 1, 2, null));
    const wide = [_]pb.Bundle{.{ .origin = .fan_rail, .members = &.{ 1, 2 } }};
    try expect(pb.bundleMembersAt(&wide, 1, 2, .{ .x = 9, .y = 9 }));
}

test "a pairwise-scoped set licenses only a pair's own common approach, never a third member's" {
    const stem = [_]pb.BundleCell{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 8 } };
    const port_only = [_]pb.BundleCell{.{ .x = 5, .y = 3 }};
    const pairwise = [_]pb.PairCells{
        .{ .a = 0, .b = 1, .cells = &stem },
        .{ .a = 0, .b = 2, .cells = &port_only },
        .{ .a = 1, .b = 2, .cells = &port_only },
    };
    const union_cells = [_]pb.BundleCell{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 8 } };
    const unnumbered = [_]pb.Bundle{.{
        .origin = .port_share,
        .members = &.{ 0, 1, 2 },
        .cells = &union_cells,
        .pairwise = &pairwise,
    }};
    const sets = try pb.numberBundles(std.testing.allocator, &unnumbered);
    defer std.testing.allocator.free(sets);

    try expect(pb.bundleMembersAt(sets, 0, 1, null));
    try expect(pb.bundleMembersAt(sets, 0, 2, null));
    try expect(pb.bundleMembersAt(sets, 1, 2, null));

    try expect(pb.bundleMembersAt(sets, 0, 1, .{ .x = 5, .y = 8 }));
    try expect(!pb.bundleMembersAt(sets, 0, 2, .{ .x = 5, .y = 8 }));
    try expect(!pb.bundleMembersAt(sets, 1, 2, .{ .x = 5, .y = 8 }));
    try expect(pb.bundleMembersAt(sets, 0, 2, .{ .x = 5, .y = 3 }));
    try expect(pb.bundleMembersAt(sets, 1, 2, .{ .x = 5, .y = 3 }));

    try expect(pb.bundleOf(sets, 0, .{ .x = 5, .y = 8 }) != pb.no_bundle);
    try expect(pb.bundleOf(sets, 2, .{ .x = 5, .y = 8 }) == bundle_mod.privateBundle(2));
}

test "a numbered bundle set names every set exactly once" {
    const a = [_]pb.EdgeId{ 0, 1 };
    const b = [_]pb.EdgeId{ 2, 3 };
    const raw = [_]pb.Bundle{
        .{ .origin = .fan_rail, .bundle = 1, .members = &a },
        .{ .origin = .fan_rail, .bundle = 1, .members = &b },
    };
    try expect(!pb.bundleSetsNumbered(&[_]pb.Bundle{.{ .origin = .fan_rail, .members = &a }}));

    const bundle_sets = try pb.numberBundles(std.testing.allocator, &raw);
    defer std.testing.allocator.free(bundle_sets);
    try expect(pb.bundleSetsNumbered(bundle_sets));
    try expectEqual(@as(pb.BundleId, 1), bundle_sets[0].bundle);
    try expectEqual(@as(pb.BundleId, 2), bundle_sets[1].bundle);

    try expectEqual(@as(pb.BundleId, 1), pb.bundleOf(bundle_sets, 0, null));
    try expectEqual(@as(pb.BundleId, 2), pb.bundleOf(bundle_sets, 3, null));
    try expect(pb.bundleOf(bundle_sets, 0, null) == pb.bundleOf(bundle_sets, 1, null));
    try expect(pb.bundleOf(bundle_sets, 1, null) != pb.bundleOf(bundle_sets, 2, null));

    try expect(bundle_mod.privateBundle(0) != bundle_mod.privateBundle(1));
    try expectEqual(bundle_mod.privateBundle(9), pb.bundleOf(bundle_sets, 9, null));
    try expect(pb.bundleOf(bundle_sets, 9, null) != pb.bundleOf(bundle_sets, 8, null));

    const blank = [_]pb.Bundle{.{ .origin = .fan_rail, .members = &a }};
    try expectEqual(bundle_mod.privateBundle(0), pb.bundleOf(&blank, 0, null));
    try expect(pb.bundleOf(&blank, 0, null) != pb.bundleOf(&blank, 1, null));
}

test "structural set resolution is unique and excludes scoped provenance" {
    const scoped = [_]pb.BundleCell{.{ .x = 3, .y = 4 }};
    const sets = [_]pb.Bundle{
        .{ .origin = .fan_rail, .members = &.{ 1, 2 } },
        .{ .origin = .selected_bundle, .members = &.{ 2, 3 } },
        .{ .origin = .port_share, .members = &.{4} },
        .{ .origin = .fan_rail, .members = &.{5}, .cells = &scoped },
    };

    switch (pb.resolveStructuralBundle(&sets, 1)) {
        .unique => |i| try expectEqual(@as(usize, 0), i),
        else => try expect(false),
    }
    switch (pb.resolveStructuralBundle(&sets, 2)) {
        .multiple => {},
        else => try expect(false),
    }
    switch (pb.resolveStructuralBundle(&sets, 4)) {
        .absent => {},
        else => try expect(false),
    }
    switch (pb.resolveStructuralBundle(&sets, 5)) {
        .absent => {},
        else => try expect(false),
    }
}

test "a bundle asked by name holds its member on every cell, whichever set names the edge first" {
    // Edge 1 is a member of two structural sets: the fan-out {0, 1} stamped
    // first and the fan-in {1, 2} stamped second (rail membership at both
    // ends). Both license everywhere, so `bundleOf` resolves edge 1 to the
    // first one at every cell; asked by NAME, each set holds it.
    const fan_out = [_]pb.EdgeId{ 0, 1 };
    const fan_in = [_]pb.EdgeId{ 1, 2 };
    const raw = [_]pb.Bundle{
        .{ .origin = .fan_rail, .members = &fan_out },
        .{ .origin = .fan_rail, .members = &fan_in },
    };
    const sets = try pb.numberBundles(std.testing.allocator, &raw);
    defer std.testing.allocator.free(sets);
    const here: pb.BundleCell = .{ .x = 9, .y = 9 };

    try expectEqual(@as(pb.BundleId, 1), pb.bundleOf(sets, 1, here));
    try expect(pb.memberOfBundleAt(sets, 1, 1, here));
    try expect(pb.memberOfBundleAt(sets, 2, 1, here));
    try expect(pb.memberOfBundleAt(sets, 2, 2, here));
    try expect(!pb.memberOfBundleAt(sets, 1, 2, here));
    try expect(!pb.memberOfBundleAt(sets, 2, 0, here));
    // A name no set carries holds nobody; so does "not filed".
    try expect(!pb.memberOfBundleAt(sets, 3, 1, here));
    try expect(!pb.memberOfBundleAt(sets, pb.no_bundle, 1, here));
    // An unnumbered list names nothing, so nothing is a member of anything.
    try expect(!pb.memberOfBundleAt(&raw, 1, 1, here));

    // A cell-scoped set holds its member only on its own cells.
    const cells = [_]pb.BundleCell{.{ .x = 2, .y = 2 }};
    const scoped_raw = [_]pb.Bundle{.{ .origin = .port_share, .members = &fan_out, .cells = &cells }};
    const scoped = try pb.numberBundles(std.testing.allocator, &scoped_raw);
    defer std.testing.allocator.free(scoped);
    try expect(pb.memberOfBundleAt(scoped, 1, 0, .{ .x = 2, .y = 2 }));
    try expect(!pb.memberOfBundleAt(scoped, 1, 0, .{ .x = 7, .y = 7 }));
    try expect(pb.memberOfBundleAt(scoped, 1, 0, null));
}

test "the derivation and the recorded identity answer alike on a declared bundle" {
    const members = [_]pb.EdgeId{ 4, 5 };
    const raw = [_]pb.Bundle{.{ .origin = .fan_rail, .members = &members }};
    const bundle_sets = try pb.numberBundles(std.testing.allocator, &raw);
    defer std.testing.allocator.free(bundle_sets);

    try expect(pb.derivedSameBundle(.{}, bundle_sets, 4, 5, null));
    try expect(pb.bundleOf(bundle_sets, 4, null) == pb.bundleOf(bundle_sets, 5, null));
    try expect(!pb.derivedSameBundle(.{}, bundle_sets, 4, 6, null));
    try expect(pb.bundleOf(bundle_sets, 4, null) != pb.bundleOf(bundle_sets, 6, null));

    const here = [_]pb.BundleCell{.{ .x = 2, .y = 2 }};
    const scoped_raw = [_]pb.Bundle{.{ .origin = .port_share, .members = &members, .cells = &here }};
    const scoped = try pb.numberBundles(std.testing.allocator, &scoped_raw);
    defer std.testing.allocator.free(scoped);
    try expect(pb.derivedSameBundle(.{}, scoped, 4, 5, .{ .x = 2, .y = 2 }));
    try expect(pb.bundleOf(scoped, 4, .{ .x = 2, .y = 2 }) == pb.bundleOf(scoped, 5, .{ .x = 2, .y = 2 }));
    try expect(!pb.derivedSameBundle(.{}, scoped, 4, 5, .{ .x = 7, .y = 7 }));
    try expect(pb.bundleOf(scoped, 4, .{ .x = 7, .y = 7 }) != pb.bundleOf(scoped, 5, .{ .x = 7, .y = 7 }));
}

test {
    _ = @import("rail_star_test.zig");
}
