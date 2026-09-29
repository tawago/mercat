const std = @import("std");

pub const DiagramType = @import("detect.zig").Kind;

pub const Direction = enum {
    LR,
    RL,
    TD,
    TB,
    BT,
};

pub const BoxChars = struct {
    top_left: u21,
    top_right: u21,
    bottom_left: u21,
    bottom_right: u21,
    horizontal: u21,
    vertical: u21,
};

pub const unicode_square: BoxChars = .{
    .top_left = 0x250C,
    .top_right = 0x2510,
    .bottom_left = 0x2514,
    .bottom_right = 0x2518,
    .horizontal = 0x2500,
    .vertical = 0x2502,
};

pub const unicode_rounded: BoxChars = .{
    .top_left = 0x256D,
    .top_right = 0x256E,
    .bottom_left = 0x2570,
    .bottom_right = 0x256F,
    .horizontal = 0x2500,
    .vertical = 0x2502,
};

pub const Arrows = struct {
    pub const right: u21 = 0x25B6;
    pub const down: u21 = 0x25BC;

    pub const right_thin: u21 = 0x25BA;
    pub const left_thin: u21 = 0x25C4;
    pub const up_thin: u21 = 0x25B2;
    pub const down_thin: u21 = 0x25BC;
};

pub const LineChars = struct {
    pub const horizontal: u21 = 0x2500;
    pub const vertical: u21 = 0x2502;
    pub const corner_ne: u21 = 0x2514;
    pub const corner_nw: u21 = 0x2518;
    pub const corner_se: u21 = 0x250C;
    pub const corner_sw: u21 = 0x2510;
    pub const tee_left: u21 = 0x2524;
    pub const tee_right: u21 = 0x251C;

    pub const horizontal_dotted: u21 = 0x2504;
    pub const vertical_dotted: u21 = 0x2506;

    pub const horizontal_thick: u21 = 0x2501;
};

pub const Point = struct {
    x: i32,
    y: i32,

    pub fn eql(self: Point, other: Point) bool {
        return self.x == other.x and self.y == other.y;
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and
            p.x < self.x + @as(i32, @intCast(self.width)) and
            p.y >= self.y and
            p.y < self.y + @as(i32, @intCast(self.height));
    }

    pub fn right(self: Rect) i32 {
        return self.x + @as(i32, @intCast(self.width));
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + @as(i32, @intCast(self.height));
    }
};

pub const NotePosition = enum {
    left_of,
    right_of,
    over,
};

test "DiagramType detection" {
    const testing = std.testing;

    try testing.expectEqual(DiagramType.flowchart, DiagramType.fromSource("graph LR"));
    try testing.expectEqual(DiagramType.flowchart, DiagramType.fromSource("flowchart TD"));
    try testing.expectEqual(DiagramType.flowchart, DiagramType.fromSource("  graph LR\n  A --> B"));
    try testing.expectEqual(DiagramType.sequence, DiagramType.fromSource("sequenceDiagram"));
    try testing.expectEqual(DiagramType.class_diagram, DiagramType.fromSource("classDiagram"));
    try testing.expectEqual(DiagramType.state, DiagramType.fromSource("stateDiagram"));
    try testing.expectEqual(DiagramType.state, DiagramType.fromSource("stateDiagram-v2"));
    try testing.expectEqual(DiagramType.er, DiagramType.fromSource("erDiagram"));
    try testing.expectEqual(DiagramType.unsupported, DiagramType.fromSource("pie"));
    try testing.expectEqual(DiagramType.unsupported, DiagramType.fromSource("gantt"));
}
