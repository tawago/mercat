const std = @import("std");
const lattice = @import("../lattice.zig");

pub fn mergeRole(existing: lattice.EdgeRole, incoming: lattice.EdgeRole) lattice.EdgeRole {
    if (priority(incoming) > priority(existing)) return incoming;
    return existing;
}

fn priority(r: lattice.EdgeRole) u8 {
    return switch (r) {
        .fan_out_rail, .fan_in_rail => 3,
        .fan_out_dropper, .fan_in_dropper => 2,
        .back_edge, .self_loop, .cluster_internal => 1,
        .forward, .member_stroke => 0,
    };
}

test {
    _ = @import("edge_roles_test.zig");
}
