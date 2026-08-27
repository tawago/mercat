//! Static diagnostic registry (D-DISPOSITION items 1, 3, 5, 6): the four
//! disposition classes, the closed tag enum, the record-verbatim name
//! table, and the exhaustive tag -> class map.
//!
//! Split out of base/ledger.zig, which sat exactly at the mermaid_v2
//! 500-line cap. ledger.zig re-exports every symbol here, so existing
//! `pb.DiagnosticTag` / `pb.tagName` / `pb.tagByName` / `pb.classOf`
//! call sites are source-compatible and type-identical.
//!
//! Pure data + pure functions; imports only std. Universally importable
//! (base/ no-deps tier) — enforced by tools/lint_imports.zig's base/ rule.
//! Tests live in diagnostics_test.zig, aggregated from entry.zig.

const std = @import("std");

/// The four disposition classes are exhaustive. The
/// `score_input` class is approved EMPTY of new members in this slice: no
/// registered tag maps to it.
pub const DispositionClass = enum {
    report_only,
    candidate_invalid,
    render_fatal,
    score_input,
};

/// The closed tag registry, declared in D-DISPOSITION item 3's own
/// enumeration order (owning record noted per block). Tags whose
/// record-verbatim names carry dots (`join_select.*`) spell them with
/// underscores here; `tagName` returns the verbatim form.
pub const DiagnosticTag = enum {
    // D-DISPOSITION (3)
    disp_terminal_fallback_engaged,
    disp_unregistered_diagnostic,
    ink_grammar_render_fatal,
    // D-POLICY (1)
    join_policy_not_joined,
    // D-TRUNK (4)
    /// Counts a construction group whose mixed stroke styles cause incompatible
    /// candidates to remain private; this does not describe shipped ink.
    rail_member_style_mixed,
    rail_member_invisible,
    rail_pivot_side_arrow,
    rail_duplicate_pair,
    // D-DUAL (3)
    dual_membership_edges,
    dual_membership_selected_both_sides,
    permission_overlap_conflicts,
    // D-JOIN-SELECT (9)
    join_select_selected,
    join_select_independent_not_selected,
    join_select_independent_overlap_conflict,
    join_select_independent_unsafe_component,
    join_select_conflict_neither,
    join_select_invalidated,
    join_select_cluster_skipped,
    join_select_duplicate_key_blocked,
    join_select_proposal_multiplicity_blocked,
    // D-JOIN (1)
    intentional_joins,
    // D-PORT (5)
    port_capacity_exceeded,
    port_key_collision,
    port_coalesced,
    port_departure_conflict,
    port_skipped_clustered,
    // D-REACH (12)
    reach_undeclared_pair,
    reach_missing_declared,
    reach_split_trace,
    reach_duplicate_trace,
    reach_join_split,
    reach_independent_joined,
    reach_cross_connected,
    reach_one_sided_adjacency,
    reach_mixed_stroke_junction,
    reach_unknown_continuation,
    reach_vector_raster_mismatch,
    reach_skipped_clustered,
    // D-IR (3)
    join_permits_skipped_clustered,
    realized_plan_missing,
    selected_join_invalidated,
    // D-EDGE-ID (2)
    edgeid_scope_clustered_skipped,
    edgeid_unqualified_local_lookup,
    // Rail-law refusals (3) and co-set declaration failures (2). The last
    // three are fired by the all-arrow-free shared-rail closure law
    // (base/rail_closure.zig) — the flat commitment in layout/join_commit.zig
    // and the clustered pass in layout/fan_rail_law.zig — and reach stderr on
    // the `MERCAT_INTEGRITY=1` line.
    /// Counts a construction group whose mixed pivot-end arrow decorations
    /// cause incompatible candidates to remain private. It does not describe a
    /// defect in the final private rendering.
    rail_deco_mixed,
    /// Fires when a rail is refused because its members do not form a star
    /// around one shared pivot — the star-only rail law admits no union of
    /// two or more pivots.
    rail_star_violation,
    /// Fires once per rail the closure law refuses: an all-arrow-free rail
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

/// Record-verbatim tag string (dotted for the `join_select.*` family).
/// guarded-by: diagnostics_test.zig "tag names round-trip through tagByName"
pub fn tagName(tag: DiagnosticTag) []const u8 {
    return switch (tag) {
        .join_select_selected => "join_select.selected",
        .join_select_independent_not_selected => "join_select.independent.not_selected",
        .join_select_independent_overlap_conflict => "join_select.independent.overlap_conflict",
        .join_select_independent_unsafe_component => "join_select.independent.unsafe_component",
        .join_select_conflict_neither => "join_select.conflict_neither",
        .join_select_invalidated => "join_select.invalidated",
        .join_select_cluster_skipped => "join_select.cluster_skipped",
        .join_select_duplicate_key_blocked => "join_select.duplicate_key_blocked",
        .join_select_proposal_multiplicity_blocked => "join_select.proposal_multiplicity_blocked",
        inline else => |t| @tagName(t),
    };
}

/// Registry lookup by record-verbatim name. Null means UNREGISTERED — the
/// disposition for firing such a tag is `disp_unregistered_diagnostic`
/// (render-fatal backstop, D-DISPOSITION item 4).
pub fn tagByName(name: []const u8) ?DiagnosticTag {
    inline for (@typeInfo(DiagnosticTag).@"enum".fields) |f| {
        const tag: DiagnosticTag = @enumFromInt(f.value);
        if (std.mem.eql(u8, tagName(tag), name)) return tag;
    }
    return null;
}

/// The static tag → class registry: every tag by explicit name, no
/// wildcard, no prefix, no else branch (D-DISPOSITION items 3, 5, 6).
/// guarded-by: diagnostics_test.zig "registry partitions the 48 tags RF 5 / CI 17 / RO 26"
/// guarded-by: diagnostics_test.zig "both invalidation tags are candidate-invalid (D-DISPOSITION item 5 row 4)"
pub fn classOf(tag: DiagnosticTag) DispositionClass {
    return switch (tag) {
        // RF (5): D-DISPOSITION item 4 + item 9(e) backstops; item 5 row 1;
        // item 6 rows for the two semantic/defensive fatals.
        .disp_unregistered_diagnostic,
        .ink_grammar_render_fatal,
        .join_policy_not_joined,
        .port_key_collision,
        .edgeid_unqualified_local_lookup,
        => .render_fatal,

        // CI (17): the 11 substantive reach_* oracle failures (item 6
        // row 4), the per-candidate port breaches (item 6 rows 5-6),
        // realized_plan_missing (item 6 row 7), and BOTH invalidated-
        // selected-join tags (item 5 row 4 names the pair).
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
        => .candidate_invalid,

        // RO (26): normal-operation inventory/style/safety-filter outcomes
        // (item 6 rows 1-2), the five clustered scope-gate skips (item 6
        // row 3), the terminal-fallback count (item 9(e)), the
        // count-surfaced intentional_joins, and the five registered-but-
        // unfired rail-law / co-set tags — a refusal there is discharged by
        // unfusing onto separate lanes, never by invalidating the candidate.
        .disp_terminal_fallback_engaged,
        .rail_member_style_mixed,
        .rail_member_invisible,
        .rail_pivot_side_arrow,
        .rail_duplicate_pair,
        .dual_membership_edges,
        .dual_membership_selected_both_sides,
        .permission_overlap_conflicts,
        .join_select_selected,
        .join_select_independent_not_selected,
        .join_select_independent_overlap_conflict,
        .join_select_independent_unsafe_component,
        .join_select_conflict_neither,
        .join_select_cluster_skipped,
        .join_select_duplicate_key_blocked,
        .join_select_proposal_multiplicity_blocked,
        .intentional_joins,
        .reach_skipped_clustered,
        .join_permits_skipped_clustered,
        .port_skipped_clustered,
        .edgeid_scope_clustered_skipped,
        .rail_deco_mixed,
        .rail_star_violation,
        .rail_closure_undeclared,
        .co_undeclared,
        .co_double_discharge,
        => .report_only,
    };
}
