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

const std = @import("std");
const mermaid_types = @import("../mermaid/types.zig");
const unicode = @import("../../lib/unicode.zig");

pub const Options = struct {
    width: usize,
    left_padding: usize = 2,
    show_heading_markers: bool = true,
    mermaid_box_style: mermaid_types.BoxDrawingStyle = .standard,
    mermaid_crossing_heuristic: mermaid_types.CrossingReductionHeuristic = .median,
    mermaid_force_layout: mermaid_types.ForceLayout = .auto,
    mermaid_aspect_ratio: f32 = 1.0,
    mermaid_debug: bool = false,
    /// Subgraph frame-border notation (owner ruling 2026-07-19; bridge default).
    mermaid_subgraph_edges: @import("prim").SubgraphEdges = .bridge,
};

/// Semantic style tokens for styled text spans.
/// These represent the logical meaning of text (e.g., "this is a heading")
/// rather than presentational details (e.g., "this is bold blue").
/// The mapping to concrete colors is handled by theme.zig.
pub const SpanStyle = enum {
    heading1,
    heading2,
    heading3,
    heading4,
    heading5,
    heading6,
    body,
    muted,
    emphasis,
    strong,
    strong_emphasis,
    code,
    code_block,
    code_block_keyword,
    code_block_string,
    code_block_number,
    code_block_comment,
    code_keyword,
    code_string,
    code_number,
    code_comment,
    quote,
    link,
    strikethrough,
    image_alt,
    superscript,
    subscript,
    highlight,
};

/// A span of styled text. This is the shared abstraction used by both
/// CLI and TUI renderers. The CLI converts Span → ANSI escape sequences,
/// while the TUI converts Span → vaxis.Segment for terminal rendering.
pub const Span = struct {
    text: []const u8,
    style: SpanStyle,
    url: ?[]const u8 = null,
};

pub const Line = struct {
    spans: []Span,

    /// Total terminal display width of the line's rendered text.
    pub fn displayWidth(self: Line) usize {
        var width: usize = 0;
        for (self.spans) |span| width += unicode.displayWidth(span.text);
        return width;
    }

    pub fn deinit(self: Line, allocator: std.mem.Allocator) void {
        for (self.spans) |span| {
            allocator.free(span.text);
            if (span.url) |url| allocator.free(url);
        }
        allocator.free(self.spans);
    }
};

pub const Rendered = struct {
    lines: []Line,

    pub fn deinit(self: Rendered, allocator: std.mem.Allocator) void {
        for (self.lines) |line| line.deinit(allocator);
        allocator.free(self.lines);
    }
};

test "Line.displayWidth sums span display widths" {
    var spans = [_]Span{
        .{ .text = "ab", .style = .body },
        .{ .text = "日", .style = .body }, // 2 columns wide
    };
    const line = Line{ .spans = &spans };
    try std.testing.expectEqual(@as(usize, 4), line.displayWidth());
}
