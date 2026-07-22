//! cluster/entry_inset.zig — the shared "entry-side frame inset" predicate.
//!
//! A cross-border edge that terminates on a subgraph's FIRST-LAYER member lands
//! its arrowhead one cell inside the frame; without a straight approach cell the
//! arrowhead's base is the frame stroke (or a title-band letter). This module
//! decides, purely, whether a super-node should grow one extra frame-inset cell
//! on its flow-entry side so the arrowhead gets a collinear base. It is the
//! SINGLE source of that decision, called from BOTH the `superSize` sizing site
//! (`recurse.stitchOuter`) and the child-translate sites (`stitch`), so sizing
//! and translation can never disagree.
//!
//! Pure data work: no allocation, no drawing. Imports `sketch`, `split`, `sem_graph`.

const std = @import("std");
const sketch = @import("../sketch.zig");
const split_mod = @import("split.zig");
const sg = @import("../sem_graph.zig");

/// Which frame side a cross-border terminal arrives on, derived from the PARENT
/// flow direction (a TD parent drops ▼ onto the target's top; LR enters from the
/// left with ▶; etc.).
pub const EntrySide = enum { north, south, east, west };

fn entrySideOf(dir: sg.Direction) EntrySide {
    return switch (dir) {
        .TD => .north,
        .BT => .south,
        .LR => .west,
        .RL => .east,
    };
}

/// One extra frame-inset cell on a cluster's flow-entry side, so a terminal
/// arrowhead landing one cell inside the frame gets a straight collinear
/// approach cell instead of sitting directly on the frame stroke.
pub const EntryInset = struct {
    /// 0 (no first-layer terminal) or 1 (raise the entry-side inset).
    extra: u32,
    side: EntrySide,

    /// Extra super-node width (east/west entry only).
    pub fn wExtra(self: EntryInset) u32 {
        return switch (self.side) {
            .east, .west => self.extra,
            .north, .south => 0,
        };
    }
    /// Extra super-node height (north/south entry only).
    pub fn hExtra(self: EntryInset) u32 {
        return switch (self.side) {
            .north, .south => self.extra,
            .east, .west => 0,
        };
    }
    /// Child x-offset when the extra inset sits on the near (west) side.
    pub fn dxExtra(self: EntryInset) i32 {
        return if (self.side == .west) @intCast(self.extra) else 0;
    }
    /// Child y-offset when the extra inset sits on the near (north) side.
    pub fn dyExtra(self: EntryInset) i32 {
        return if (self.side == .north) @intCast(self.extra) else 0;
    }
};

/// Decide whether super-node `super` needs an extra frame-inset cell on its
/// flow-entry side. Returns extra=1 iff some cross-border terminal lands on a
/// FIRST-LAYER DIRECT member of this cluster. A target inside a NESTED sub-
/// cluster carries a non-null `cluster_id` in the child sketch → excluded (the
/// edge only passes THROUGH this frame with no arrowhead here; a target wrapped
/// only in a chrome-free synthetic packing cluster is a fan branch whose
/// splitter absorbs the row without yielding a straight base, so excluding it is
/// correct too). Synthetic packing supers have no frame → never charged.
pub fn entryArrivalInset(
    crossings: []const split_mod.Crossing,
    super: split_mod.SuperNode,
    child_sketch: sketch.Sketch,
    child_input_of: []const sketch.NodeId,
    piece_orig_ids: []const sg.NodeId,
    parent_dir: sg.Direction,
) EntryInset {
    const side = entrySideOf(parent_dir);
    if (super.synthetic) return .{ .extra = 0, .side = side };
    for (crossings) |c| {
        if (c.arrow_to == .none) continue; // no terminal arrowhead into the box
        for (child_sketch.nodes) |cp| {
            if (cp.cluster_id != null) continue; // nested/fan target: not a direct frame arrival
            if (split_mod.pieceId(piece_orig_ids, child_input_of, cp.id) != c.to) continue;
            if (isEntryLayer(child_sketch, cp.rect, side))
                return .{ .extra = 1, .side = side };
        }
    }
    return .{ .extra = 0, .side = side };
}

/// True if `rect` sits on the entry-side extreme (the first layer) among all
/// child nodes — no node is further toward the entry side.
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

// ====================================================================
// Tests
// ====================================================================

fn tNode(id: sketch.NodeId, x: i32, y: i32, cid: ?sketch.ClusterId) sketch.NodePlacement {
    return .{ .id = id, .rect = .{ .x = x, .y = y, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = cid };
}

fn tSketch(nodes: []const sketch.NodePlacement) sketch.Sketch {
    return .{ .bbox = .{ .x = 0, .y = 0, .w = 20, .h = 20 }, .direction = .TD, .nodes = nodes, .clusters = &.{}, .edges = &.{}, .busbars = &.{}, .diagnostics = &.{}, .budget = .{ .max_width = 20, .rung = 0 } };
}

test "entryArrivalInset" {
    const t = std.testing;
    const super: split_mod.SuperNode = .{ .outer_node = 0, .cluster_id = 7, .child_piece = 1, .synthetic = false };
    // child sketch: node 0 at top layer (y=0), node 1 below (y=5); ids map 1:1 to orig.
    const nodes = [_]sketch.NodePlacement{ tNode(0, 0, 0, null), tNode(1, 0, 5, null) };
    const s = tSketch(&nodes);
    const input_of = [_]sketch.NodeId{ 0, 1 };
    const orig = [_]sg.NodeId{ 100, 101 };

    // Crossing terminating on the FIRST-LAYER member (orig 100) → charge north +1.
    const cross_top = [_]split_mod.Crossing{.{ .id = 0, .from = 200, .to = 100, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null }};
    const hit = entryArrivalInset(&cross_top, super, s, &input_of, &orig, .TD);
    try t.expectEqual(@as(u32, 1), hit.extra);
    try t.expectEqual(EntrySide.north, hit.side);
    try t.expectEqual(@as(u32, 1), hit.hExtra());
    try t.expectEqual(@as(u32, 0), hit.wExtra());
    try t.expectEqual(@as(i32, 1), hit.dyExtra());

    // Crossing terminating on a LATER-layer member (orig 101) → no charge.
    const cross_deep = [_]split_mod.Crossing{.{ .id = 0, .from = 200, .to = 101, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null }};
    try t.expectEqual(@as(u32, 0), entryArrivalInset(&cross_deep, super, s, &input_of, &orig, .TD).extra);

    // Arrowless crossing → no charge.
    const cross_none = [_]split_mod.Crossing{.{ .id = 0, .from = 200, .to = 100, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null }};
    try t.expectEqual(@as(u32, 0), entryArrivalInset(&cross_none, super, s, &input_of, &orig, .TD).extra);

    // Nested target (cluster_id set) → pass-through, no charge.
    const nodes_nested = [_]sketch.NodePlacement{ tNode(0, 0, 0, 9), tNode(1, 0, 5, null) };
    try t.expectEqual(@as(u32, 0), entryArrivalInset(&cross_top, super, tSketch(&nodes_nested), &input_of, &orig, .TD).extra);

    // Synthetic super → never charged.
    var syn = super;
    syn.synthetic = true;
    try t.expectEqual(@as(u32, 0), entryArrivalInset(&cross_top, syn, s, &input_of, &orig, .TD).extra);

    // LR parent → west side, extra becomes WIDTH + near-side x-offset.
    const lr = entryArrivalInset(&cross_top, super, s, &input_of, &orig, .LR);
    try t.expectEqual(EntrySide.west, lr.side);
    try t.expectEqual(@as(u32, 1), lr.wExtra());
    try t.expectEqual(@as(u32, 0), lr.hExtra());
    try t.expectEqual(@as(i32, 1), lr.dxExtra());
    try t.expectEqual(@as(i32, 0), lr.dyExtra());
}
