const std = @import("std");

test {
    _ = @import("prng.zig");
    _ = @import("gen.zig");
    _ = @import("runner.zig");
    _ = @import("sketch_props.zig");
    std.testing.refAllDecls(@This());
}
