//! Unit tests for the static diagnostic registry in diagnostics.zig.
//! Aggregated into the test build from entry.zig's `test {}` block — NOT
//! imported by diagnostics.zig itself — so that module keeps the base/
//! no-deps tier's literal empty allowlist. Split out of ledger_test.zig
//! alongside the registry itself.

const std = @import("std");
const pb = @import("diagnostics.zig");

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "the registry holds 48 tags" {
    try expectEqual(@as(usize, 48), @typeInfo(pb.DiagnosticTag).@"enum".fields.len);
}

test "bundle_select tags spell their record-verbatim dotted names" {
    try expectEqualStrings("bundle_select.selected", pb.tagName(.bundle_select_selected));
    try expectEqualStrings("bundle_select.independent.not_selected", pb.tagName(.bundle_select_independent_not_selected));
    try expectEqualStrings("bundle_select.independent.overlap_conflict", pb.tagName(.bundle_select_independent_overlap_conflict));
    try expectEqualStrings("bundle_select.independent.unsafe_component", pb.tagName(.bundle_select_independent_unsafe_component));
    try expectEqualStrings("bundle_select.conflict_neither", pb.tagName(.bundle_select_conflict_neither));
    try expectEqualStrings("bundle_select.invalidated", pb.tagName(.bundle_select_invalidated));
    try expectEqualStrings("bundle_select.cluster_skipped", pb.tagName(.bundle_select_cluster_skipped));
    try expectEqualStrings("bundle_select.duplicate_key_blocked", pb.tagName(.bundle_select_duplicate_key_blocked));
    try expectEqualStrings("bundle_select.proposal_multiplicity_blocked", pb.tagName(.bundle_select_proposal_multiplicity_blocked));
    try expectEqualStrings("selected_bundle_invalidated", pb.tagName(.selected_bundle_invalidated));
}

test "rail style and decoration exclusions are distinct registry entries" {
    try expectEqualStrings("rail_member_style_mixed", pb.tagName(.rail_member_style_mixed));
    try expectEqualStrings("rail_deco_mixed", pb.tagName(.rail_deco_mixed));
    try std.testing.expect(pb.DiagnosticTag.rail_member_style_mixed != pb.DiagnosticTag.rail_deco_mixed);
}
