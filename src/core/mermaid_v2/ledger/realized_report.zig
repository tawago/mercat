//! realized_report.zig — the planner's report-only output vocabulary: the
//! frozen selection-order clause enum, the per-group verdict record, and the
//! Report/Result envelopes `realize` returns.
//!
//! Split out of realized.zig, which sat at the mermaid_v2 500-line cap.
//! realized.zig re-exports every symbol here, so existing
//! `realized.GroupClause` / `realized.Report` / `realized.Result` call sites
//! are source-compatible and type-identical.
//!
//! Pure data; imports base/ledger only (for the id + tag handles).
//! Allowed imports (tools/lint_imports.zig): std, prim, base/ledger.

const std = @import("std");
const pb = @import("../base/ledger.zig");

/// Which step of the frozen selection order decided a group; the first
/// failing step names the tag (D-JOIN-SELECT item 3). Report-only.
pub const GroupClause = enum {
    selected,
    duplicate_key,
    unresolved_member,
    incomplete,
    overlap,
    style,
    no_proposal,
    multiplicity,
};

pub const GroupVerdict = struct {
    group: pb.CandidateBundleId,
    clause: GroupClause,
    /// First-fail naming tag (bundle_select.* family, pinned registry).
    tag: pb.DiagnosticTag,
    /// D-TRUNK first-failing sub-clause tag when clause == .style
    /// ((a) invisible → (b) kind mixed → (c) pivot-side arrow mixed).
    rail_detail: ?pb.DiagnosticTag = null,
    /// Report-only D-TRUNK duplicate-(from,to) inventory; fires regardless
    /// of the first-fail clause (V-D-TRUNK-06 pairs it with duplicate_key).
    duplicate_pair: bool = false,
    /// Raw rail-proposal count, identical-key duplicates included —
    /// item 3 reads this count and no other proposal property.
    proposal_count: u32 = 0,
};

/// Report-only planner outputs that do not ride the RealizedBundles
/// envelope (D-JOIN-SELECT item 6: never score input).
pub const Report = struct {
    verdicts: []const GroupVerdict = &.{},
    /// Canonical proposal records; identical-key entries collapsed into
    /// one multiplicity-counted entry (item 1d). Parallel `multiplicity`.
    proposals: []const pb.BundleProposal = &.{},
    multiplicity: []const u32 = &.{},
    dual_membership_edges: u32 = 0,
    permission_overlap_conflicts: u32 = 0,
    /// Discharged edges that ALSO own private geometry in this candidate
    /// (`co_double_discharge`). An edge discharged by a rail's crossbar has
    /// no second rendering, so a non-zero count means the withholding leaked.
    /// @guarded-by: realized_test.zig "a discharged edge that still owns an EdgePath counts as a double discharge"
    co_double_discharge: u32 = 0,
    /// Candidate off the flat identity path (D-JOIN-SELECT item 10):
    /// nothing was planned; the plan is the empty `.{}`.
    skipped_clustered: bool = false,
};

pub const Result = struct {
    plan: pb.RealizedBundles = .{},
    report: Report = .{},
};

/// First-fail naming tag per D-JOIN-SELECT items 3/7 (the pinned
/// bundle_select.* registry family).
pub fn tagFor(clause: GroupClause) pb.DiagnosticTag {
    return switch (clause) {
        .selected => .bundle_select_selected,
        .duplicate_key => .bundle_select_duplicate_key_blocked,
        .overlap => .bundle_select_conflict_neither,
        .multiplicity => .bundle_select_proposal_multiplicity_blocked,
        .unresolved_member, .incomplete, .style, .no_proposal => .bundle_select_independent_not_selected,
    };
}

test {
    std.testing.refAllDecls(@This());
}
