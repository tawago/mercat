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
    try expectEqual(@as(usize, 0), plan.mesh_unions.len);
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

// ---------------------------------------------------------------------------
// Static 43-tag registry (D-DISPOSITION items 3, 5, 6).
// ---------------------------------------------------------------------------

const rf_tags = [_]pb.DiagnosticTag{
    .join_policy_not_joined,
    .port_key_collision,
    .edgeid_unqualified_local_lookup,
    .disp_unregistered_diagnostic,
    .ink_grammar_render_fatal,
};

const ci_tags = [_]pb.DiagnosticTag{
    .reach_undeclared_pair,
    .reach_missing_declared,
    .reach_split_trace,
    .reach_duplicate_trace,
    .reach_join_split,
    .reach_independent_joined,
    .reach_cross_connected,
    .reach_one_sided_adjacency,
    .reach_mixed_stroke_junction,
    .reach_unknown_continuation,
    .reach_vector_raster_mismatch,
    .port_coalesced,
    .port_departure_conflict,
    .port_capacity_exceeded,
    .realized_plan_missing,
    .selected_join_invalidated,
    .join_select_invalidated,
};

const ro_tags = [_]pb.DiagnosticTag{
    .disp_terminal_fallback_engaged,
    .trunk_member_style_mixed,
    .trunk_member_invisible,
    .trunk_pivot_side_arrow,
    .trunk_duplicate_pair,
    .dual_membership_edges,
    .dual_membership_selected_both_sides,
    .permission_overlap_conflicts,
    .join_select_selected,
    .join_select_independent_not_selected,
    .join_select_independent_overlap_conflict,
    .join_select_independent_unsafe_component,
    .join_select_conflict_neither,
    .join_select_duplicate_key_blocked,
    .join_select_proposal_multiplicity_blocked,
    .join_select_cluster_skipped,
    .reach_skipped_clustered,
    .port_skipped_clustered,
    .join_permits_skipped_clustered,
    .edgeid_scope_clustered_skipped,
    .intentional_joins,
};

test "registry partitions the 43 tags RF 5 / CI 17 / RO 21" {
    // Class assignments per D-DISPOSITION items 5-6, pinned tag by tag.
    for (rf_tags) |t| try expectEqual(pb.DispositionClass.render_fatal, pb.classOf(t));
    for (ci_tags) |t| try expectEqual(pb.DispositionClass.candidate_invalid, pb.classOf(t));
    for (ro_tags) |t| try expectEqual(pb.DispositionClass.report_only, pb.classOf(t));

    // Partition counts pinned to exactly 5 / 17 / 21 = 43, with the SI
    // class empty of members (D-DISPOSITION item 10).
    try expectEqual(@as(usize, 5), rf_tags.len);
    try expectEqual(@as(usize, 17), ci_tags.len);
    try expectEqual(@as(usize, 21), ro_tags.len);
    const fields = @typeInfo(pb.DiagnosticTag).@"enum".fields;
    try expectEqual(@as(usize, 43), fields.len);
    var counts = [_]usize{ 0, 0, 0, 0 };
    inline for (fields) |f| {
        counts[@intFromEnum(pb.classOf(@enumFromInt(f.value)))] += 1;
    }
    try expectEqual(@as(usize, 21), counts[@intFromEnum(pb.DispositionClass.report_only)]);
    try expectEqual(@as(usize, 17), counts[@intFromEnum(pb.DispositionClass.candidate_invalid)]);
    try expectEqual(@as(usize, 5), counts[@intFromEnum(pb.DispositionClass.render_fatal)]);
    try expectEqual(@as(usize, 0), counts[@intFromEnum(pb.DispositionClass.score_input)]);
    // Four classes verbatim (D-DISPOSITION item 1): score_input exists as
    // a class even though this slice registers no member.
    try expectEqual(@as(usize, 4), @typeInfo(pb.DispositionClass).@"enum".fields.len);
}

test "both invalidation tags are candidate-invalid (D-DISPOSITION item 5 row 4)" {
    // Item 5 row 4 names BOTH tags: `selected_join_invalidated` (D-IR) and
    // `join_select.invalidated` (D-JOIN-SELECT) are two registry entries,
    // each CI. Cross-pinned again by V-D-DISPOSITION-14 in Step 9.
    try expectEqual(pb.DispositionClass.candidate_invalid, pb.classOf(.selected_join_invalidated));
    try expectEqual(pb.DispositionClass.candidate_invalid, pb.classOf(.join_select_invalidated));
    try expectEqual(pb.DispositionClass.candidate_invalid, pb.classOf(pb.tagByName("selected_join_invalidated").?));
    try expectEqual(pb.DispositionClass.candidate_invalid, pb.classOf(pb.tagByName("join_select.invalidated").?));
}

test "tag names round-trip through tagByName" {
    inline for (@typeInfo(pb.DiagnosticTag).@"enum".fields) |f| {
        const tag: pb.DiagnosticTag = @enumFromInt(f.value);
        try expectEqual(tag, pb.tagByName(pb.tagName(tag)).?);
    }
    // The join_select family carries its record-verbatim dotted names.
    try expectEqualStrings("join_select.selected", pb.tagName(.join_select_selected));
    try expectEqualStrings("join_select.independent.not_selected", pb.tagName(.join_select_independent_not_selected));
    try expectEqualStrings("join_select.independent.overlap_conflict", pb.tagName(.join_select_independent_overlap_conflict));
    try expectEqualStrings("join_select.independent.unsafe_component", pb.tagName(.join_select_independent_unsafe_component));
    try expectEqualStrings("join_select.conflict_neither", pb.tagName(.join_select_conflict_neither));
    try expectEqualStrings("join_select.invalidated", pb.tagName(.join_select_invalidated));
    try expectEqualStrings("join_select.cluster_skipped", pb.tagName(.join_select_cluster_skipped));
    try expectEqualStrings("join_select.duplicate_key_blocked", pb.tagName(.join_select_duplicate_key_blocked));
    try expectEqualStrings("join_select.proposal_multiplicity_blocked", pb.tagName(.join_select_proposal_multiplicity_blocked));
    // Undotted tags spell exactly their field name.
    try expectEqualStrings("selected_join_invalidated", pb.tagName(.selected_join_invalidated));
    // Unregistered names resolve to null (item-4 backstop is the caller's).
    try expectEqual(@as(?pb.DiagnosticTag, null), pb.tagByName("not_a_registered_tag"));
    try expectEqual(@as(?pb.DiagnosticTag, null), pb.tagByName("join_select.selected_both"));
}
