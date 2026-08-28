//! Unit tests for `sketch_channels.zig`: the roster gets one name per set,
//! a rail adopts the name of the set that holds its members, and a rail no
//! set holds still gets a name of its own.
//!
//! Plus the end-to-end fact the raster depends on: a real render's Sketch
//! reaches the rasterizer with its roster numbered, so a reader downstream is
//! never handed a blank identity to compare against.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const sketch = @import("sketch.zig");
const sketch_channels = @import("sketch_channels.zig");
const parse = @import("parse.zig");
const select = @import("select.zig");
const permits = @import("ledger/permits.zig");

const testing = std.testing;

const taps_a = [_]sketch.Tap{
    .{ .edge = 0, .node = 1, .at = .{ .x = 1, .y = 3 }, .landing = .{ .x = 1, .y = 6 } },
    .{ .edge = 1, .node = 2, .at = .{ .x = 5, .y = 3 }, .landing = .{ .x = 5, .y = 6 } },
};
const taps_b = [_]sketch.Tap{
    .{ .edge = 7, .node = 3, .at = .{ .x = 2, .y = 5 }, .landing = .{ .x = 2, .y = 8 } },
};

fn railAt(taps: []const sketch.Tap, y: i32) sketch.Rail {
    return .{
        .pivot = 0,
        .stem = &.{},
        .crossbar = .{ .{ .x = 1, .y = y }, .{ .x = 5, .y = y } },
        .taps = taps,
        .kind = .solid,
    };
}

fn sketchWith(sets: []const ledger.CoSet, bars: []const sketch.Rail) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .rails = bars,
        .co_sets = sets,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

test "a stamped sketch names its rail's channel and its roster alike" {
    const members = [_]ledger.EdgeId{ 0, 1 };
    const sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &members }};
    const bars = [_]sketch.Rail{railAt(&taps_a, 3)};
    var s = sketchWith(&sets, &bars);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_channels.stamp(arena.allocator(), &s);

    try testing.expectEqual(sketch.ChannelStampState.complete, s.channel_stamp_state);
    try testing.expect(ledger.rosterNumbered(s.co_sets));
    try testing.expectEqual(@as(ledger.ChannelId, 1), s.co_sets[0].channel);
    // The rail rides the set that names its members, so the two agree — which
    // is what lets the rail writer state a licence without a scan.
    try testing.expectEqual(@as(ledger.ChannelId, 1), s.rails[0].channel);
    try testing.expectEqual(@as(ledger.ChannelId, 1), ledger.channelOf(s.co_sets, 0, null));
    try testing.expectEqual(@as(ledger.ChannelId, 1), ledger.channelOf(s.co_sets, 1, null));
    try testing.expect(ledger.channelsAgree(s.co_sets, 0, 1, null));
}

test "a merged roster names every channel once" {
    // Two children's sets, each of which numbered its own fan from one before
    // the merge: re-numbering is what stops them answering to one name.
    const a = [_]ledger.EdgeId{ 0, 1 };
    const b = [_]ledger.EdgeId{ 2, 3 };
    const sets = [_]ledger.CoSet{
        .{ .origin = .fan_rail, .channel = 1, .members = &a },
        .{ .origin = .fan_rail, .channel = 1, .members = &b },
    };
    var s = sketchWith(&sets, &.{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_channels.stamp(arena.allocator(), &s);

    try testing.expectEqual(@as(ledger.ChannelId, 1), s.co_sets[0].channel);
    try testing.expectEqual(@as(ledger.ChannelId, 2), s.co_sets[1].channel);
    try testing.expect(!ledger.channelsAgree(s.co_sets, 0, 2, null));
}

test "a rail off the roster is stamped a channel none of its future merges can ever match" {
    // A structural set exists, but it names neither of this rail's taps — the
    // OFF-roster case. The rail still gets a name (past the roster's end),
    // but that name is a fresh mint no OTHER edge can ever hold, so every
    // future comparison against it (`ledger.channelOf` for some foreign edge)
    // reads unequal. This pins that the rail's channel and the roster's
    // channel are, by construction, disjoint — the fact that makes
    // `.merged_foreign` the INEVITABLE outcome of such a rail's every merge.
    const unrelated_members = [_]ledger.EdgeId{ 90, 91 };
    const sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &unrelated_members }};
    const bars = [_]sketch.Rail{railAt(&taps_a, 3)};
    var s = sketchWith(&sets, &bars);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_channels.stamp(arena.allocator(), &s);

    try testing.expectEqual(@as(ledger.ChannelId, 1), s.co_sets[0].channel);
    try testing.expectEqual(@as(ledger.ChannelId, 2), s.rails[0].channel);
    // The roster's one set can never answer with 2 — `numberChannels` only
    // ever mints 1..N over N sets — so no future set on this roster can ever
    // collide with this rail's name.
    try testing.expect(s.rails[0].channel != s.co_sets[0].channel);
}

test "a rail no set holds gets a name of its own, past the roster" {
    const members = [_]ledger.EdgeId{ 0, 1 };
    const sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &members }};
    const bars = [_]sketch.Rail{ railAt(&taps_a, 3), railAt(&taps_b, 5) };
    var s = sketchWith(&sets, &bars);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_channels.stamp(arena.allocator(), &s);

    try testing.expectEqual(@as(ledger.ChannelId, 1), s.rails[0].channel);
    // Past the roster's end, so it can collide with neither a set's name nor
    // the other rail's — and it is a SHARED name, which the one-edge-wide
    // private band could not express.
    try testing.expectEqual(@as(ledger.ChannelId, 2), s.rails[1].channel);
    try testing.expect(s.rails[1].channel != s.rails[0].channel);
}

test "a port share is too narrow to name a whole rail" {
    const members = [_]ledger.EdgeId{ 0, 1 };
    const here = [_]ledger.CoCell{.{ .x = 1, .y = 3 }};
    const sets = [_]ledger.CoSet{.{ .origin = .port_share, .members = &members, .cells = &here }};
    const bars = [_]sketch.Rail{railAt(&taps_a, 3)};
    var s = sketchWith(&sets, &bars);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_channels.stamp(arena.allocator(), &s);

    // The share licenses one cell; the crossbar spans five. Adopting its name
    // would hand the whole run the authority of a share that stops at a port.
    try testing.expectEqual(@as(ledger.ChannelId, 2), s.rails[0].channel);
}

test "different structural channels reject the whole stamp" {
    const set0_members = [_]ledger.EdgeId{taps_a[0].edge};
    const set1_members = [_]ledger.EdgeId{taps_a[1].edge};
    const sets = [_]ledger.CoSet{
        .{ .origin = .fan_rail, .channel = 41, .members = &set0_members },
        .{ .origin = .fan_rail, .channel = 42, .members = &set1_members },
    };
    const bars = [_]sketch.Rail{blk: {
        var bar = railAt(&taps_a, 3);
        bar.channel = 73;
        break :blk bar;
    }};
    var s = sketchWith(&sets, &bars);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_channels.stamp(arena.allocator(), &s);

    try testing.expectEqual(sketch.ChannelStampState.rail_invariant, s.channel_stamp_state);
    try testing.expect(s.co_sets.ptr == sets[0..].ptr);
    try testing.expect(s.rails.ptr == bars[0..].ptr);
    try testing.expectEqualDeep(sets[0..], s.co_sets);
    try testing.expectEqualDeep(bars[0..], s.rails);
}

test "partial structural membership rejects the whole stamp" {
    const sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &.{taps_a[0].edge} }};
    const bars = [_]sketch.Rail{railAt(&taps_a, 3)};
    var s = sketchWith(&sets, &bars);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_channels.stamp(arena.allocator(), &s);

    try testing.expectEqual(sketch.ChannelStampState.rail_invariant, s.channel_stamp_state);
    try testing.expect(s.co_sets.ptr == sets[0..].ptr);
    try testing.expect(s.rails.ptr == bars[0..].ptr);
    try testing.expectEqual(ledger.no_channel, s.co_sets[0].channel);
    try testing.expectEqual(ledger.no_channel, s.rails[0].channel);
}

test "a tap in multiple structural sets rejects the whole stamp" {
    const sets = [_]ledger.CoSet{
        .{ .origin = .fan_rail, .members = &.{ 0, 1 } },
        .{ .origin = .selected_join, .members = &.{ 0, 1 } },
    };
    const bars = [_]sketch.Rail{railAt(&taps_a, 3)};
    var s = sketchWith(&sets, &bars);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_channels.stamp(arena.allocator(), &s);

    try testing.expectEqual(sketch.ChannelStampState.rail_invariant, s.channel_stamp_state);
    try testing.expect(s.co_sets.ptr == sets[0..].ptr);
    try testing.expect(s.rails.ptr == bars[0..].ptr);
    try testing.expectEqual(ledger.no_channel, s.co_sets[0].channel);
    try testing.expectEqual(ledger.no_channel, s.co_sets[1].channel);
    try testing.expectEqual(ledger.no_channel, s.rails[0].channel);
}

test "stamp is transactional across both allocation failures and success" {
    const members = [_]ledger.EdgeId{ 0, 1 };
    const sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .channel = 41, .members = &members }};
    const original_bar = blk: {
        var bar = railAt(&taps_a, 3);
        bar.channel = 73;
        break :blk bar;
    };
    const bars = [_]sketch.Rail{original_bar};

    var fail_index: usize = 0;
    while (fail_index < 3) : (fail_index += 1) {
        var s = sketchWith(&sets, &bars);
        s.channel_stamp_state = .complete;
        const before_sets = sets;
        const before_bars = bars;
        const before_sets_ptr = s.co_sets.ptr;
        const before_bars_ptr = s.rails.ptr;
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        sketch_channels.stamp(failing.allocator(), &s);

        if (fail_index < 2) {
            try testing.expect(failing.has_induced_failure);
            try testing.expectEqual(sketch.ChannelStampState.out_of_memory, s.channel_stamp_state);
            try testing.expect(s.co_sets.ptr == before_sets_ptr);
            try testing.expect(s.rails.ptr == before_bars_ptr);
            try testing.expectEqualDeep(before_sets[0..], s.co_sets);
            try testing.expectEqualDeep(before_bars[0..], s.rails);
        } else {
            defer failing.allocator().free(s.rails);
            defer failing.allocator().free(s.co_sets);
            try testing.expect(!failing.has_induced_failure);
            try testing.expectEqual(sketch.ChannelStampState.complete, s.channel_stamp_state);
            try testing.expect(s.co_sets.ptr != before_sets_ptr);
            try testing.expect(s.rails.ptr != before_bars_ptr);
            try testing.expectEqual(@as(ledger.ChannelId, 1), s.co_sets[0].channel);
            try testing.expectEqual(@as(ledger.ChannelId, 1), s.rails[0].channel);
        }
    }
}

test "a production render reaches the raster with its roster numbered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n";
    const graph = try parse.parse(a, source);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const chosen = try select.choose(a, graph, &plan, 80, false, false);

    try testing.expectEqual(sketch.ChannelStampState.complete, chosen.sketch.channel_stamp_state);
    try testing.expect(ledger.rosterNumbered(chosen.sketch.co_sets));
    for (chosen.sketch.rails) |bb| {
        try testing.expect(bb.channel != ledger.no_channel);
    }
}
