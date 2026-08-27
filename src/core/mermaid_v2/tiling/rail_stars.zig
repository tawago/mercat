//! Lattice-only semantic rail-star tier.
//!
//! The input is exactly `Lattice.rail_claims`. No Sketch or SemGraph can
//! alter the result. Each claim is checked once with `ledger.checkRailClaim`;
//! the checker result is then projected into four independently attributable
//! families. A claim increments at most once in each family.
//!
//! Exact equations and ownership:
//!   `n_rail_claims == len(Lattice.rail_claims)`
//!   `n_rail_claim_members == sum(claim.members.len)`
//!   `c_rail_star_valid == count(!bnd_s && !decoration && !style && !record)`
//!   `d_rail_star_violation == count(bnd_s)`
//!   `d_rail_deco_mixed == count(decoration)`
//!   `d_rail_member_style_mixed == count(style)`
//!   `u_rail_claim_unresolved + u_rail_claim_record_invalid == count(record)`
//! The two record buckets are disjoint: unresolved wins; the latter owns
//! invalid identity, arity, or stale caches only when resolution is complete.
//! Families may overlap because one claim may independently violate BND-S,
//! decoration, style, and its record envelope. Such overlap is attribution,
//! not double-counting within a family.
//!
//! Diagnostic registry mapping (the registry remains `base/diagnostics.zig`):
//! BND-S -> `rail_star_violation`; decoration -> `rail_deco_mixed`; style ->
//! `rail_member_style_mixed`. This report-only tier files counters, not a
//! second diagnostic registry, and never changes layout or lattice cells.

const ledger = @import("../base/ledger.zig");
const lattice = @import("../lattice.zig");
const counts = @import("counts.zig");

/// Audit every final claim, including on a zero-sized lattice.
pub fn check(lat: *const lattice.Lattice, c: *counts.Counts) void {
    c.n_rail_claims = @intCast(lat.rail_claims.len);
    if (lat.rail_claims.len == 0) {
        c.u_rail_claim_population_absent += 1;
        return;
    }

    for (lat.rail_claims) |claim| {
        c.n_rail_claim_members += @intCast(claim.members.len);
        const result = ledger.checkRailClaim(claim);
        const failed = result.partition();
        if (!failed.any()) c.c_rail_star_valid += 1;
        if (failed.bnd_s) c.d_rail_star_violation += 1;
        if (failed.decoration) c.d_rail_deco_mixed += 1;
        if (failed.style) c.d_rail_member_style_mixed += 1;
        if (failed.record) {
            if (result.record.unresolved)
                c.u_rail_claim_unresolved += 1
            else
                c.u_rail_claim_record_invalid += 1;
        }
    }
}

test {
    _ = @import("rail_stars_test.zig");
}
