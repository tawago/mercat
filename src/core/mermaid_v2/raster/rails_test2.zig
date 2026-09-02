//! Split from rails_test.zig at the 500-line cap (tools/lint/line_caps.zig).
//! Chained via rails_test.zig's own `test {}` block.

const std = @import("std");
const testing = std.testing;
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const raster = @import("../raster.zig");
const rails_test = @import("rails_test.zig");

test "a rail reports licensed or foreign without changing bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const members = [_]u32{ 0, 1, 2 };
    const Bundle = @typeInfo(@TypeOf((sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    }).bundle_sets)).pointer.child;
    const mates = [_]Bundle{.{ .origin = .fan_rail, .bundle = 1, .members = &members }};
    var baseline: ?[]const lattice.Cell = null;

    for ([2]lattice.CarrierKind{ .merged_foreign, .merged_licensed }) |want| {
        var nodes: [4]sketch.NodePlacement = undefined;
        var taps: [3]sketch.Tap = undefined;
        var stem: [2]sketch.Point = undefined;
        var rails: [1]sketch.Rail = undefined;
        var s = rails_test.fanSketch(&nodes, &taps, &stem, &rails);
        if (want == .merged_licensed) s.bundle_sets = &mates;
        s.bundle_stamp_state = .complete;

        const r = try raster.rasterize(a, s, .bridge);
        if (baseline) |cells| try testing.expectEqualSlices(lattice.Cell, cells, r.lattice.cells) else baseline = r.lattice.cells;
        const records = try rails_test.recordsAt(a, r.lattice, .carrier, 12, 5);
        try testing.expectEqual(@as(usize, 1), records.len);
        try testing.expectEqual(@as(u32, 1), records[0].value);
        try testing.expectEqual(@intFromEnum(want), records[0].detail);
    }
}

test "every incomplete rail stamp files untested without changing bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const members = [_]u32{ 0, 1, 2 };
    const Bundle = @typeInfo(@TypeOf((sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    }).bundle_sets)).pointer.child;
    const roster = [_]Bundle{.{ .origin = .fan_rail, .bundle = 1, .members = &members }};
    var baseline: ?[]const lattice.Cell = null;

    for ([_]sketch.BundleStampState{ .unattempted, .complete, .out_of_memory, .rail_invariant }) |state| {
        var nodes: [4]sketch.NodePlacement = undefined;
        var taps: [3]sketch.Tap = undefined;
        var stem: [2]sketch.Point = undefined;
        var rails: [1]sketch.Rail = undefined;
        var s = rails_test.fanSketch(&nodes, &taps, &stem, &rails);
        s.bundle_sets = &roster;
        s.bundle_stamp_state = state;

        const r = try raster.rasterize(a, s, .bridge);
        if (baseline) |cells| try testing.expectEqualSlices(lattice.Cell, cells, r.lattice.cells) else baseline = r.lattice.cells;
        const records = try rails_test.recordsAt(a, r.lattice, .carrier, 12, 5);
        try testing.expectEqual(@as(usize, 1), records.len);
        try testing.expectEqual(
            @intFromEnum(if (state == .complete) lattice.CarrierKind.merged_licensed else .merged_untested),
            records[0].detail,
        );
    }
}

test "a rail off the roster reads every merge as foreign" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Bundle = @typeInfo(@TypeOf((sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    }).bundle_sets)).pointer.child;
    const unrelated_members = [_]u32{ 90, 91 };
    const unrelated = [_]Bundle{.{ .origin = .fan_rail, .bundle = 1, .members = &unrelated_members }};

    var nodes: [4]sketch.NodePlacement = undefined;
    var taps: [3]sketch.Tap = undefined;
    var stem: [2]sketch.Point = undefined;
    var rails: [1]sketch.Rail = undefined;
    var s = rails_test.fanSketch(&nodes, &taps, &stem, &rails);
    s.bundle_sets = &unrelated;
    rails[0].bundle = 2;
    s.bundle_stamp_state = .complete;

    const r = try raster.rasterize(a, s, .bridge);
    const at_junction = try rails_test.recordsAt(a, r.lattice, .carrier, 12, 5);
    try testing.expectEqual(@as(usize, 1), at_junction.len);
    try testing.expectEqual(@intFromEnum(lattice.CarrierKind.merged_foreign), at_junction[0].detail);
}
