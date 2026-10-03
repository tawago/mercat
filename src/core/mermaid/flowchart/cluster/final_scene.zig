const sketch = @import("../sketch.zig");
const split_mod = @import("split.zig");

pub const Final = struct {
    sr: split_mod.SplitResult,
    outer: sketch.Sketch,
    outer_base: sketch.EdgeId,
    bridge_base: sketch.EdgeId,
    paths: []const sketch.EdgePath,
    bridges: []const sketch.EdgePath,
    rails: []const sketch.Rail,
    placements: []const sketch.NodePlacement,
};
