//! Unit tests for ledger.zig (P2v Step 1 vectors). Aggregated into the
//! test build from entry.zig's `test {}` block — NOT imported by
//! ledger.zig itself — so the module keeps D-IR item 1's literal
//! `&.{}` lint allowlist.

const std = @import("std");
const prim = @import("prim");
const pb = @import("ledger.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// ---------------------------------------------------------------------------
// JoinPolicy (D-POLICY items 1, 10).
// ---------------------------------------------------------------------------

test "V-D-POLICY-01: JoinPolicy has exactly one variant, named joined" {
    const info = @typeInfo(pb.JoinPolicy).@"enum";
    try expectEqual(@as(usize, 1), info.fields.len);
    try expectEqualStrings("joined", info.fields[0].name);
}

// The joined invariant, asserted WITHOUT any `switch` on the policy enum:
// adding a future variant to a policy enum cannot redefine what `joined`
// asserts (D-POLICY item 10 / V-D-POLICY-05).
fn expectJoined(policy: anytype) !void {
    try expect(std.mem.eql(u8, @tagName(policy), "joined"));
}

test "V-D-POLICY-05: joined invariants hold without switching on the policy enum" {
    try expectJoined(pb.JoinPolicy.joined);
    // Test-only shadow enum with a second variant: the same no-switch
    // invariant check still compiles and passes for its `joined` value.
    const ShadowPolicy = enum { joined, separate };
    try expectJoined(ShadowPolicy.joined);
    try std.testing.expectError(error.TestUnexpectedResult, expectJoined(ShadowPolicy.separate));
}

// ---------------------------------------------------------------------------
// Identity handles and the defaulted envelope.
// ---------------------------------------------------------------------------

test "identity handles match prim's" {
    try expect(pb.NodeId == prim.NodeId);
    try expect(pb.EdgeId == prim.EdgeId);
}

test "empty RealizedJoins is default-constructible with all-empty fields" {
    const plan: pb.RealizedJoins = .{};
    try expectEqual(@as(usize, 0), plan.selected_joins.len);
    try expectEqual(@as(usize, 0), plan.rejected_proposals.len);
    try expectEqual(@as(usize, 0), plan.memberships.len);
    try expectEqual(@as(usize, 0), plan.conflicts.len);
    try expectEqual(@as(usize, 0), plan.terminal_ports.len);
}

test "co-membership needs both edges inside one set" {
    var left = [_]pb.EdgeId{ 1, 2 };
    var right = [_]pb.EdgeId{ 3, 4 };
    const sets = [_]pb.CoSet{
        .{ .origin = .selected_join, .members = &left },
        .{ .origin = .fan_rail, .members = &right },
    };

    try expect(pb.coMembers(&sets, 1, 2));
    try expect(pb.coMembers(&sets, 4, 3)); // order-free
    // One from each set is NOT co-membership: two channels are two channels.
    try expect(!pb.coMembers(&sets, 2, 3));
    try expect(!pb.coMembers(&sets, 1, 9));
    try expect(!pb.coMembers(&.{}, 1, 2));
}

test "co-sets from a plan name one channel per selected join" {
    var join_members = [_]pb.EdgeId{ 7, 8 };
    var other_members = [_]pb.EdgeId{ 20, 21, 22 };
    var sel = [_]pb.SelectedJoin{
        .{ .id = 0, .proposal = 0, .permission_group = 0, .members = &join_members },
        .{ .id = 1, .proposal = 1, .permission_group = 1, .members = &other_members },
    };

    const sets = try pb.coSetsFromPlan(std.testing.allocator, .{ .selected_joins = &sel });
    defer std.testing.allocator.free(sets);

    try expectEqual(@as(usize, 2), sets.len);
    try expectEqual(pb.CoOrigin.selected_join, sets[0].origin);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 7, 8 }, sets[0].members);
    try expectEqual(pb.CoOrigin.selected_join, sets[1].origin);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 20, 21, 22 }, sets[1].members);

    // An empty plan authorizes nothing and allocates nothing.
    try expectEqual(@as(usize, 0), (try pb.coSetsFromPlan(std.testing.allocator, .{})).len);
}

test "empty ComponentEntry is default-constructible with all-empty fields" {
    const entry: pb.ComponentEntry = .{};
    try expectEqual(@as(pb.ComponentId, 0), entry.id);
    try expectEqual(@as(usize, 0), entry.source_terminals.len);
    try expectEqual(@as(usize, 0), entry.target_terminals.len);
    try expectEqual(@as(usize, 0), entry.declared_pairs_in_component.len);
    try expectEqual(@as(usize, 0), entry.reachable_pairs.len);
    try expectEqual(@as(usize, 0), entry.missing_declared_pairs.len);
    try expectEqual(@as(usize, 0), entry.extra_undeclared_pairs.len);
    try expectEqual(@as(usize, 0), entry.selected_join_ids.len);
    try expectEqual(@as(usize, 0), entry.bridge_ids.len);
}

// ---------------------------------------------------------------------------
// Pinned ordinal tables (D-PORT clause 4 — every name→ordinal pair).
// ---------------------------------------------------------------------------

test "D-PORT clause 4: every EdgeKind name→ordinal pair is pinned" {
    try expectEqual(@as(usize, 4), pb.edge_kind_ordinals.len);
    try expectEqual(@as(?u8, 0), pb.ordinalByName(&pb.edge_kind_ordinals, "solid"));
    try expectEqual(@as(?u8, 1), pb.ordinalByName(&pb.edge_kind_ordinals, "dotted"));
    try expectEqual(@as(?u8, 2), pb.ordinalByName(&pb.edge_kind_ordinals, "thick"));
    try expectEqual(@as(?u8, 3), pb.ordinalByName(&pb.edge_kind_ordinals, "invisible"));
    // The production enum maps through the table by NAME, so a reorder of
    // prim.EdgeKind cannot change K.
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
    // Same-shape mirror of sem_graph.ArrowEnd (sem_graph.zig is not
    // importable from the prim tier); the map is by NAME, so the mirror
    // exercises exactly what production values will.
    const ArrowEndMirror = enum { none, open, filled, circle, cross };
    try expectEqual(@as(u8, 0), pb.arrowEndOrdinal(ArrowEndMirror.none));
    try expectEqual(@as(u8, 1), pb.arrowEndOrdinal(ArrowEndMirror.open));
    try expectEqual(@as(u8, 2), pb.arrowEndOrdinal(ArrowEndMirror.filled));
    try expectEqual(@as(u8, 3), pb.arrowEndOrdinal(ArrowEndMirror.circle));
    try expectEqual(@as(u8, 4), pb.arrowEndOrdinal(ArrowEndMirror.cross));
    try expectEqual(@as(?u8, null), pb.ordinalByName(&pb.arrow_end_ordinals, "bidirectional"));
}

// ---------------------------------------------------------------------------
// Canonical comparators (D-JOIN-SELECT item 1; D-PORT clauses 4, 6).
// ---------------------------------------------------------------------------

test "node key comparator is bytewise total order" {
    try expectEqual(std.math.Order.eq, pb.nodeKeyOrder("Hub", "Hub"));
    try expectEqual(std.math.Order.lt, pb.nodeKeyOrder("A", "B"));
    try expectEqual(std.math.Order.gt, pb.nodeKeyOrder("B", "A"));
    // Prefix sorts before its extension, and digits compare as bytes, not
    // numerically — the order is bytewise, never numeric-ID based.
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

    // Field 1: from (node key bytes) decides before anything else.
    var b = base_edge_key;
    b.from = "R";
    b.label = "zzz";
    try expectEqual(std.math.Order.gt, pb.edgeKeyOrder(base_edge_key, b));

    // Field 2: to.
    b = base_edge_key;
    b.to = "U";
    try expectEqual(std.math.Order.lt, pb.edgeKeyOrder(base_edge_key, b));

    // Field 3: stroke-kind ordinal.
    b = base_edge_key;
    b.kind = 1;
    try expectEqual(std.math.Order.lt, pb.edgeKeyOrder(base_edge_key, b));

    // Fields 4-5: arrow presence/direction (arrow_from then arrow_to).
    b = base_edge_key;
    b.arrow_from = 2;
    try expectEqual(std.math.Order.lt, pb.edgeKeyOrder(base_edge_key, b));
    b = base_edge_key;
    b.arrow_to = 0;
    try expectEqual(std.math.Order.gt, pb.edgeKeyOrder(base_edge_key, b));

    // Field 6: label bytes-or-absence, no-label first.
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
    // The pinned endpoint_side values are part of K itself.
    try expectEqual(@as(u1, 0), @intFromEnum(pb.EndpointSide.source_exit));
    try expectEqual(@as(u1, 1), @intFromEnum(pb.EndpointSide.target_entry));

    try expectEqual(std.math.Order.eq, pb.attachmentKeyOrder(base_attachment_key, base_attachment_key));

    // Field 1: opposite endpoint raw_id bytes.
    var b = base_attachment_key;
    b.opposite = "A";
    try expectEqual(std.math.Order.gt, pb.attachmentKeyOrder(base_attachment_key, b));

    // Field 2: endpoint_side (source-exit=0 before target-entry=1).
    b = base_attachment_key;
    b.endpoint_side = .target_entry;
    try expectEqual(std.math.Order.lt, pb.attachmentKeyOrder(base_attachment_key, b));

    // Field 3: EdgeKind ordinal.
    b = base_attachment_key;
    b.kind = 3;
    try expectEqual(std.math.Order.lt, pb.attachmentKeyOrder(base_attachment_key, b));

    // Fields 4-5: arrow ordinals.
    b = base_attachment_key;
    b.arrow_from = 4;
    try expectEqual(std.math.Order.lt, pb.attachmentKeyOrder(base_attachment_key, b));
    b = base_attachment_key;
    b.arrow_to = 1;
    try expectEqual(std.math.Order.gt, pb.attachmentKeyOrder(base_attachment_key, b));

    // Field 6: label, no-label first.
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
    // Every key field is raw_id bytes, a pinned u8 ordinal, the typed
    // endpoint side, or optional label bytes — numeric NodeId/EdgeId
    // handles cannot appear in any ordering (D-PORT clause 4; spine (vi)).
    try expectSemanticFieldsOnly(pb.EdgeKey);
    try expectSemanticFieldsOnly(pb.AttachmentKey);
}

test "keepOrigin selects exactly one origin's sets" {
    // The two helpers that let a producer REPLACE the population it owns
    // without taking another origin's records down with it.
    const sets = [_]pb.CoSet{
        .{ .origin = .fan_rail, .members = &.{ 0, 1 } },
        .{ .origin = .port_share, .members = &.{ 2, 3 } },
        .{ .origin = .selected_join, .members = &.{ 4, 5 } },
        .{ .origin = .port_share, .members = &.{ 6, 7 } },
    };
    const shares = try pb.keepOrigin(std.testing.allocator, &sets, .port_share);
    defer std.testing.allocator.free(shares);
    try expectEqual(@as(usize, 2), shares.len);
    try expect(pb.coMembers(shares, 2, 3));
    try expect(pb.coMembers(shares, 6, 7));
    try expect(!pb.coMembers(shares, 0, 1));

    const head = [_]pb.CoSet{.{ .origin = .selected_join, .members = &.{ 8, 9 } }};
    const joined = try pb.concatSets(std.testing.allocator, &head, shares);
    defer std.testing.allocator.free(joined);
    try expectEqual(@as(usize, 3), joined.len);
    try expectEqual(pb.CoOrigin.selected_join, joined[0].origin);
    try expect(pb.coMembers(joined, 8, 9));
    try expect(pb.coMembers(joined, 6, 7));

    // Degenerate arms: an empty side is returned as the other side verbatim.
    const no_joins = [_]pb.CoSet{.{ .origin = .fan_rail, .members = &.{ 0, 1 } }};
    try expectEqual(@as(usize, 0), (try pb.keepOrigin(std.testing.allocator, &no_joins, .selected_join)).len);
    try expectEqual(@as(usize, 1), (try pb.concatSets(std.testing.allocator, &head, &.{})).len);
}

test "a cell-scoped co-set answers only inside its licensed cells" {
    // The `.port_share` shape: the pair is one channel on the common approach
    // and foreign everywhere else. `at = null` asks the position-blind
    // question and no scope applies to it.
    const licensed = [_]pb.CoCell{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 3 } };
    const sets = [_]pb.CoSet{.{ .origin = .port_share, .members = &.{ 1, 2 }, .cells = &licensed }};
    try expect(pb.coMembersAt(&sets, 1, 2, .{ .x = 4, .y = 2 }));
    try expect(!pb.coMembersAt(&sets, 1, 2, .{ .x = 9, .y = 9 }));
    try expect(pb.coMembersAt(&sets, 1, 2, null));
    try expect(pb.coMembers(&sets, 1, 2));
    // An unscoped set is position-blind on the very same cell.
    const wide = [_]pb.CoSet{.{ .origin = .fan_rail, .members = &.{ 1, 2 } }};
    try expect(pb.coMembersAt(&wide, 1, 2, .{ .x = 9, .y = 9 }));
}
