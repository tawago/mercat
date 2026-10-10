const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const split_mod = @import("split.zig");
const entry_inset = @import("entry_inset.zig");

fn tNode(id: sketch.NodeId, x: i32, y: i32, cid: ?sketch.ClusterId) sketch.NodePlacement {
    return .{ .id = id, .rect = .{ .x = x, .y = y, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = cid };
}

fn tSketch(nodes: []const sketch.NodePlacement) sketch.Sketch {
    return .{ .bbox = .{ .x = 0, .y = 0, .w = 20, .h = 20 }, .direction = .TD, .nodes = nodes, .clusters = &.{}, .edges = &.{}, .rails = &.{}, .diagnostics = &.{}, .budget = .{ .max_width = 20, .rung = 0 } };
}

test "entryArrivalInset" {
    const t = std.testing;
    const super: split_mod.SuperNode = .{ .outer_node = 0, .cluster_id = 7, .child_piece = 1, .synthetic = false };
    const nodes = [_]sketch.NodePlacement{ tNode(0, 0, 0, null), tNode(1, 0, 5, null) };
    const s = tSketch(&nodes);
    const input_of = [_]sketch.NodeId{ 0, 1 };
    const orig = [_]sg.NodeId{ 100, 101 };

    const arrive_top = [_]split_mod.Arrival{.{ .to = 100, .side = .north }};
    const hit = entry_inset.entryArrivalInset(&arrive_top, &.{}, super, 0, s, &input_of, &orig);
    try t.expectEqual(@as(u32, 1), hit.north);
    try t.expectEqual(@as(u32, 1), hit.hExtra());
    try t.expectEqual(@as(u32, 0), hit.wExtra());
    try t.expectEqual(@as(i32, 1), hit.dyExtra());

    const arrive_deep = [_]split_mod.Arrival{.{ .to = 101, .side = .north }};
    try t.expectEqual(@as(u32, 0), entry_inset.entryArrivalInset(&arrive_deep, &.{}, super, 0, s, &input_of, &orig).hExtra());

    const nodes_nested = [_]sketch.NodePlacement{ tNode(0, 0, 0, 9), tNode(1, 0, 5, null) };
    try t.expectEqual(@as(u32, 0), entry_inset.entryArrivalInset(&arrive_top, &.{}, super, 0, tSketch(&nodes_nested), &input_of, &orig).hExtra());

    var syn = super;
    syn.synthetic = true;
    try t.expectEqual(@as(u32, 0), entry_inset.entryArrivalInset(&arrive_top, &.{}, syn, 0, s, &input_of, &orig).hExtra());

    const arrive_left = [_]split_mod.Arrival{.{ .to = 100, .side = .west }};
    const lr = entry_inset.entryArrivalInset(&arrive_left, &.{}, super, 0, s, &input_of, &orig);
    try t.expectEqual(@as(u32, 1), lr.west);
    try t.expectEqual(@as(u32, 1), lr.wExtra());
    try t.expectEqual(@as(u32, 0), lr.hExtra());
    try t.expectEqual(@as(i32, 1), lr.dxExtra());
    try t.expectEqual(@as(i32, 0), lr.dyExtra());

    const arrive_both = [_]split_mod.Arrival{ .{ .to = 100, .side = .north }, .{ .to = 100, .side = .west } };
    const both = entry_inset.entryArrivalInset(&arrive_both, &.{}, super, 0, s, &input_of, &orig);
    try t.expectEqual(@as(u32, 1), both.hExtra());
    try t.expectEqual(@as(u32, 1), both.wExtra());
}

test "entryArrivalInset: a crossing leg's label width becomes run room inside the frame" {
    const t = std.testing;
    const super: split_mod.SuperNode = .{ .outer_node = 0, .cluster_id = 7, .child_piece = 1, .synthetic = false };
    const nodes = [_]sketch.NodePlacement{ tNode(0, 0, 0, null), tNode(1, 0, 5, null) };
    const s = tSketch(&nodes);
    const input_of = [_]sketch.NodeId{ 0, 1 };
    const orig = [_]sg.NodeId{ 100, 101 };

    const enter = [_]split_mod.Arrival{.{ .to = 100, .side = .north, .label_w = 8 }};
    const leave = [_]split_mod.Departure{.{ .from = 101, .side = .south, .label_w = 8 }};
    const td = entry_inset.entryArrivalInset(&enter, &leave, super, 0, s, &input_of, &orig);
    try t.expectEqual(@as(u32, 3), td.north);
    try t.expectEqual(@as(u32, 2), td.south);
    try t.expectEqual(@as(u32, 0), td.wExtra());

    const wide = [_]split_mod.Arrival{.{ .to = 100, .side = .north, .label_w = 20 }};
    const spill = entry_inset.entryArrivalInset(&wide, &.{}, super, 0, s, &input_of, &orig);
    try t.expectEqual(@as(u32, 6), spill.west);
    try t.expectEqual(spill.west, spill.east);

    const deep = [_]split_mod.Departure{.{ .from = 100, .side = .south, .label_w = 8 }};
    try t.expectEqual(@as(u32, 0), entry_inset.entryArrivalInset(&.{}, &deep, super, 0, s, &input_of, &orig).south);

    const shared = [_]split_mod.Arrival{ .{ .to = 100, .side = .north, .label_w = 8 }, .{ .to = 101, .side = .north } };
    try t.expectEqual(@as(u32, 3), entry_inset.entryArrivalInset(&shared, &.{}, super, 0, s, &input_of, &orig).north);

    const lr = [_]split_mod.Arrival{.{ .to = 100, .side = .west, .label_w = 8 }};
    try t.expectEqual(@as(u32, 10), entry_inset.entryArrivalInset(&lr, &.{}, super, 0, s, &input_of, &orig).west);
}
