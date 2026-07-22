const std = @import("std");
const Allocator = std.mem.Allocator;

/// Supported diagram types
pub const DiagramType = enum {
    flowchart,
    sequence,
    class_diagram,
    state,
    er,
    unsupported,

    pub fn fromSource(source: []const u8) DiagramType {
        const trimmed = std.mem.trimLeft(u8, source, " \t\n\r");
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

/// Graph direction for flowcharts
pub const Direction = enum {
    LR, // Left to Right
    RL, // Right to Left
    TD, // Top Down (same as TB)
    TB, // Top to Bottom
    BT, // Bottom to Top

    pub fn isHorizontal(self: Direction) bool {
        return self == .LR or self == .RL;
    }

    pub fn isReversed(self: Direction) bool {
        return self == .RL or self == .BT;
    }
};

/// Node shapes supported in flowcharts
pub const NodeShape = enum {
    rectangle, // [text]
    rounded, // (text)
    stadium, // ([text])
    diamond, // {text}
    hexagon, // {{text}}
    parallelogram, // [/text/]
    parallelogram_alt, // [\text\]
    trapezoid, // [/text\]
    trapezoid_alt, // [\text/]
    cylinder, // [(text)]
    circle, // ((text))
    asymmetric, // >text]
    subroutine, // [[text]]

    /// Get box-drawing characters for this shape
    pub fn getBoxChars(self: NodeShape, unicode_mode: bool) BoxChars {
        if (!unicode_mode) return ascii_box;

        return switch (self) {
            .rectangle => unicode_square,
            .rounded => unicode_rounded,
            .stadium => unicode_stadium,
            .cylinder => unicode_cylinder,
            .circle => unicode_circle,
            .diamond => unicode_diamond,
            .hexagon => unicode_hexagon,
            .subroutine => unicode_subroutine,
            .asymmetric => unicode_asymmetric,
            .parallelogram, .parallelogram_alt, .trapezoid, .trapezoid_alt => unicode_square,
        };
    }

    /// Check if shape needs special rendering (not standard box)
    pub fn needsSpecialRendering(self: NodeShape) bool {
        return switch (self) {
            .diamond, .circle, .cylinder, .hexagon, .parallelogram, .parallelogram_alt, .trapezoid, .trapezoid_alt, .stadium, .subroutine, .asymmetric => true,
            else => false,
        };
    }
};

/// Edge line styles
pub const EdgeStyle = enum {
    solid, // ---
    dotted, // -.-
    thick, // ===
    dashed, // - - (for back-edges in cyclic graphs)
};

/// Arrow head styles
pub const ArrowHead = enum {
    arrow, // >
    open_arrow, // >
    circle, // o
    cross, // x
    none, // (no arrow)
};

/// A node in the graph
pub const Node = struct {
    id: []const u8,
    label: []const u8,
    shape: NodeShape = .rectangle,
    // Layout properties (assigned during layout phase)
    layer: ?u32 = null,
    order: ?u32 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    width: u32 = 0,
    height: u32 = 0,
    // Subgraph containment
    subgraph_id: ?[]const u8 = null,
    // For dummy nodes in long edges
    is_dummy: bool = false,
};

/// An edge connecting two nodes
pub const Edge = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8 = null,
    style: EdgeStyle = .solid,
    arrow_start: ArrowHead = .none,
    arrow_end: ArrowHead = .arrow,
    // Layout: is this edge reversed to break cycles?
    reversed: bool = false,
    // For edges that span multiple layers
    dummy_nodes: ?[][]const u8 = null,
    // True if 'from' is a subgraph ID (not a regular node).
    from_is_subgraph: bool = false,
    // True if 'to' is a subgraph ID (not a regular node).
    to_is_subgraph: bool = false,
};

/// A subgraph/cluster containing nodes
pub const Subgraph = struct {
    id: []const u8,
    label: ?[]const u8,
    parent_id: ?[]const u8 = null,
    node_ids: std.ArrayList([]const u8),
    allocator: Allocator,
    // Bounding box (calculated during layout)
    x: ?i32 = null,
    y: ?i32 = null,
    width: ?u32 = null,
    height: ?u32 = null,

    pub fn init(allocator: Allocator, id: []const u8, label: ?[]const u8, parent_id: ?[]const u8) Subgraph {
        return .{
            .id = id,
            .label = label,
            .parent_id = parent_id,
            .node_ids = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Subgraph) void {
        self.node_ids.deinit(self.allocator);
    }

    pub fn addNode(self: *Subgraph, node_id: []const u8) !void {
        try self.node_ids.append(self.allocator, node_id);
    }
};

/// The complete graph structure
pub const Graph = struct {
    allocator: Allocator,
    diagram_type: DiagramType,
    direction: Direction,
    nodes: std.StringHashMap(Node),
    edges: std.ArrayList(Edge),
    subgraphs: std.ArrayList(Subgraph),
    // Ordered list of node IDs for deterministic iteration
    node_order: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) Graph {
        return .{
            .allocator = allocator,
            .diagram_type = .flowchart,
            .direction = .TD,
            .nodes = std.StringHashMap(Node).init(allocator),
            .edges = .empty,
            .subgraphs = .empty,
            .node_order = .empty,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.nodes.deinit();
        self.edges.deinit(self.allocator);
        for (self.subgraphs.items) |*sg| {
            sg.deinit();
        }
        self.subgraphs.deinit(self.allocator);
        self.node_order.deinit(self.allocator);
    }

    pub fn addNode(self: *Graph, node: Node) !void {
        const result = try self.nodes.getOrPut(node.id);
        if (!result.found_existing) {
            result.value_ptr.* = node;
            try self.node_order.append(self.allocator, node.id);
        }
    }

    pub fn addEdge(self: *Graph, edge: Edge) !void {
        try self.edges.append(self.allocator, edge);
    }

    pub fn getNode(self: *const Graph, id: []const u8) ?*const Node {
        return self.nodes.getPtr(id);
    }

    pub fn getNodeMut(self: *Graph, id: []const u8) ?*Node {
        return self.nodes.getPtr(id);
    }

    pub fn addSubgraph(self: *Graph, subgraph: Subgraph) !void {
        try self.subgraphs.append(self.allocator, subgraph);
    }

    /// Get all nodes in a specific layer
    pub fn getNodesInLayer(self: *const Graph, allocator: Allocator, layer: u32, out: *std.ArrayList(*const Node)) !void {
        for (self.node_order.items) |id| {
            if (self.nodes.getPtr(id)) |node| {
                if (node.layer == layer) {
                    try out.append(allocator, node);
                }
            }
        }
    }

    /// Count the number of layers
    pub fn getLayerCount(self: *const Graph) u32 {
        var max_layer: u32 = 0;
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            if (node.layer) |l| {
                if (l > max_layer) max_layer = l;
            }
        }
        return max_layer + 1;
    }

    /// Get edges originating from a node
    pub fn getOutgoingEdges(self: *const Graph, allocator: Allocator, node_id: []const u8, out: *std.ArrayList(*const Edge)) !void {
        for (self.edges.items) |*edge| {
            const from = if (edge.reversed) edge.to else edge.from;
            if (std.mem.eql(u8, from, node_id)) {
                try out.append(allocator, edge);
            }
        }
    }

    /// Get edges pointing to a node
    pub fn getIncomingEdges(self: *const Graph, allocator: Allocator, node_id: []const u8, out: *std.ArrayList(*const Edge)) !void {
        for (self.edges.items) |*edge| {
            const to = if (edge.reversed) edge.from else edge.to;
            if (std.mem.eql(u8, to, node_id)) {
                try out.append(allocator, edge);
            }
        }
    }
};

// Box drawing character sets
pub const BoxChars = struct {
    top_left: u21,
    top_right: u21,
    bottom_left: u21,
    bottom_right: u21,
    horizontal: u21,
    vertical: u21,
};

pub const unicode_square: BoxChars = .{
    .top_left = 0x250C, // ┌
    .top_right = 0x2510, // ┐
    .bottom_left = 0x2514, // └
    .bottom_right = 0x2518, // ┘
    .horizontal = 0x2500, // ─
    .vertical = 0x2502, // │
};

pub const unicode_rounded: BoxChars = .{
    .top_left = 0x256D, // ╭
    .top_right = 0x256E, // ╮
    .bottom_left = 0x2570, // ╰
    .bottom_right = 0x256F, // ╯
    .horizontal = 0x2500, // ─
    .vertical = 0x2502, // │
};

pub const unicode_diamond: BoxChars = .{
    .top_left = 0x25C7, // ◇
    .top_right = 0x25C7, // ◇
    .bottom_left = 0x25C7, // ◇
    .bottom_right = 0x25C7, // ◇
    .horizontal = 0x2500, // ─
    .vertical = 0x2502, // │
};

// Stadium shape: uses rounded corners ╭╮╰╯
pub const unicode_stadium: BoxChars = .{
    .top_left = 0x256D, // ╭
    .top_right = 0x256E, // ╮
    .bottom_left = 0x2570, // ╰
    .bottom_right = 0x256F, // ╯
    .horizontal = 0x2500, // ─
    .vertical = 0x2502, // │
};

// Circle shape: ╱─╲ │ │ ╲─╱
pub const unicode_circle: BoxChars = .{
    .top_left = 0x2571, // ╱
    .top_right = 0x2572, // ╲
    .bottom_left = 0x2572, // ╲
    .bottom_right = 0x2571, // ╱
    .horizontal = 0x2500, // ─
    .vertical = 0x2502, // │
};

// Hexagon shape: ╱─╲ < > ╲─╱
pub const unicode_hexagon: BoxChars = .{
    .top_left = 0x2571, // ╱
    .top_right = 0x2572, // ╲
    .bottom_left = 0x2572, // ╲
    .bottom_right = 0x2571, // ╱
    .horizontal = 0x2500, // ─
    .vertical = 0x2502, // │ (< > used for sides)
};

// Cylinder shape: ╭═╮ │ │ ╰─╯
pub const unicode_cylinder: BoxChars = .{
    .top_left = 0x256D, // ╭
    .top_right = 0x256E, // ╮
    .bottom_left = 0x2570, // ╰
    .bottom_right = 0x256F, // ╯
    .horizontal = 0x2550, // ═ (for top)
    .vertical = 0x2502, // │
};

// Subroutine: ┌─┬─┬─┐ │ │ │ │ └─┴─┴─┘
pub const unicode_subroutine: BoxChars = .{
    .top_left = 0x250C, // ┌
    .top_right = 0x2510, // ┐
    .bottom_left = 0x2514, // └
    .bottom_right = 0x2518, // ┘
    .horizontal = 0x2500, // ─
    .vertical = 0x2502, // │
};

// Asymmetric (flag): right side uses >
pub const unicode_asymmetric: BoxChars = .{
    .top_left = 0x250C, // ┌
    .top_right = '>', // >
    .bottom_left = 0x2514, // └
    .bottom_right = '>', // >
    .horizontal = 0x2500, // ─
    .vertical = 0x2502, // │
};

pub const ascii_box: BoxChars = .{
    .top_left = '+',
    .top_right = '+',
    .bottom_left = '+',
    .bottom_right = '+',
    .horizontal = '-',
    .vertical = '|',
};

/// Box drawing style selection for ASCII-specific rendering
pub const BoxDrawingStyle = enum {
    standard, // ─ │ ┌ ┐ └ ┘
    rounded, // ╭ ╮ ╰ ╯ (rounded corners)
    heavy, // ━ ┃ ┏ ┓ ┗ ┛ (heavy/thick lines)
    double, // ═ ║ ╔ ╗ ╚ ╝ (double lines)
    ascii, // - | + (simple ASCII)

    /// Get BoxChars for this style
    pub fn getBoxChars(self: BoxDrawingStyle) BoxChars {
        return switch (self) {
            .standard => unicode_square,
            .rounded => unicode_rounded,
            .heavy => box_chars_heavy,
            .double => box_chars_double,
            .ascii => ascii_box,
        };
    }
};

/// Heavy box-drawing characters (━ ┃ ┏ ┓ ┗ ┛ ┣ ┫ ┳ ┻ ╋)
pub const box_chars_heavy: BoxChars = .{
    .top_left = 0x250F, // ┏
    .top_right = 0x2513, // ┓
    .bottom_left = 0x2517, // ┗
    .bottom_right = 0x251B, // ┛
    .horizontal = 0x2501, // ━
    .vertical = 0x2503, // ┃
};

/// Double box-drawing characters (═ ║ ╔ ╗ ╚ ╝ ╠ ╣ ╦ ╩ ╬)
pub const box_chars_double: BoxChars = .{
    .top_left = 0x2554, // ╔
    .top_right = 0x2557, // ╗
    .bottom_left = 0x255A, // ╚
    .bottom_right = 0x255D, // ╝
    .horizontal = 0x2550, // ═
    .vertical = 0x2551, // ║
};

// Arrow characters - use filled triangles for better visibility
pub const Arrows = struct {
    pub const right: u21 = 0x25B6; // ▶
    pub const left: u21 = 0x25C0; // ◀
    pub const up: u21 = 0x25B2; // ▲
    pub const down: u21 = 0x25BC; // ▼

    // Use filled triangles by default (more visible than thin arrows)
    pub const right_thin: u21 = 0x25BA; // ►
    pub const left_thin: u21 = 0x25C4; // ◄
    pub const up_thin: u21 = 0x25B2; // ▲
    pub const down_thin: u21 = 0x25BC; // ▼

    pub const right_ascii: u21 = '>';
    pub const left_ascii: u21 = '<';
    pub const up_ascii: u21 = '^';
    pub const down_ascii: u21 = 'v';
};

// T-junction characters for clean edge connections
pub const Junctions = struct {
    pub const tee_up: u21 = 0x2534; // ┴ - edge exits upward
    pub const tee_down: u21 = 0x252C; // ┬ - edge exits downward
    pub const tee_left: u21 = 0x2524; // ┤ - edge exits leftward
    pub const tee_right: u21 = 0x251C; // ├ - edge exits rightward
};

// Line characters for edges
pub const LineChars = struct {
    pub const horizontal: u21 = 0x2500; // ─
    pub const vertical: u21 = 0x2502; // │
    pub const corner_ne: u21 = 0x2514; // └
    pub const corner_nw: u21 = 0x2518; // ┘
    pub const corner_se: u21 = 0x250C; // ┌
    pub const corner_sw: u21 = 0x2510; // ┐
    pub const tee_left: u21 = 0x2524; // ┤
    pub const tee_right: u21 = 0x251C; // ├
    pub const tee_up: u21 = 0x2534; // ┴
    pub const tee_down: u21 = 0x252C; // ┬
    pub const cross: u21 = 0x253C; // ┼

    // Dotted variants (triple dash)
    pub const horizontal_dotted: u21 = 0x2504; // ┄
    pub const vertical_dotted: u21 = 0x2506; // ┆

    // Dashed variants (quadruple dash - visually distinct from dotted)
    pub const horizontal_dashed: u21 = 0x2508; // ┈
    pub const vertical_dashed: u21 = 0x250A; // ┊

    // Thick/double edge junction (down through horizontal): ╥
    pub const tee_down_double: u21 = 0x2565; // ╥

    // Thick variants
    pub const horizontal_thick: u21 = 0x2501; // ━
    pub const vertical_thick: u21 = 0x2503; // ┃
};

/// 2D point for coordinates
pub const Point = struct {
    x: i32,
    y: i32,

    pub fn eql(self: Point, other: Point) bool {
        return self.x == other.x and self.y == other.y;
    }
};

/// Bounding rectangle
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

/// Heuristic for crossing reduction in layered graph layout
pub const CrossingReductionHeuristic = enum {
    /// Median (default): O(n log n)/layer, 3-approx; good performance + stability
    median,
    /// Barycenter: O(n)/layer, O(√n)-approx; often better empirically, less stable
    barycenter,
};

/// Force a specific layout algorithm regardless of automatic selection
pub const ForceLayout = enum {
    /// Automatic selection (default): tree → force-directed → Sugiyama
    auto,
    /// Force Sugiyama layered layout (best for DAGs)
    sugiyama,
    /// Force Reingold-Tilford tree layout (best for trees)
    tree,
    /// Force force-directed layout (Kamada-Kawai for small graphs, Fruchterman-Reingold otherwise)
    force,

    /// Returns user-friendly name for status bar display
    pub fn displayName(self: ForceLayout) []const u8 {
        return switch (self) {
            .auto => "auto",
            .sugiyama => "sugiyama",
            .tree => "tree",
            .force => "force",
        };
    }

    /// Cycle to next layout algorithm
    pub fn next(self: ForceLayout) ForceLayout {
        return switch (self) {
            .auto => .sugiyama,
            .sugiyama => .tree,
            .tree => .force,
            .force => .auto,
        };
    }
};

/// Render options
/// Which layout algorithm was actually selected during rendering
pub const LayoutAlgorithm = enum {
    sugiyama,
    reingold_tilford,
    fruchterman_reingold,
    kamada_kawai,
    stress_majorization,
    dominance_drawing,
    layered_bfs, // used by state diagrams
    unknown,

    /// Returns true if this algorithm produces layered output directly
    pub fn isLayered(self: LayoutAlgorithm) bool {
        return switch (self) {
            .sugiyama, .reingold_tilford, .layered_bfs => true,
            .fruchterman_reingold, .kamada_kawai, .stress_majorization, .dominance_drawing, .unknown => false,
        };
    }
};

/// Stages of width fitting, in escalation order
/// Each stage attempts to fit the diagram within max_width
pub const FitStage = enum {
    natural, // No fitting needed - natural layout fits
    label_wrap, // Wrapped labels to 2 lines
    direction_switch, // Switched layout direction (TD ↔ LR)
    spacing_compress, // Compressed spacing to minimum
    label_truncate, // Truncated labels with ellipsis
    overflow, // Could not fit - fallback required

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

/// Normalized node layout information for downstream stages
/// This provides a consistent interface regardless of which layout algorithm was used
pub const LayoutNode = struct {
    id: []const u8,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    layer: ?u32 = null, // Assigned by layered algorithms or inferred from coordinates
    order: ?u32 = null, // Position within layer
};

/// Normalized layout result produced by all flowchart layout algorithms
/// This is the contract between layout and downstream stages (routing, compaction, canvas)
pub const LayoutResult = struct {
    allocator: Allocator,

    /// Final node coordinates for all non-dummy nodes
    nodes: std.ArrayList(LayoutNode),

    /// Layer structure - non-null for layered algorithms, inferred for free-placement
    /// Each inner slice contains node indices in order within that layer
    layers: ?[][]usize = null,

    /// Indices into the original edge list for edges that were reversed during cycle breaking
    /// These should be rendered as dashed back-edges
    back_edges: std.ArrayList(usize),

    /// Metadata about the layout process
    algorithm_used: LayoutAlgorithm = .unknown,
    is_tree: bool = false,
    is_cyclic: bool = false,
    crossing_reduction_iterations: u32 = 0,

    /// Width fitting metadata
    fit_stage: FitStage = .natural,
    original_direction: ?Direction = null, // Set if direction was switched
    natural_width: u32 = 0, // Width before any fitting
    final_width: u32 = 0, // Width after fitting

    pub fn init(allocator: Allocator) LayoutResult {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .back_edges = .empty,
        };
    }

    pub fn deinit(self: *LayoutResult) void {
        self.nodes.deinit(self.allocator);
        self.back_edges.deinit(self.allocator);
        if (self.layers) |layers| {
            for (layers) |layer| {
                self.allocator.free(layer);
            }
            self.allocator.free(layers);
        }
    }

    /// Add a node to the layout result
    pub fn addNode(self: *LayoutResult, node: LayoutNode) !void {
        try self.nodes.append(self.allocator, node);
    }

    /// Record a back-edge (reversed during cycle breaking)
    pub fn addBackEdge(self: *LayoutResult, edge_index: usize) !void {
        try self.back_edges.append(self.allocator, edge_index);
    }

    /// Get a node by ID
    pub fn getNode(self: *const LayoutResult, id: []const u8) ?*const LayoutNode {
        for (self.nodes.items) |*node| {
            if (std.mem.eql(u8, node.id, id)) {
                return node;
            }
        }
        return null;
    }
};

pub const RenderOptions = struct {
    max_width: u32 = 120,
    unicode_mode: bool = true,
    node_padding: u32 = 1,
    horizontal_spacing: u32 = 8, // Increased for labels
    vertical_spacing: u32 = 3, // Space for: line with label, line, arrow
    max_label_width: ?u32 = null,
    /// Crossing reduction heuristic (default: median)
    crossing_reduction_heuristic: CrossingReductionHeuristic = .median,
    /// Box drawing style (standard, rounded, heavy, double, ascii)
    box_drawing_style: BoxDrawingStyle = .standard,
    /// Force a specific layout algorithm (default: auto)
    force_layout: ForceLayout = .auto,
    /// Subgraph frame-border notation (owner ruling 2026-07-19; bridge default)
    subgraph_edges: @import("prim").SubgraphEdges = .bridge,
    /// Aspect ratio correction for terminal cells (visual_x = grid_x * aspect_ratio_x)
    aspect_ratio_x: f32 = 1.0, // Set to 2.0 for typical 2:1 terminal cell aspect ratio
    aspect_ratio_y: f32 = 1.0,
    /// Emit debug block showing layout decisions
    debug_mermaid: bool = false,
};

pub const CompactionLevel = enum {
    default,
    reduced,
    tight,
    direction_switch,
    multiline,
};

pub const CompactionHints = struct {
    level: CompactionLevel,
    render_options: RenderOptions,
    sequence_participant_spacing: u32 = 8,
    sequence_padding: u32 = 2,
    sequence_direction: ?Direction = null,
};

/// Result of rendering
pub const RenderResult = struct {
    output: []const u8,
    width: u32,
    height: u32,
    is_fallback: bool = false,
    fallback_reason: ?[]const u8 = null,
    /// Which layout algorithm was used (set by layout phase)
    algorithm_used: LayoutAlgorithm = .unknown,
    /// Number of nodes in the graph (0 for non-flowchart types)
    node_count: u32 = 0,
    /// Number of edges in the graph (0 for non-flowchart types)
    edge_count: u32 = 0,
    /// Whether the graph was detected as a tree
    is_tree: bool = false,
    /// Whether the graph contains cycles
    is_cyclic: bool = false,
    /// Whether width constraint triggered compaction
    width_constraint_triggered: bool = false,
    /// Crossing reduction iterations used (Sugiyama only)
    crossing_reduction_iterations: u32 = 0,
    /// Which width fitting stage succeeded
    fit_stage: FitStage = .natural,
    /// Original direction if switched for width fitting
    original_direction: ?Direction = null,
};

// =====================================================
// Sequence Diagram Types
// =====================================================

/// Arrow types for sequence diagram messages
pub const SequenceArrowType = enum {
    solid_arrow, // ->>  solid line with arrowhead
    solid_line, // --   solid line without arrowhead
    dashed_arrow, // -->> dashed line with arrowhead
    dashed_line, // --   dashed line without arrowhead
    solid_cross, // -x   solid line with cross
    dashed_cross, // --x  dashed line with cross
    solid_open, // -)   solid line with open arrow
    dashed_open, // --)  dashed line with open arrow

    pub fn isDashed(self: SequenceArrowType) bool {
        return switch (self) {
            .dashed_arrow, .dashed_line, .dashed_cross, .dashed_open => true,
            else => false,
        };
    }

    pub fn hasArrowhead(self: SequenceArrowType) bool {
        return switch (self) {
            .solid_arrow, .dashed_arrow, .solid_open, .dashed_open => true,
            else => false,
        };
    }
};

/// A participant in a sequence diagram
pub const Participant = struct {
    id: []const u8,
    alias: ?[]const u8 = null, // Display name if different from id
    participant_type: ParticipantType = .participant,
    // Layout properties
    x: ?i32 = null,
    y: ?i32 = null,
    box_width: u32 = 0,

    pub fn displayName(self: *const Participant) []const u8 {
        return self.alias orelse self.id;
    }
};

/// Type of participant (affects rendering style)
pub const ParticipantType = enum {
    participant, // Default box
    actor, // Stick figure
};

/// A message between participants
pub const Message = struct {
    from: []const u8,
    to: []const u8,
    text: []const u8,
    arrow_type: SequenceArrowType = .solid_arrow,
    // For self-messages (from == to)
    is_self_message: bool = false,
};

/// A note in a sequence diagram
pub const SequenceNote = struct {
    position: NotePosition,
    participant1: []const u8, // Primary participant
    participant2: ?[]const u8 = null, // Second participant for "over A,B"
    text: []const u8,
};

pub const NotePosition = enum {
    left_of,
    right_of,
    over,
};

/// Activation state change
pub const Activation = struct {
    participant: []const u8,
    is_activate: bool, // true = activate, false = deactivate
};

/// A sequence element that can be a message, note, or activation, preserving order
pub const SequenceElement = union(enum) {
    message: Message,
    note: SequenceNote,
    activation: Activation,
};

/// Complete sequence diagram structure
pub const SequenceDiagram = struct {
    allocator: Allocator,
    participants: std.ArrayList(Participant),
    messages: std.ArrayList(Message),
    notes: std.ArrayList(SequenceNote),
    elements: std.ArrayList(SequenceElement), // Ordered list of all elements
    direction: Direction = .TB,
    direction_explicit: bool = false,
    // Auto-numbered messages
    auto_number: bool = false,

    pub fn init(allocator: Allocator) SequenceDiagram {
        return .{
            .allocator = allocator,
            .participants = .empty,
            .messages = .empty,
            .notes = .empty,
            .elements = .empty,
        };
    }

    pub fn deinit(self: *SequenceDiagram) void {
        self.participants.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.notes.deinit(self.allocator);
        self.elements.deinit(self.allocator);
    }

    pub fn addParticipant(self: *SequenceDiagram, participant: Participant) !void {
        // Check if participant already exists
        for (self.participants.items) |p| {
            if (std.mem.eql(u8, p.id, participant.id)) {
                return; // Already exists
            }
        }
        try self.participants.append(self.allocator, participant);
    }

    pub fn addMessage(self: *SequenceDiagram, message: Message) !void {
        try self.messages.append(self.allocator, message);
        try self.elements.append(self.allocator, .{ .message = message });
    }

    pub fn addNote(self: *SequenceDiagram, note: SequenceNote) !void {
        try self.notes.append(self.allocator, note);
        try self.elements.append(self.allocator, .{ .note = note });
    }

    pub fn addActivation(self: *SequenceDiagram, activation: Activation) !void {
        try self.elements.append(self.allocator, .{ .activation = activation });
    }

    pub fn getParticipant(self: *const SequenceDiagram, id: []const u8) ?*const Participant {
        for (self.participants.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) {
                return p;
            }
        }
        return null;
    }

    pub fn getParticipantMut(self: *SequenceDiagram, id: []const u8) ?*Participant {
        for (self.participants.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) {
                return p;
            }
        }
        return null;
    }

    pub fn getParticipantIndex(self: *const SequenceDiagram, id: []const u8) ?usize {
        for (self.participants.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.id, id)) {
                return i;
            }
        }
        return null;
    }
};

// =====================================================
// Class Diagram Types
// =====================================================

/// Visibility modifier for class members
pub const Visibility = enum {
    public, // +
    private, // -
    protected, // #
    package, // ~
    none,

    pub fn toChar(self: Visibility) ?u8 {
        return switch (self) {
            .public => '+',
            .private => '-',
            .protected => '#',
            .package => '~',
            .none => null,
        };
    }

    pub fn fromChar(c: u8) Visibility {
        return switch (c) {
            '+' => .public,
            '-' => .private,
            '#' => .protected,
            '~' => .package,
            else => .none,
        };
    }
};

/// A member (attribute or method) of a class
pub const ClassMember = struct {
    name: []const u8,
    member_type: []const u8, // e.g., "int", "String", return type for methods
    visibility: Visibility = .none,
    is_method: bool = false,
    is_static: bool = false,
    is_abstract: bool = false,
};

/// Relationship types between classes
pub const ClassRelationType = enum {
    inheritance, // <|-- (extends)
    composition, // *-- (has, owns)
    aggregation, // o-- (has)
    association, // --> (uses)
    dependency, // ..> (depends on)
    realization, // ..|> (implements)
    link, // -- (link)

    pub fn getArrowChars(self: ClassRelationType, unicode_mode: bool) struct { start: []const u8, end: []const u8, line: u21 } {
        if (!unicode_mode) {
            return switch (self) {
                .inheritance => .{ .start = "", .end = "<|", .line = '-' },
                .composition => .{ .start = "*", .end = "", .line = '-' },
                .aggregation => .{ .start = "o", .end = "", .line = '-' },
                .association => .{ .start = "", .end = ">", .line = '-' },
                .dependency => .{ .start = "", .end = ">", .line = '.' },
                .realization => .{ .start = "", .end = "|>", .line = '.' },
                .link => .{ .start = "", .end = "", .line = '-' },
            };
        }
        return switch (self) {
            .inheritance => .{ .start = "", .end = "◁", .line = 0x2500 }, // ─
            .composition => .{ .start = "◆", .end = "", .line = 0x2500 },
            .aggregation => .{ .start = "◇", .end = "", .line = 0x2500 },
            .association => .{ .start = "", .end = "▶", .line = 0x2500 },
            .dependency => .{ .start = "", .end = "▶", .line = 0x2504 }, // ┄
            .realization => .{ .start = "", .end = "◁", .line = 0x2504 },
            .link => .{ .start = "", .end = "", .line = 0x2500 },
        };
    }
};

/// A class in the diagram
pub const Class = struct {
    name: []const u8,
    members: std.ArrayList(ClassMember),
    allocator: Allocator,
    // Layout properties
    x: ?i32 = null,
    y: ?i32 = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(allocator: Allocator, name: []const u8) Class {
        return .{
            .name = name,
            .members = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Class) void {
        self.members.deinit(self.allocator);
    }

    pub fn addMember(self: *Class, member: ClassMember) !void {
        try self.members.append(self.allocator, member);
    }

    /// Get attributes (non-method members)
    pub fn getAttributes(self: *const Class) []const ClassMember {
        var count: usize = 0;
        for (self.members.items) |m| {
            if (!m.is_method) count += 1;
        }
        // Note: This returns the full slice; caller filters
        return self.members.items;
    }

    /// Get methods
    pub fn getMethods(self: *const Class) []const ClassMember {
        return self.members.items;
    }
};

/// A relationship between two classes
pub const ClassRelation = struct {
    from: []const u8,
    to: []const u8,
    relation_type: ClassRelationType = .association,
    label: ?[]const u8 = null,
    from_cardinality: ?[]const u8 = null,
    to_cardinality: ?[]const u8 = null,
};

/// Complete class diagram structure
pub const ClassDiagram = struct {
    allocator: Allocator,
    classes: std.StringHashMap(Class),
    relations: std.ArrayList(ClassRelation),
    class_order: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) ClassDiagram {
        return .{
            .allocator = allocator,
            .classes = std.StringHashMap(Class).init(allocator),
            .relations = .empty,
            .class_order = .empty,
        };
    }

    pub fn deinit(self: *ClassDiagram) void {
        var it = self.classes.valueIterator();
        while (it.next()) |class| {
            @constCast(class).deinit();
        }
        self.classes.deinit();
        self.relations.deinit(self.allocator);
        self.class_order.deinit(self.allocator);
    }

    pub fn addClass(self: *ClassDiagram, class: Class) !void {
        const result = try self.classes.getOrPut(class.name);
        if (!result.found_existing) {
            result.value_ptr.* = class;
            try self.class_order.append(self.allocator, class.name);
        }
    }

    pub fn getClass(self: *const ClassDiagram, name: []const u8) ?*const Class {
        return self.classes.getPtr(name);
    }

    pub fn getClassMut(self: *ClassDiagram, name: []const u8) ?*Class {
        return self.classes.getPtr(name);
    }

    pub fn addRelation(self: *ClassDiagram, relation: ClassRelation) !void {
        try self.relations.append(self.allocator, relation);
    }
};

// =====================================================
// ER Diagram Types
// =====================================================

/// Cardinality for ER relationships
pub const Cardinality = enum {
    zero_or_one, // |o or o|
    exactly_one, // ||
    zero_or_more, // }o or o{
    one_or_more, // }| or |{

    pub fn toStringLeft(self: Cardinality, unicode_mode: bool) []const u8 {
        _ = unicode_mode;
        return switch (self) {
            .zero_or_one => "o|",
            .exactly_one => "||",
            .zero_or_more => "}o",
            .one_or_more => "}|",
        };
    }

    pub fn toStringRight(self: Cardinality, unicode_mode: bool) []const u8 {
        _ = unicode_mode;
        return switch (self) {
            .zero_or_one => "|o",
            .exactly_one => "||",
            .zero_or_more => "o{",
            .one_or_more => "|{",
        };
    }
};

/// An entity in the ER diagram
pub const Entity = struct {
    name: []const u8,
    attributes: std.ArrayList(EntityAttribute),
    allocator: Allocator,
    // Layout properties
    x: ?i32 = null,
    y: ?i32 = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(allocator: Allocator, name: []const u8) Entity {
        return .{
            .name = name,
            .attributes = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Entity) void {
        self.attributes.deinit(self.allocator);
    }

    pub fn addAttribute(self: *Entity, attr: EntityAttribute) !void {
        try self.attributes.append(self.allocator, attr);
    }
};

/// An attribute of an entity
pub const EntityAttribute = struct {
    name: []const u8,
    attr_type: []const u8,
    is_primary_key: bool = false,
    is_foreign_key: bool = false,
};

/// A relationship between entities
pub const ERRelation = struct {
    from: []const u8,
    to: []const u8,
    from_cardinality: Cardinality = .exactly_one,
    to_cardinality: Cardinality = .exactly_one,
    label: ?[]const u8 = null,
};

/// Complete ER diagram structure
pub const ERDiagram = struct {
    allocator: Allocator,
    entities: std.StringHashMap(Entity),
    relations: std.ArrayList(ERRelation),
    entity_order: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) ERDiagram {
        return .{
            .allocator = allocator,
            .entities = std.StringHashMap(Entity).init(allocator),
            .relations = .empty,
            .entity_order = .empty,
        };
    }

    pub fn deinit(self: *ERDiagram) void {
        var it = self.entities.valueIterator();
        while (it.next()) |entity| {
            @constCast(entity).deinit();
        }
        self.entities.deinit();
        self.relations.deinit(self.allocator);
        self.entity_order.deinit(self.allocator);
    }

    pub fn addEntity(self: *ERDiagram, entity: Entity) !void {
        const result = try self.entities.getOrPut(entity.name);
        if (!result.found_existing) {
            result.value_ptr.* = entity;
            try self.entity_order.append(self.allocator, entity.name);
        }
    }

    pub fn getEntity(self: *const ERDiagram, name: []const u8) ?*const Entity {
        return self.entities.getPtr(name);
    }

    pub fn getEntityMut(self: *ERDiagram, name: []const u8) ?*Entity {
        return self.entities.getPtr(name);
    }

    pub fn addRelation(self: *ERDiagram, relation: ERRelation) !void {
        try self.relations.append(self.allocator, relation);
    }
};

// =====================================================
// State Diagram Types
// =====================================================

/// Type of state in a state diagram
pub const StateType = enum {
    start, // [*] as source - filled circle
    end, // [*] as target - circled dot
    regular, // Normal state box
    choice, // <<choice>> - diamond
    fork, // <<fork>> - horizontal bar
    join, // <<join>> - horizontal bar
    composite, // State containing other states

    pub fn isSpecial(self: StateType) bool {
        return self == .start or self == .end or self == .choice or self == .fork or self == .join;
    }
};

/// A state in a state diagram
pub const State = struct {
    id: []const u8,
    label: ?[]const u8 = null, // Description after ":"
    state_type: StateType = .regular,
    // For composite states
    is_composite: bool = false,
    parent_id: ?[]const u8 = null, // ID of containing composite state
    // Layout properties
    x: ?i32 = null,
    y: ?i32 = null,
    width: u32 = 0,
    height: u32 = 0,
    layer: ?u32 = null, // For layered layout

    pub fn displayName(self: *const State) []const u8 {
        if (self.state_type == .start) return "[*]";
        if (self.state_type == .end) return "[*]";
        return self.label orelse self.id;
    }

    pub fn isStartOrEnd(self: *const State) bool {
        return self.state_type == .start or self.state_type == .end;
    }
};

/// A transition between states
pub const StateTransition = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8 = null, // Transition label after ":"
};

/// A note attached to a state
pub const StateNote = struct {
    state_id: []const u8,
    text: []const u8,
    position: NotePosition = .right_of,
};

/// Complete state diagram structure
pub const StateDiagram = struct {
    allocator: Allocator,
    states: std.StringHashMap(State),
    transitions: std.ArrayList(StateTransition),
    notes: std.ArrayList(StateNote),
    state_order: std.ArrayList([]const u8), // Ordered list for deterministic iteration
    // Allocated strings that need to be freed (e.g., generated start/end IDs)
    allocated_ids: std.ArrayList([]const u8),
    // Direction (default is top-down)
    direction: Direction = .TD,

    pub fn init(allocator: Allocator) StateDiagram {
        return .{
            .allocator = allocator,
            .states = std.StringHashMap(State).init(allocator),
            .transitions = .empty,
            .notes = .empty,
            .state_order = .empty,
            .allocated_ids = .empty,
        };
    }

    pub fn deinit(self: *StateDiagram) void {
        // Free allocated IDs
        for (self.allocated_ids.items) |id| {
            self.allocator.free(id);
        }
        self.allocated_ids.deinit(self.allocator);
        self.states.deinit();
        self.transitions.deinit(self.allocator);
        self.notes.deinit(self.allocator);
        self.state_order.deinit(self.allocator);
    }

    /// Track an allocated ID for cleanup
    pub fn trackAllocatedId(self: *StateDiagram, id: []const u8) !void {
        try self.allocated_ids.append(self.allocator, id);
    }

    pub fn addState(self: *StateDiagram, state: State) !void {
        const result = try self.states.getOrPut(state.id);
        if (!result.found_existing) {
            result.value_ptr.* = state;
            try self.state_order.append(self.allocator, state.id);
        } else {
            // Update existing state if it has more info (e.g., label added later)
            if (state.label != null and result.value_ptr.label == null) {
                result.value_ptr.label = state.label;
            }
            if (state.is_composite) {
                result.value_ptr.is_composite = true;
            }
            if (state.state_type != .regular and result.value_ptr.state_type == .regular) {
                result.value_ptr.state_type = state.state_type;
            }
        }
    }

    pub fn addTransition(self: *StateDiagram, transition: StateTransition) !void {
        try self.transitions.append(self.allocator, transition);
    }

    pub fn addNote(self: *StateDiagram, note: StateNote) !void {
        try self.notes.append(self.allocator, note);
    }

    pub fn getState(self: *const StateDiagram, id: []const u8) ?*const State {
        return self.states.getPtr(id);
    }

    pub fn getStateMut(self: *StateDiagram, id: []const u8) ?*State {
        return self.states.getPtr(id);
    }

    /// Get all states in a composite state
    pub fn getChildStates(self: *const StateDiagram, allocator: Allocator, parent_id: []const u8, out: *std.ArrayList(*const State)) !void {
        for (self.state_order.items) |id| {
            if (self.states.getPtr(id)) |state| {
                if (state.parent_id) |pid| {
                    if (std.mem.eql(u8, pid, parent_id)) {
                        try out.append(allocator, state);
                    }
                }
            }
        }
    }

    /// Get states at the top level (not inside any composite)
    pub fn getTopLevelStates(self: *const StateDiagram, allocator: Allocator, out: *std.ArrayList(*const State)) !void {
        for (self.state_order.items) |id| {
            if (self.states.getPtr(id)) |state| {
                if (state.parent_id == null) {
                    try out.append(allocator, state);
                }
            }
        }
    }

    /// Find start states (states with [*] --> transitions pointing to them)
    pub fn findStartStates(self: *const StateDiagram, allocator: Allocator, parent_id: ?[]const u8, out: *std.ArrayList([]const u8)) !void {
        for (self.state_order.items) |id| {
            if (self.states.getPtr(id)) |state| {
                if (state.state_type == .start) {
                    // Check if this start state is in the right scope
                    const in_scope = if (parent_id) |pid|
                        (state.parent_id != null and std.mem.eql(u8, state.parent_id.?, pid))
                    else
                        state.parent_id == null;

                    if (in_scope) {
                        try out.append(allocator, id);
                    }
                }
            }
        }
    }

    /// Find end states
    pub fn findEndStates(self: *const StateDiagram, allocator: Allocator, parent_id: ?[]const u8, out: *std.ArrayList([]const u8)) !void {
        for (self.state_order.items) |id| {
            if (self.states.getPtr(id)) |state| {
                if (state.state_type == .end) {
                    const in_scope = if (parent_id) |pid|
                        (state.parent_id != null and std.mem.eql(u8, state.parent_id.?, pid))
                    else
                        state.parent_id == null;

                    if (in_scope) {
                        try out.append(allocator, id);
                    }
                }
            }
        }
    }

    /// Count the number of layers (for layout)
    pub fn getLayerCount(self: *const StateDiagram) u32 {
        var max_layer: u32 = 0;
        var it = self.states.valueIterator();
        while (it.next()) |state| {
            if (state.layer) |l| {
                if (l > max_layer) max_layer = l;
            }
        }
        return max_layer + 1;
    }
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

test "StateDiagram basic operations" {
    const testing = std.testing;
    var diagram = StateDiagram.init(testing.allocator);
    defer diagram.deinit();

    // Add states
    try diagram.addState(.{ .id = "s1", .label = "State 1" });
    try diagram.addState(.{ .id = "s2", .label = "State 2" });
    try diagram.addState(.{ .id = "[*]_start", .state_type = .start });
    try diagram.addState(.{ .id = "[*]_end", .state_type = .end });

    // Add transitions
    try diagram.addTransition(.{ .from = "[*]_start", .to = "s1" });
    try diagram.addTransition(.{ .from = "s1", .to = "s2", .label = "go" });
    try diagram.addTransition(.{ .from = "s2", .to = "[*]_end" });

    try testing.expect(diagram.getState("s1") != null);
    try testing.expect(diagram.getState("s2") != null);
    try testing.expect(diagram.getState("s3") == null);
    try testing.expectEqual(@as(usize, 3), diagram.transitions.items.len);
    try testing.expectEqual(@as(usize, 4), diagram.state_order.items.len);
}

test "Graph basic operations" {
    const testing = std.testing;
    var graph = Graph.init(testing.allocator);
    defer graph.deinit();

    try graph.addNode(.{ .id = "A", .label = "Start" });
    try graph.addNode(.{ .id = "B", .label = "End" });
    try graph.addEdge(.{ .from = "A", .to = "B" });

    try testing.expect(graph.getNode("A") != null);
    try testing.expect(graph.getNode("B") != null);
    try testing.expect(graph.getNode("C") == null);
    try testing.expectEqual(@as(usize, 1), graph.edges.items.len);
}
