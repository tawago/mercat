//! Unit tests for the static diagnostic registry in diagnostics.zig.
//! Aggregated into the test build from entry.zig's `test {}` block — NOT
//! imported by diagnostics.zig itself — so that module keeps the base/
//! no-deps tier's literal empty allowlist. Split out of ledger_test.zig
//! alongside the registry itself.

const std = @import("std");
const pb = @import("diagnostics.zig");

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// ---------------------------------------------------------------------------
// Static diagnostic registry (D-DISPOSITION items 3, 5, 6).
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
    .reach_bundle_split,
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
    .selected_bundle_invalidated,
    .bundle_select_invalidated,
};

const ro_tags = [_]pb.DiagnosticTag{
    .disp_terminal_fallback_engaged,
    .rail_member_style_mixed,
    .rail_member_invisible,
    .rail_pivot_side_arrow,
    .rail_duplicate_pair,
    .dual_membership_edges,
    .dual_membership_selected_both_sides,
    .permission_overlap_conflicts,
    .bundle_select_selected,
    .bundle_select_independent_not_selected,
    .bundle_select_independent_overlap_conflict,
    .bundle_select_independent_unsafe_component,
    .bundle_select_conflict_neither,
    .bundle_select_duplicate_key_blocked,
    .bundle_select_proposal_multiplicity_blocked,
    .bundle_select_cluster_skipped,
    .reach_skipped_clustered,
    .port_skipped_clustered,
    .bundle_permits_skipped_clustered,
    .edgeid_scope_clustered_skipped,
    .intentional_bundles,
    // Rail construction/refusal and bundle declaration diagnostics.
    .rail_deco_mixed,
    .rail_star_violation,
    .rail_closure_undeclared,
    .co_undeclared,
    .co_double_discharge,
};

test "registry partitions the 48 tags RF 5 / CI 17 / RO 26" {
    // Class assignments per D-DISPOSITION items 5-6, pinned tag by tag.
    for (rf_tags) |t| try expectEqual(pb.DispositionClass.render_fatal, pb.classOf(t));
    for (ci_tags) |t| try expectEqual(pb.DispositionClass.candidate_invalid, pb.classOf(t));
    for (ro_tags) |t| try expectEqual(pb.DispositionClass.report_only, pb.classOf(t));

    // Partition counts pinned to exactly 5 / 17 / 26 = 48, with the SI
    // class empty of members (D-DISPOSITION item 10).
    try expectEqual(@as(usize, 5), rf_tags.len);
    try expectEqual(@as(usize, 17), ci_tags.len);
    try expectEqual(@as(usize, 26), ro_tags.len);
    const fields = @typeInfo(pb.DiagnosticTag).@"enum".fields;
    try expectEqual(@as(usize, 48), fields.len);
    var counts = [_]usize{ 0, 0, 0, 0 };
    inline for (fields) |f| {
        counts[@intFromEnum(pb.classOf(@enumFromInt(f.value)))] += 1;
    }
    try expectEqual(@as(usize, 26), counts[@intFromEnum(pb.DispositionClass.report_only)]);
    try expectEqual(@as(usize, 17), counts[@intFromEnum(pb.DispositionClass.candidate_invalid)]);
    try expectEqual(@as(usize, 5), counts[@intFromEnum(pb.DispositionClass.render_fatal)]);
    try expectEqual(@as(usize, 0), counts[@intFromEnum(pb.DispositionClass.score_input)]);
    // Four classes verbatim (D-DISPOSITION item 1): score_input exists as
    // a class even though this slice registers no member.
    try expectEqual(@as(usize, 4), @typeInfo(pb.DispositionClass).@"enum".fields.len);
}

test "both invalidation tags are candidate-invalid (D-DISPOSITION item 5 row 4)" {
    // Item 5 row 4 names BOTH tags: `selected_bundle_invalidated` (D-IR) and
    // `bundle_select.invalidated` (D-JOIN-SELECT) are two registry entries,
    // each CI. Cross-pinned again by V-D-DISPOSITION-14 in Step 9.
    try expectEqual(pb.DispositionClass.candidate_invalid, pb.classOf(.selected_bundle_invalidated));
    try expectEqual(pb.DispositionClass.candidate_invalid, pb.classOf(.bundle_select_invalidated));
    try expectEqual(pb.DispositionClass.candidate_invalid, pb.classOf(pb.tagByName("selected_bundle_invalidated").?));
    try expectEqual(pb.DispositionClass.candidate_invalid, pb.classOf(pb.tagByName("bundle_select.invalidated").?));
}

test "tag names round-trip through tagByName" {
    inline for (@typeInfo(pb.DiagnosticTag).@"enum".fields) |f| {
        const tag: pb.DiagnosticTag = @enumFromInt(f.value);
        try expectEqual(tag, pb.tagByName(pb.tagName(tag)).?);
    }
    // The bundle_select family carries its record-verbatim dotted names.
    try expectEqualStrings("bundle_select.selected", pb.tagName(.bundle_select_selected));
    try expectEqualStrings("bundle_select.independent.not_selected", pb.tagName(.bundle_select_independent_not_selected));
    try expectEqualStrings("bundle_select.independent.overlap_conflict", pb.tagName(.bundle_select_independent_overlap_conflict));
    try expectEqualStrings("bundle_select.independent.unsafe_component", pb.tagName(.bundle_select_independent_unsafe_component));
    try expectEqualStrings("bundle_select.conflict_neither", pb.tagName(.bundle_select_conflict_neither));
    try expectEqualStrings("bundle_select.invalidated", pb.tagName(.bundle_select_invalidated));
    try expectEqualStrings("bundle_select.cluster_skipped", pb.tagName(.bundle_select_cluster_skipped));
    try expectEqualStrings("bundle_select.duplicate_key_blocked", pb.tagName(.bundle_select_duplicate_key_blocked));
    try expectEqualStrings("bundle_select.proposal_multiplicity_blocked", pb.tagName(.bundle_select_proposal_multiplicity_blocked));
    // Undotted tags spell exactly their field name.
    try expectEqualStrings("selected_bundle_invalidated", pb.tagName(.selected_bundle_invalidated));
    // Unregistered names resolve to null (item-4 backstop is the caller's).
    try expectEqual(@as(?pb.DiagnosticTag, null), pb.tagByName("not_a_registered_tag"));
    try expectEqual(@as(?pb.DiagnosticTag, null), pb.tagByName("bundle_select.selected_both"));
}

test "rail style and decoration exclusions are distinct report-only registry entries" {
    try expectEqual(pb.DiagnosticTag.rail_member_style_mixed, pb.tagByName("rail_member_style_mixed").?);
    try expectEqual(pb.DiagnosticTag.rail_deco_mixed, pb.tagByName("rail_deco_mixed").?);
    try std.testing.expect(pb.DiagnosticTag.rail_member_style_mixed != pb.DiagnosticTag.rail_deco_mixed);
    try expectEqual(pb.DispositionClass.report_only, pb.classOf(.rail_member_style_mixed));
    try expectEqual(pb.DispositionClass.report_only, pb.classOf(.rail_deco_mixed));
}
