//! Shared Styled Text Abstraction
//!
//! This module defines the common styled text types used by both CLI and TUI renderers.
//! The rendering pipeline is:
//!
//!   1. markdown.parse() → Document (AST)
//!   2. render_model.renderDocument() → Rendered ([]Line of []Span)
//!   3a. CLI: theme.token() → StyleToken → ansi.writeTokenStyled() → ANSI codes
//!   3b. TUI: theme.token() → StyleToken → theme.vaxisStyle() → vaxis.Style
//!
//! `SpanStyle` is semantic (heading, code, link) rather than presentational (blue, bold).
//! The mapping to concrete colors is handled by theme.zig based on dark/light mode.

const config = @import("../../config.zig");
const mermaid_types = @import("../../mermaid/types.zig");
const decor_mod = @import("decor.zig");
const line = @import("line.zig");

pub const Options = struct {
    width: usize,
    left_padding: usize = 2,
    show_heading_markers: bool = true,
    /// Structural decoration vocabulary (prefixes/glyphs/frames). Defaults to
    /// `decor.legacy`, which reproduces the historical hardcoded literals so
    /// every un-themed render path stays byte-identical.
    decor: *const decor_mod.Decor = &decor_mod.legacy,
    /// YAML front matter display style (issue #9; panel default).
    frontmatter_style: config.FrontmatterStyle = .panel,
    mermaid_box_style: mermaid_types.BoxDrawingStyle = .standard,
    mermaid_crossing_heuristic: mermaid_types.CrossingReductionHeuristic = .median,
    mermaid_force_layout: mermaid_types.ForceLayout = .auto,
    mermaid_aspect_ratio: f32 = 1.0,
    mermaid_debug: bool = false,
    /// Subgraph frame-border notation (owner ruling 2026-07-19; bridge default).
    mermaid_subgraph_edges: @import("prim").SubgraphEdges = .bridge,
};

pub const SpanStyle = line.SpanStyle;
pub const Span = line.Span;
pub const Line = line.Line;
pub const Rendered = line.Rendered;
