const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const split_mod = @import("split.zig");
const corridors = @import("corridors.zig");
const sg = @import("../sem_graph.zig");

pub const EntrySide = sketch.Dir4;

pub const EntryInset = struct {
    north: u32 = 0,
    south: u32 = 0,
    east: u32 = 0,
    west: u32 = 0,

    fn raise(self: *EntryInset, side: EntrySide, n: u32) void {
        const field = switch (side) {
            .north => &self.north,
            .south => &self.south,
            .east => &self.east,
            .west => &self.west,
        };
        field.* = @max(field.*, n);
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

const Leg = struct { side: EntrySide, label_w: u32, head: bool, base: u32 };

const Pad = struct { x: u32, y: u32 };

pub fn entryArrivalInset(
    arrivals: []const split_mod.Arrival,
    departures: []const split_mod.Departure,
    super: split_mod.SuperNode,
    scale: u32,
    child_sketch: sketch.Sketch,
    child_input_of: []const sketch.NodeId,
    piece_orig_ids: []const sg.NodeId,
) EntryInset {
    var out: EntryInset = .{};
    if (super.synthetic) return out;
    const pad: Pad = .{ .x = prim.framePadX(scale), .y = prim.framePadY(scale) };
    const piece: Piece = .{ .sketch = child_sketch, .input_of = child_input_of, .orig_ids = piece_orig_ids };
    for (child_sketch.nodes) |cp| {
        if (cp.cluster_id != null) continue;
        const pid = piece.id(cp);
        for (arrivals) |a| {
            if (a.to != pid) continue;
            const leg: Leg = .{ .side = a.side, .label_w = a.label_w, .head = true, .base = 1 };
            raiseFor(&out, child_sketch, cp.rect, leg, pad);
        }
        for (departures) |d| {
            if (d.from != pid) continue;
            const leg: Leg = .{ .side = d.side, .label_w = d.label_w, .head = d.tail, .base = 0 };
            raiseFor(&out, child_sketch, cp.rect, leg, pad);
        }
    }
    return out;
}

fn raiseFor(out: *EntryInset, s: sketch.Sketch, rect: sketch.Rect, leg: Leg, pad: Pad) void {
    if (!isEntryLayer(s, rect, leg.side)) return;
    out.raise(leg.side, leg.base);
    if (leg.label_w == 0) return;
    const head: u32 = @intFromBool(leg.head);
    switch (leg.side) {
        .north, .south => {
            out.raise(leg.side, prim.labelRunCells(1, head) -| (pad.y - 1));
            const cc: i32 = @intCast(leg.label_w);
            const px = rect.x + @as(i32, @intCast(corridors.sideOffset(rect, leg.side)));
            const start = px - @divTrunc(cc - 1, 2);
            const wall: i32 = @as(i32, @intCast(prim.label_box_clearance + 1)) - @as(i32, @intCast(pad.x));
            const need: u32 = @intCast(@max(0, @max(wall - start, start + cc + wall - @as(i32, @intCast(s.bbox.w)))));
            out.raise(.west, need);
            out.raise(.east, need);
        },
        .east, .west => out.raise(leg.side, (prim.label_box_clearance + leg.label_w + prim.label_run_margin + head) -| (pad.x - 1)),
    }
}

const Piece = struct {
    sketch: sketch.Sketch,
    input_of: []const sketch.NodeId,
    orig_ids: []const sg.NodeId,

    fn id(self: Piece, p: sketch.NodePlacement) sg.NodeId {
        return split_mod.pieceId(self.orig_ids, self.input_of, p.id);
    }
};

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
