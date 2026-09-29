const std = @import("std");
const text = @import("text");

pub const DiagramType = enum {
    flowchart,
    sequence,
    class_diagram,
    state,
    er,
    unsupported,

    pub fn fromSource(source: []const u8) DiagramType {
        const trimmed = text.firstMeaningfulLine(source, "%%");
        if (std.mem.startsWith(u8, trimmed, "graph") or
            std.mem.startsWith(u8, trimmed, "flowchart"))
        {
            return .flowchart;
        }
        if (std.mem.startsWith(u8, trimmed, "sequenceDiagram")) return .sequence;
        if (std.mem.startsWith(u8, trimmed, "classDiagram")) return .class_diagram;
        if (std.mem.startsWith(u8, trimmed, "stateDiagram")) return .state;
        if (std.mem.startsWith(u8, trimmed, "erDiagram")) return .er;
        return .unsupported;
    }
};

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

pub const ascii_box: BoxChars = .{
    .top_left = '+',
    .top_right = '+',
    .bottom_left = '+',
    .bottom_right = '+',
    .horizontal = '-',
    .vertical = '|',
};

pub const BoxDrawingStyle = enum {
    standard,
    rounded,
    heavy,
    double,
    ascii,
};

pub const Arrows = struct {
    pub const right: u21 = 0x25B6;
    pub const left: u21 = 0x25C0;
    pub const up: u21 = 0x25B2;
    pub const down: u21 = 0x25BC;

    pub const right_thin: u21 = 0x25BA;
    pub const left_thin: u21 = 0x25C4;
    pub const up_thin: u21 = 0x25B2;
    pub const down_thin: u21 = 0x25BC;

    pub const right_ascii: u21 = '>';
    pub const left_ascii: u21 = '<';
    pub const up_ascii: u21 = '^';
    pub const down_ascii: u21 = 'v';
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
    pub const tee_up: u21 = 0x2534;
    pub const tee_down: u21 = 0x252C;
    pub const cross: u21 = 0x253C;

    pub const horizontal_dotted: u21 = 0x2504;
    pub const vertical_dotted: u21 = 0x2506;

    pub const horizontal_dashed: u21 = 0x2508;
    pub const vertical_dashed: u21 = 0x250A;

    pub const tee_down_double: u21 = 0x2565;

    pub const horizontal_thick: u21 = 0x2501;
    pub const vertical_thick: u21 = 0x2503;
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

pub const CrossingReductionHeuristic = enum {
    median,
    barycenter,
};

pub const ForceLayout = enum {
    auto,
    sugiyama,
    tree,
    force,

    pub fn displayName(self: ForceLayout) []const u8 {
        return switch (self) {
            .auto => "auto",
            .sugiyama => "sugiyama",
            .tree => "tree",
            .force => "force",
        };
    }

    pub fn next(self: ForceLayout) ForceLayout {
        return switch (self) {
            .auto => .sugiyama,
            .sugiyama => .tree,
            .tree => .force,
            .force => .auto,
        };
    }
};

pub const LayoutAlgorithm = enum {
    sugiyama,
    reingold_tilford,
    fruchterman_reingold,
    kamada_kawai,
    stress_majorization,
    dominance_drawing,
    layered_bfs,
    unknown,
};

pub const FitStage = enum {
    natural,
    label_wrap,
    direction_switch,
    spacing_compress,
    label_truncate,
    overflow,

    pub fn description(self: FitStage) []const u8 {
        return switch (self) {
            .natural => "natural fit",
            .label_wrap => "labels wrapped",
            .direction_switch => "direction switched",
            .spacing_compress => "spacing compressed",
            .label_truncate => "labels truncated",
            .overflow => "overflow (fallback)",
        };
    }
};

pub const RenderOptions = struct {
    max_width: u32 = 120,
    unicode_mode: bool = true,
    node_padding: u32 = 1,
    horizontal_spacing: u32 = 8,
    vertical_spacing: u32 = 3,
    max_label_width: ?u32 = null,
    crossing_reduction_heuristic: CrossingReductionHeuristic = .median,
    box_drawing_style: BoxDrawingStyle = .standard,
    force_layout: ForceLayout = .auto,
    subgraph_edges: @import("prim").SubgraphEdges = .bridge,
    aspect_ratio_x: f32 = 1.0,
    aspect_ratio_y: f32 = 1.0,
    debug_mermaid: bool = false,
};

pub const RenderResult = struct {
    output: []const u8,
    width: u32,
    height: u32,
    is_fallback: bool = false,
    fallback_reason: ?[]const u8 = null,
    algorithm_used: LayoutAlgorithm = .unknown,
    node_count: u32 = 0,
    edge_count: u32 = 0,
    is_tree: bool = false,
    is_cyclic: bool = false,
    width_constraint_triggered: bool = false,
    crossing_reduction_iterations: u32 = 0,
    fit_stage: FitStage = .natural,
    original_direction: ?Direction = null,
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
