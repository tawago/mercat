//! Static diagnostic registry (D-DISPOSITION items 1, 3): the closed tag
//! enum and the record-verbatim name table.
//!
//! Split out of base/ledger.zig, which sat exactly at the mermaid_v2
//! 500-line cap. ledger.zig re-exports every symbol here, so existing
//! `pb.DiagnosticTag` / `pb.tagName` call sites are source-compatible and
//! type-identical.
//!
//! Pure data + pure functions; imports only std. Universally importable
//! (base/ no-deps tier) — enforced by tools/lint_imports.zig's base/ rule.
//! Tests live in diagnostics_test.zig, aggregated from entry.zig.

const std = @import("std");

/// The closed tag registry, declared in D-DISPOSITION item 3's own
/// enumeration order (owning record noted per block). Tags whose
/// record-verbatim names carry dots (`bundle_select.*`) spell them with
/// underscores here; `tagName` returns the verbatim form.
pub const DiagnosticTag = enum {
    disp_terminal_fallback_engaged,
    disp_unregistered_diagnostic,
    ink_grammar_render_fatal,
    join_policy_not_joined,
    /// Counts a construction group whose mixed stroke styles cause incompatible
    /// candidates to remain private; this does not describe shipped ink.
    rail_member_style_mixed,
    rail_member_invisible,
    rail_pivot_side_arrow,
    rail_duplicate_pair,
    dual_membership_edges,
    /// Retired with the one-bundle-per-edge rule (confluence theory,
    /// "Membership at both ends"): an edge may be selected at both ends
    /// and two groups sharing a member is no conflict. Kept for the pinned
    /// registry; structurally zero.
    dual_membership_selected_both_sides,
    permission_overlap_conflicts,
    bundle_select_selected,
    bundle_select_independent_not_selected,
    bundle_select_independent_overlap_conflict,
    bundle_select_independent_unsafe_component,
    bundle_select_conflict_neither,
    bundle_select_invalidated,
    bundle_select_cluster_skipped,
    bundle_select_duplicate_key_blocked,
    bundle_select_proposal_multiplicity_blocked,
    intentional_bundles,
    port_capacity_exceeded,
    port_key_collision,
    port_coalesced,
    port_departure_conflict,
    port_skipped_clustered,
    reach_undeclared_pair,
    reach_missing_declared,
    reach_split_trace,
    reach_duplicate_trace,
    reach_bundle_split,
    reach_independent_joined,
    reach_cross_connected,
    reach_one_sided_adjacency,
    reach_mixed_stroke_junction,
    reach_unknown_continuation,
    reach_vector_raster_mismatch,
    reach_skipped_clustered,
    bundle_permits_skipped_clustered,
    realized_plan_missing,
    selected_bundle_invalidated,
    edgeid_scope_clustered_skipped,
    edgeid_unqualified_local_lookup,
    /// Counts a construction group whose mixed pivot-end arrow decorations
    /// cause incompatible candidates to remain private. It does not describe a
    /// defect in the final private rendering.
    rail_deco_mixed,
    /// Fires when a rail is refused because its members do not form a star
    /// around one shared pivot — the star licence admits no union of
    /// two or more pivots.
    rail_star_violation,
    /// Fires once per rail the closure licence refuses: an all-arrow-free rail
    /// whose crossbar would assert a leaf pair the graph never declared, so
    /// its membership is not closed over the ink the rail actually owns.
    /// Counted for a partial salvage too — the rail as proposed was refused.
    rail_closure_undeclared,
    /// Fires per LEAF PAIR of a proposed rail with no usable declaration
    /// backing it: undeclared, or declared with an arrowhead, a label, or the
    /// wrong stroke class. The inventory behind one `rail_closure_undeclared`.
    co_undeclared,
    /// Fires when an edge a rail discharged ALSO owns private geometry, so one
    /// relation is rendered twice — the withholding leaked. Must stay zero.
    co_double_discharge,
};

/// Record-verbatim tag string (dotted for the `bundle_select.*` family).
/// @guarded-by: diagnostics_test.zig "bundle_select tags spell their record-verbatim dotted names"
pub fn tagName(tag: DiagnosticTag) []const u8 {
    return switch (tag) {
        .bundle_select_selected => "bundle_select.selected",
        .bundle_select_independent_not_selected => "bundle_select.independent.not_selected",
        .bundle_select_independent_overlap_conflict => "bundle_select.independent.overlap_conflict",
        .bundle_select_independent_unsafe_component => "bundle_select.independent.unsafe_component",
        .bundle_select_conflict_neither => "bundle_select.conflict_neither",
        .bundle_select_invalidated => "bundle_select.invalidated",
        .bundle_select_cluster_skipped => "bundle_select.cluster_skipped",
        .bundle_select_duplicate_key_blocked => "bundle_select.duplicate_key_blocked",
        .bundle_select_proposal_multiplicity_blocked => "bundle_select.proposal_multiplicity_blocked",
        inline else => |t| @tagName(t),
    };
}
