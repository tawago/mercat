//! Split from busbars_test.zig at the 500-line cap (tools/lint/line_caps.zig).
//! Chained via busbars_test.zig's own `test {}` block.

const std = @import("std");
const testing = std.testing;
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const raster = @import("../raster.zig");
const busbars_test = @import("busbars_test.zig");

test "a rail reports licensed or foreign without changing bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const members = [_]u32{ 0, 1, 2 };
    const CoSet = @typeInfo(@TypeOf((sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    }).co_sets)).pointer.child;
    const mates = [_]CoSet{.{ .origin = .fan_rail, .channel = 1, .members = &members }};
    var baseline: ?[]const lattice.Cell = null;

    for ([2]lattice.CarrierKind{ .merged_foreign, .merged_licensed }) |want| {
        var nodes: [4]sketch.NodePlacement = undefined;
        var taps: [3]sketch.Tap = undefined;
        var stem: [2]sketch.Point = undefined;
        var busbars: [1]sketch.Rail = undefined;
        var s = busbars_test.fanSketch(&nodes, &taps, &stem, &busbars);
        if (want == .merged_licensed) s.co_sets = &mates;
        s.channel_stamp_state = .complete;

        const r = try raster.rasterize(a, s, .bridge);
        if (baseline) |cells| try testing.expectEqualSlices(lattice.Cell, cells, r.lattice.cells) else baseline = r.lattice.cells;
        const records = try busbars_test.recordsAt(a, r.lattice, .carrier, 12, 5);
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
    const CoSet = @typeInfo(@TypeOf((sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    }).co_sets)).pointer.child;
    const roster = [_]CoSet{.{ .origin = .fan_rail, .channel = 1, .members = &members }};
    var baseline: ?[]const lattice.Cell = null;

    for ([_]sketch.ChannelStampState{ .unattempted, .complete, .out_of_memory, .rail_invariant }) |state| {
        var nodes: [4]sketch.NodePlacement = undefined;
        var taps: [3]sketch.Tap = undefined;
        var stem: [2]sketch.Point = undefined;
        var busbars: [1]sketch.Rail = undefined;
        var s = busbars_test.fanSketch(&nodes, &taps, &stem, &busbars);
        s.co_sets = &roster;
        s.channel_stamp_state = state;

        const r = try raster.rasterize(a, s, .bridge);
        if (baseline) |cells| try testing.expectEqualSlices(lattice.Cell, cells, r.lattice.cells) else baseline = r.lattice.cells;
        const records = try busbars_test.recordsAt(a, r.lattice, .carrier, 12, 5);
        try testing.expectEqual(@as(usize, 1), records.len);
        try testing.expectEqual(
            @intFromEnum(if (state == .complete) lattice.CarrierKind.merged_licensed else .merged_untested),
            records[0].detail,
        );
    }
}

test "a rail off the roster reads every merge as foreign" {
    // A structural set exists on the roster, but it names an edge this rail
    // never carries — the OFF-roster case `sketch_channels.stamp` mints a
    // fresh channel for. That channel can never equal the junction's edge 1,
    // so the merge at (12,5) MUST read `.merged_foreign` — not because
    // anything is broken, but because two edges that share no structural
    // decision are, correctly, strangers. Report-only: pins the outcome, asks
    // for no change to what gets drawn.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const CoSet = @typeInfo(@TypeOf((sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    }).co_sets)).pointer.child;
    const unrelated_members = [_]u32{ 90, 91 };
    // Stamped, as a producer stamps — the roster IS numbered here; it simply
    // has nothing to say about this rail's taps, which is the OFF-roster case
    // this test pins, not the unstamped-roster case `licenceAt`'s abstention
    // guard exists for.
    const unrelated = [_]CoSet{.{ .origin = .fan_rail, .channel = 1, .members = &unrelated_members }};

    var nodes: [4]sketch.NodePlacement = undefined;
    var taps: [3]sketch.Tap = undefined;
    var stem: [2]sketch.Point = undefined;
    var busbars: [1]sketch.Rail = undefined;
    var s = busbars_test.fanSketch(&nodes, &taps, &stem, &busbars);
    s.co_sets = &unrelated;
    // The producer mints an off-roster rail channel beyond the roster band.
    busbars[0].channel = 2;
    s.channel_stamp_state = .complete;

    const r = try raster.rasterize(a, s, .bridge);
    const at_junction = try busbars_test.recordsAt(a, r.lattice, .carrier, 12, 5);
    try testing.expectEqual(@as(usize, 1), at_junction.len);
    try testing.expectEqual(@intFromEnum(lattice.CarrierKind.merged_foreign), at_junction[0].detail);
}
