const std = @import("std");
const sketch = @import("../sketch.zig");
const split_mod = @import("split.zig");
const sg = @import("../sem_graph.zig");

pub const EntrySide = sketch.Dir4;

pub const EntryInset = struct {
    north: u32 = 0,
    south: u32 = 0,
    east: u32 = 0,
    west: u32 = 0,

    fn raise(self: *EntryInset, side: EntrySide) void {
        switch (side) {
            .north => self.north = 1,
            .south => self.south = 1,
            .east => self.east = 1,
            .west => self.west = 1,
        }
    }
    pub fn wExtra(self: EntryInset) u32 {
        return self.east + self.west;
    }
    pub fn hExtra(self: EntryInset) u32 {
        return self.north + self.south;
    }
    pub fn dxExtra(self: EntryInset) i32 {
        return @intCast(self.west);
    }
    pub fn dyExtra(self: EntryInset) i32 {
        return @intCast(self.north);
    }
};

pub fn entryArrivalInset(
    arrivals: []const split_mod.Arrival,
    super: split_mod.SuperNode,
    child_sketch: sketch.Sketch,
    child_input_of: []const sketch.NodeId,
    piece_orig_ids: []const sg.NodeId,
) EntryInset {
    var out: EntryInset = .{};
    if (super.synthetic) return out;
    for (arrivals) |a| {
        for (child_sketch.nodes) |cp| {
            if (cp.cluster_id != null) continue;
            if (split_mod.pieceId(piece_orig_ids, child_input_of, cp.id) != a.to) continue;
            if (isEntryLayer(child_sketch, cp.rect, a.side)) out.raise(a.side);
        }
    }
    return out;
}

fn isEntryLayer(s: sketch.Sketch, rect: sketch.Rect, side: EntrySide) bool {
    for (s.nodes) |n| {
        switch (side) {
            .north => if (n.rect.y < rect.y) return false,
            .south => if (n.rect.bottom() > rect.bottom()) return false,
            .west => if (n.rect.x < rect.x) return false,
            .east => if (n.rect.right() > rect.right()) return false,
        }
    }
    return true;
}

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
    const hit = entryArrivalInset(&arrive_top, super, s, &input_of, &orig);
    try t.expectEqual(@as(u32, 1), hit.north);
    try t.expectEqual(@as(u32, 1), hit.hExtra());
    try t.expectEqual(@as(u32, 0), hit.wExtra());
    try t.expectEqual(@as(i32, 1), hit.dyExtra());

    const arrive_deep = [_]split_mod.Arrival{.{ .to = 101, .side = .north }};
    try t.expectEqual(@as(u32, 0), entryArrivalInset(&arrive_deep, super, s, &input_of, &orig).hExtra());

    const nodes_nested = [_]sketch.NodePlacement{ tNode(0, 0, 0, 9), tNode(1, 0, 5, null) };
    try t.expectEqual(@as(u32, 0), entryArrivalInset(&arrive_top, super, tSketch(&nodes_nested), &input_of, &orig).hExtra());

    var syn = super;
    syn.synthetic = true;
    try t.expectEqual(@as(u32, 0), entryArrivalInset(&arrive_top, syn, s, &input_of, &orig).hExtra());

    const arrive_left = [_]split_mod.Arrival{.{ .to = 100, .side = .west }};
    const lr = entryArrivalInset(&arrive_left, super, s, &input_of, &orig);
    try t.expectEqual(@as(u32, 1), lr.west);
    try t.expectEqual(@as(u32, 1), lr.wExtra());
    try t.expectEqual(@as(u32, 0), lr.hExtra());
    try t.expectEqual(@as(i32, 1), lr.dxExtra());
    try t.expectEqual(@as(i32, 0), lr.dyExtra());

    const arrive_both = [_]split_mod.Arrival{ .{ .to = 100, .side = .north }, .{ .to = 100, .side = .west } };
    const both = entryArrivalInset(&arrive_both, super, s, &input_of, &orig);
    try t.expectEqual(@as(u32, 1), both.hExtra());
    try t.expectEqual(@as(u32, 1), both.wExtra());
}
