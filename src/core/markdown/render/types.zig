const config = @import("../../config.zig");
const mermaid_types = @import("../../mermaid/types.zig");
const decor_mod = @import("decor.zig");
const line = @import("line.zig");

pub const Options = struct {
    width: usize,
    left_padding: usize = 2,
    show_heading_markers: bool = true,
    decor: *const decor_mod.Decor = &decor_mod.legacy,
    frontmatter_style: config.FrontmatterStyle = .panel,
    mermaid_box_style: mermaid_types.BoxDrawingStyle = .standard,
    mermaid_crossing_heuristic: mermaid_types.CrossingReductionHeuristic = .median,
    mermaid_force_layout: mermaid_types.ForceLayout = .auto,
    mermaid_aspect_ratio: f32 = 1.0,
    mermaid_debug: bool = false,
    mermaid_subgraph_edges: @import("prim").SubgraphEdges = .bridge,
};

pub const SpanStyle = line.SpanStyle;
pub const Span = line.Span;
pub const Line = line.Line;
pub const Rendered = line.Rendered;
