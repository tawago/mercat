const std = @import("std");
const lattice = @import("../lattice.zig");
const edge_roles = @import("edge_roles.zig");

const testing = std.testing;

test "mergeRole: a rail outranks a dropper, which outranks routing roles" {
    try testing.expectEqual(
        lattice.EdgeRole.fan_out_rail,
        edge_roles.mergeRole(.fan_out_rail, .fan_out_dropper),
    );
    try testing.expectEqual(
        lattice.EdgeRole.fan_in_rail,
        edge_roles.mergeRole(.fan_in_dropper, .fan_in_rail),
    );
    try testing.expectEqual(
        lattice.EdgeRole.fan_out_dropper,
        edge_roles.mergeRole(.back_edge, .fan_out_dropper),
    );
    try testing.expectEqual(
        lattice.EdgeRole.fan_in_dropper,
        edge_roles.mergeRole(.fan_in_dropper, .cluster_internal),
    );
    try testing.expectEqual(
        lattice.EdgeRole.fan_out_dropper,
        edge_roles.mergeRole(.forward, .fan_out_dropper),
    );
}

test "mergeRole: a same-tier arrival never displaces the first writer" {
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
