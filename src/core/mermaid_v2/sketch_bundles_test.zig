const std = @import("std");
const ledger = @import("base/ledger.zig");
const sketch = @import("sketch.zig");
const sketch_bundles = @import("sketch_bundles.zig");
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

fn sketchWith(sets: []const ledger.Bundle, rails_buf: []const sketch.Rail) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .rails = rails_buf,
        .bundle_sets = sets,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

test "a stamped sketch names its rail's bundle and its bundle sets alike" {
    const members = [_]ledger.EdgeId{ 0, 1 };
    const sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &members }};
    const rails_buf = [_]sketch.Rail{railAt(&taps_a, 3)};
    var s = sketchWith(&sets, &rails_buf);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_bundles.stamp(arena.allocator(), &s);

    try testing.expectEqual(sketch.BundleStampState.complete, s.bundle_stamp_state);
    try testing.expect(ledger.bundleSetsNumbered(s.bundle_sets));
    try testing.expectEqual(@as(ledger.BundleId, 1), s.bundle_sets[0].bundle);
    try testing.expectEqual(@as(ledger.BundleId, 1), s.rails[0].bundle);
    try testing.expect(ledger.memberOfBundleAt(s.bundle_sets, 1, 0, null));
    try testing.expect(ledger.memberOfBundleAt(s.bundle_sets, 1, 1, null));
    try testing.expect(ledger.bundleMembersAt(s.bundle_sets, 0, 1, null));
}

test "merged bundle sets name every bundle once" {
    const a = [_]ledger.EdgeId{ 0, 1 };
    const b = [_]ledger.EdgeId{ 2, 3 };
    const sets = [_]ledger.Bundle{
        .{ .origin = .fan_rail, .bundle = 1, .members = &a },
        .{ .origin = .fan_rail, .bundle = 1, .members = &b },
    };
    var s = sketchWith(&sets, &.{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_bundles.stamp(arena.allocator(), &s);

    try testing.expectEqual(@as(ledger.BundleId, 1), s.bundle_sets[0].bundle);
    try testing.expectEqual(@as(ledger.BundleId, 2), s.bundle_sets[1].bundle);
    try testing.expect(ledger.memberOfBundleAt(s.bundle_sets, 1, 0, null));
    try testing.expect(ledger.memberOfBundleAt(s.bundle_sets, 2, 2, null));
    try testing.expect(!ledger.memberOfBundleAt(s.bundle_sets, 1, 2, null));
    try testing.expect(!ledger.bundleMembersAt(s.bundle_sets, 0, 2, null));
}

test "a rail in no bundle set is stamped a bundle none of its future merges can ever match" {
    const unrelated_members = [_]ledger.EdgeId{ 90, 91 };
    const sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &unrelated_members }};
    const rails_buf = [_]sketch.Rail{railAt(&taps_a, 3)};
    var s = sketchWith(&sets, &rails_buf);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_bundles.stamp(arena.allocator(), &s);

    try testing.expectEqual(@as(ledger.BundleId, 1), s.bundle_sets[0].bundle);
    try testing.expectEqual(@as(ledger.BundleId, 2), s.rails[0].bundle);
    try testing.expect(s.rails[0].bundle != s.bundle_sets[0].bundle);
}

test "a rail no set holds gets a name of its own, past the bundle sets" {
    const members = [_]ledger.EdgeId{ 0, 1 };
    const sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &members }};
    const rails_buf = [_]sketch.Rail{ railAt(&taps_a, 3), railAt(&taps_b, 5) };
    var s = sketchWith(&sets, &rails_buf);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_bundles.stamp(arena.allocator(), &s);

    try testing.expectEqual(@as(ledger.BundleId, 1), s.rails[0].bundle);
    try testing.expectEqual(@as(ledger.BundleId, 2), s.rails[1].bundle);
    try testing.expect(s.rails[1].bundle != s.rails[0].bundle);
}

test "a port share is too narrow to name a whole rail" {
    const members = [_]ledger.EdgeId{ 0, 1 };
    const here = [_]ledger.BundleCell{.{ .x = 1, .y = 3 }};
    const sets = [_]ledger.Bundle{.{ .origin = .port_share, .members = &members, .cells = &here }};
    const rails_buf = [_]sketch.Rail{railAt(&taps_a, 3)};
    var s = sketchWith(&sets, &rails_buf);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_bundles.stamp(arena.allocator(), &s);

    try testing.expectEqual(@as(ledger.BundleId, 2), s.rails[0].bundle);
}

test "different structural bundles reject the whole stamp" {
    const set0_members = [_]ledger.EdgeId{taps_a[0].edge};
    const set1_members = [_]ledger.EdgeId{taps_a[1].edge};
    const sets = [_]ledger.Bundle{
        .{ .origin = .fan_rail, .bundle = 41, .members = &set0_members },
        .{ .origin = .fan_rail, .bundle = 42, .members = &set1_members },
    };
    const rails_buf = [_]sketch.Rail{blk: {
        var rail = railAt(&taps_a, 3);
        rail.bundle = 73;
        break :blk rail;
    }};
    var s = sketchWith(&sets, &rails_buf);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_bundles.stamp(arena.allocator(), &s);

    try testing.expectEqual(sketch.BundleStampState.rail_invariant, s.bundle_stamp_state);
    try testing.expect(s.bundle_sets.ptr == sets[0..].ptr);
    try testing.expect(s.rails.ptr == rails_buf[0..].ptr);
    try testing.expectEqualDeep(sets[0..], s.bundle_sets);
    try testing.expectEqualDeep(rails_buf[0..], s.rails);
}

test "partial structural membership rejects the whole stamp" {
    const sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &.{taps_a[0].edge} }};
    const rails_buf = [_]sketch.Rail{railAt(&taps_a, 3)};
    var s = sketchWith(&sets, &rails_buf);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_bundles.stamp(arena.allocator(), &s);

    try testing.expectEqual(sketch.BundleStampState.rail_invariant, s.bundle_stamp_state);
    try testing.expect(s.bundle_sets.ptr == sets[0..].ptr);
    try testing.expect(s.rails.ptr == rails_buf[0..].ptr);
    try testing.expectEqual(ledger.no_bundle, s.bundle_sets[0].bundle);
    try testing.expectEqual(ledger.no_bundle, s.rails[0].bundle);
}

test "a tap in multiple structural sets rejects the whole stamp" {
    const sets = [_]ledger.Bundle{
        .{ .origin = .fan_rail, .members = &.{ 0, 1 } },
        .{ .origin = .selected_bundle, .members = &.{ 0, 1 } },
    };
    const rails_buf = [_]sketch.Rail{railAt(&taps_a, 3)};
    var s = sketchWith(&sets, &rails_buf);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sketch_bundles.stamp(arena.allocator(), &s);

    try testing.expectEqual(sketch.BundleStampState.rail_invariant, s.bundle_stamp_state);
    try testing.expect(s.bundle_sets.ptr == sets[0..].ptr);
    try testing.expect(s.rails.ptr == rails_buf[0..].ptr);
    try testing.expectEqual(ledger.no_bundle, s.bundle_sets[0].bundle);
    try testing.expectEqual(ledger.no_bundle, s.bundle_sets[1].bundle);
    try testing.expectEqual(ledger.no_bundle, s.rails[0].bundle);
}

test "stamp is transactional across both allocation failures and success" {
    const members = [_]ledger.EdgeId{ 0, 1 };
    const sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .bundle = 41, .members = &members }};
    const original_rail = blk: {
        var rail = railAt(&taps_a, 3);
        rail.bundle = 73;
        break :blk rail;
    };
    const rails_buf = [_]sketch.Rail{original_rail};

    var fail_index: usize = 0;
    while (fail_index < 3) : (fail_index += 1) {
        var s = sketchWith(&sets, &rails_buf);
        s.bundle_stamp_state = .complete;
        const before_sets = sets;
        const before_rails = rails_buf;
        const before_sets_ptr = s.bundle_sets.ptr;
        const before_rails_ptr = s.rails.ptr;
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        sketch_bundles.stamp(failing.allocator(), &s);

        if (fail_index < 2) {
            try testing.expect(failing.has_induced_failure);
            try testing.expectEqual(sketch.BundleStampState.out_of_memory, s.bundle_stamp_state);
            try testing.expect(s.bundle_sets.ptr == before_sets_ptr);
            try testing.expect(s.rails.ptr == before_rails_ptr);
            try testing.expectEqualDeep(before_sets[0..], s.bundle_sets);
            try testing.expectEqualDeep(before_rails[0..], s.rails);
        } else {
            defer failing.allocator().free(s.rails);
            defer failing.allocator().free(s.bundle_sets);
            try testing.expect(!failing.has_induced_failure);
            try testing.expectEqual(sketch.BundleStampState.complete, s.bundle_stamp_state);
            try testing.expect(s.bundle_sets.ptr != before_sets_ptr);
            try testing.expect(s.rails.ptr != before_rails_ptr);
            try testing.expectEqual(@as(ledger.BundleId, 1), s.bundle_sets[0].bundle);
            try testing.expectEqual(@as(ledger.BundleId, 1), s.rails[0].bundle);
        }
    }
}

test "a production render reaches the raster with its bundle sets numbered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n";
    const graph = try parse.parse(a, source);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const chosen = try select.choose(a, graph, &plan, 80, false, false, .bridge);

    try testing.expectEqual(sketch.BundleStampState.complete, chosen.sketch.bundle_stamp_state);
    try testing.expect(ledger.bundleSetsNumbered(chosen.sketch.bundle_sets));
    for (chosen.sketch.rails) |rail| {
        try testing.expect(rail.bundle != ledger.no_bundle);
    }
}
