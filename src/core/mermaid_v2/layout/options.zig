const prim = @import("prim");
const ledger = @import("../base/ledger.zig");
const sizing = @import("sizing.zig");

pub const FixedSize = sizing.FixedSize;

pub const LayoutOptions = struct {
    bundle_permits: ?*const ledger.BundlePermits = null,
    max_width: u32 = 120,
    h_spacing: u32 = 4,
    v_spacing: u32 = 2,
    node_padding: u32 = 1,
    rung: u8 = 0,
    fixed_sizes: []const FixedSize = &.{},
    departures: []const ledger.NodeId = &.{},
    max_label_width: ?u32 = null,
    is_direction_rotated: bool = false,
    justify: Justify = .center,
    spacing_scale: u8 = 0,
    bridge_build: prim.BridgeBuild = .plain,
};

pub const Justify = enum { center, flush_left };
