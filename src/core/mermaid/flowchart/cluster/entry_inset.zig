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
