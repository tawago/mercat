//! Aggregator for the property-test harness. Pulled in by `zig build test`
//! once build.zig wires `tests/property/all.zig` as a test root.
const std = @import("std");

test {
    _ = @import("prng.zig");
    _ = @import("gen.zig");
    _ = @import("runner.zig");
    _ = @import("sketch_props.zig");
    // parse_baseline.zig lives outside this module — wired as its own test step.
    // parse_props.zig — property tests against the parser — comes next.
    std.testing.refAllDecls(@This());
}
