const std = @import("std");
const prim = @import("prim");
const sharing_mod = @import("base/sharing.zig");

pub const NodeId = prim.NodeId;

pub const EdgeId = prim.EdgeId;

pub const ClusterId = prim.ClusterId;

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn right(self: Rect) i32 {
        return self.x + @as(i32, @intCast(self.w));
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + @as(i32, @intCast(self.h));
    }

    pub fn contains(self: Rect, p: Point) bool {
        if (self.w == 0 or self.h == 0) return false;
        return p.x >= self.x and p.x < self.right() and
            p.y >= self.y and p.y < self.bottom();
    }

    pub fn overlaps(self: Rect, o: Rect) bool {
        if (self.w == 0 or self.h == 0) return false;
        if (o.w == 0 or o.h == 0) return false;
        return self.x < o.right() and o.x < self.right() and
            self.y < o.bottom() and o.y < self.bottom();
    }
};

pub const Dir4 = prim.Dir4;

pub const Direction = prim.Direction;

pub const Shape = prim.Shape;

pub const Port = struct {
    node: NodeId,
    side: Dir4,
    offset: u32,
};

pub const NodePlacement = struct {
    id: NodeId,
    rect: Rect,
    shape: Shape,
    lines: []const []const u8,
    cluster_id: ?ClusterId,
};

pub const ClusterFrame = struct {
    id: ClusterId,
    rect: Rect,
    parent_id: ?ClusterId,
    label: []const u8,
    depth: u8,
    direction: ?Direction = null,
    synthetic: bool = false,
};

pub const ArrowKind = prim.ArrowKind;

pub const EdgeKind = prim.EdgeKind;

pub const EdgeRole = prim.EdgeRole;

pub const EdgePath = struct {
    id: EdgeId,
    from: NodeId,
    to: NodeId,
    polyline: []const Point,
    port_from: Port,
    port_to: Port,
    arrow_from: ArrowKind,
    arrow_to: ArrowKind,
    label: ?[]const u8,
    kind: EdgeKind,
    role: EdgeRole = .forward,
    label_left_of_run: bool = false,
};

pub const Tap = struct {
    edge: EdgeId,
    node: NodeId,
    at: Point,
    landing: Point,
    label: ?[]const u8 = null,
    arrow: ArrowKind = .filled,
    continues: bool = false,
};

pub const Rail = struct {
    pivot: NodeId,
    stem: []const Point,
    crossbar: [2]Point,
    taps: []const Tap,
    kind: EdgeKind,
    role: EdgeRole = .fan_out_dropper,
    pivot_arrow: ArrowKind = .none,

    pub fn tapLabelSeg(self: Rail, tap: Tap) [2]Point {
        const junction = self.stem[self.stem.len - 1];
        if (tap.at.x != junction.x) {
            return .{ .{ .x = junction.x, .y = tap.at.y }, tap.at };
        }
        return .{ tap.at, tap.landing };
    }
};

pub const WidthBudget = struct {
    max_width: u32,
    rung: u8,
};

pub const Diagnostic = union(enum) {
    width_overflow,
    forced_label_wrap: struct {
        node: NodeId,
    },
};

pub const Sketch = struct {
    bbox: Rect,
    direction: Direction,
    nodes: []const NodePlacement,
    clusters: []const ClusterFrame,
    edges: []const EdgePath,
    rails: []const Rail = &.{},
    sharing: sharing_mod.Sharing = .{},
    diagnostics: []const Diagnostic,
    budget: WidthBudget,
};

pub fn placementById(placements: []const NodePlacement, id: NodeId) ?NodePlacement {
    for (placements) |placement| if (placement.id == id) return placement;
    return null;
}

pub fn pathById(paths: []const EdgePath, id: EdgeId) ?EdgePath {
    for (paths) |path| if (path.id == id) return path;
    return null;
}

test "Rect overlaps and contains" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 5 };
    const b: Rect = .{ .x = 5, .y = 2, .w = 10, .h = 5 };
    const c: Rect = .{ .x = 10, .y = 0, .w = 4, .h = 5 };
    const d: Rect = .{ .x = 100, .y = 100, .w = 1, .h = 1 };
    const empty: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    try std.testing.expectEqual(@as(i32, 10), a.right());
    try std.testing.expectEqual(@as(i32, 5), a.bottom());

    try std.testing.expect(a.contains(.{ .x = 0, .y = 0 }));
    try std.testing.expect(a.contains(.{ .x = 9, .y = 4 }));
    try std.testing.expect(!a.contains(.{ .x = 10, .y = 0 }));
    try std.testing.expect(!a.contains(.{ .x = 0, .y = 5 }));
    try std.testing.expect(!a.contains(.{ .x = -1, .y = 0 }));
    try std.testing.expect(!empty.contains(.{ .x = 0, .y = 0 }));

    try std.testing.expect(a.overlaps(b));
    try std.testing.expect(b.overlaps(a));
    try std.testing.expect(!a.overlaps(c));
    try std.testing.expect(!c.overlaps(a));
    try std.testing.expect(!a.overlaps(d));
    try std.testing.expect(!empty.overlaps(a));
    try std.testing.expect(!a.overlaps(empty));
}
