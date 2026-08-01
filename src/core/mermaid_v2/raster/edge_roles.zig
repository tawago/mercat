//! Shared-run role-merge precedence for `raster/edges.zig`: the rule that
//! decides which role survives when two writers claim one cell. Split out
//! to keep `edges.zig` under the 500-line cap.
//!
//! It answers only the MERGE question. Which cells are a fan's shared run,
//! and which arms such a cell keeps, are producer facts stamped by
//! `raster/fan_roles.zig` — never re-derived from the finished grid.
//!
//! `sketch.EdgeRole` and `lattice.EdgeRole` are the same type
//! (`prim.EdgeRole`), so no cross-layer mapping is needed here.
//!
//! Allowed imports: `std`, `lattice.zig`
//! (enforced by `tools/lint_imports.zig`).

const std = @import("std");
const lattice = @import("../lattice.zig");

/// Choose the surviving role when a cell already has a role and a new
/// writer arrives. Precedence (highest first):
///   fan_out_rail, fan_in_rail  > fan_out_dropper, fan_in_dropper
///   > back_edge, self_loop, cluster_internal  > forward.
/// Ties: prefer the existing role (first-writer-wins for same tier).
pub fn mergeRole(existing: lattice.EdgeRole, incoming: lattice.EdgeRole) lattice.EdgeRole {
    if (priority(incoming) > priority(existing)) return incoming;
    return existing;
}

fn priority(r: lattice.EdgeRole) u8 {
    return switch (r) {
        .fan_out_rail, .fan_in_rail => 3,
        .fan_out_dropper, .fan_in_dropper => 2,
        .back_edge, .self_loop, .cluster_internal => 1,
        .forward => 0,
    };
}

test {
    _ = @import("edge_roles_test.zig");
}
