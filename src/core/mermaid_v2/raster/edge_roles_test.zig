//! Tests for `edge_roles.zig`'s `mergeRole` precedence — the one question
//! that file answers. Discovered via edge_roles.zig's top-level
//! `test { _ = @import("edge_roles_test.zig"); }` block, per the
//! mermaid_v2/ test-file convention.
//!
//! The shared-run ROLE itself (which cells are a fan's rail) and the
//! fan-OUT mask strip are producer facts and live in `fan_roles_test.zig`.

const std = @import("std");
const lattice = @import("../lattice.zig");
const edge_roles = @import("edge_roles.zig");

const testing = std.testing;

test "mergeRole: a rail outranks a dropper, which outranks routing roles" {
    // Rails are the top tier: an arriving dropper never demotes one.
    try testing.expectEqual(
        lattice.EdgeRole.fan_out_rail,
        edge_roles.mergeRole(.fan_out_rail, .fan_out_dropper),
    );
    try testing.expectEqual(
        lattice.EdgeRole.fan_in_rail,
        edge_roles.mergeRole(.fan_in_dropper, .fan_in_rail),
    );
    // Droppers outrank the routing tier in both directions.
    try testing.expectEqual(
        lattice.EdgeRole.fan_out_dropper,
        edge_roles.mergeRole(.back_edge, .fan_out_dropper),
    );
    try testing.expectEqual(
        lattice.EdgeRole.fan_in_dropper,
        edge_roles.mergeRole(.fan_in_dropper, .cluster_internal),
    );
    // …and the routing tier outranks plain forward: this is the lift that
    // lets `fan_roles.markShared` recognise a fan family on a cell whose
    // first writer was an ordinary edge.
    try testing.expectEqual(
        lattice.EdgeRole.fan_out_dropper,
        edge_roles.mergeRole(.forward, .fan_out_dropper),
    );
}

test "mergeRole: a same-tier arrival never displaces the first writer" {
    // Ties keep the existing role, so the two members of one tier are not
    // silently interchangeable at a shared cell.
    try testing.expectEqual(
        lattice.EdgeRole.fan_out_rail,
        edge_roles.mergeRole(.fan_out_rail, .fan_in_rail),
    );
    try testing.expectEqual(
        lattice.EdgeRole.back_edge,
        edge_roles.mergeRole(.back_edge, .self_loop),
    );
    try testing.expectEqual(
        lattice.EdgeRole.forward,
        edge_roles.mergeRole(.forward, .forward),
    );
}
