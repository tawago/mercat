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
const config = @import("../config.zig");
const mermaid_types = @import("../mermaid/types.zig");
const unicode = @import("../../lib/unicode.zig");

/// Structural glyphs the block/table renderers stamp into the grid. Defaults are
/// the exact literals used before Issue 17, so an unpopulated Options renders
/// byte-identically. The renderer appends the trailing space after bullet and
/// checkbox markers, so these strings never include it.
pub const Glyphs = struct {
    // Single source of truth: derive every default from config.Display's own
    // defaults so the two structs cannot drift apart. The table triple defaults
    // from the default border set expanded to its concrete glyphs.
    const default_display = config.Config.Display{};
    const default_border = default_display.table_border_set.glyphs();

    quote_bar: []const u8 = default_display.quote_bar,
    bullet_glyphs: []const []const u8 = default_display.bullet_glyphs,
    hr_glyph: []const u8 = default_display.hr_glyph,
    task_checked: []const u8 = default_display.task_checked,
    task_todo: []const u8 = default_display.task_todo,
    heading_prefix: []const u8 = default_display.heading_prefix,
    table_horizontal: []const u8 = default_border.horizontal,
    table_vertical: []const u8 = default_border.vertical,
    table_cross: []const u8 = default_border.cross,

    /// Project a loaded `[display]` config onto the render-side glyph set,
    /// expanding the table_border_set enum into its concrete triple.
    pub fn fromDisplay(display: config.Config.Display) Glyphs {
        const border = display.table_border_set.glyphs();
        return .{
            .quote_bar = display.quote_bar,
            .bullet_glyphs = display.bullet_glyphs,
            .hr_glyph = display.hr_glyph,
            .task_checked = display.task_checked,
            .task_todo = display.task_todo,
            .heading_prefix = display.heading_prefix,
            .table_horizontal = border.horizontal,
            .table_vertical = border.vertical,
            .table_cross = border.cross,
        };
    }
};

pub const Options = struct {
    width: usize,
    left_padding: usize = 2,
    show_heading_markers: bool = true,
    glyphs: Glyphs = .{},
    /// YAML front matter display style (issue #9; panel default).
    frontmatter_style: config.FrontmatterStyle = .panel,
    /// True when the render model feeds a file exporter (plain/PNG) rather than
    /// an interactive terminal. The raw front-matter style keeps tabs byte-
    /// verbatim for the terminal, but the plain/PNG backends reject tab scalars,
    /// so raw content has its tabs expanded to spaces only on the export path.
    for_export: bool = false,
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
    // Structural slots (Issue 17 Layer 1b): each defaults to the token its
    // emit site borrowed before, so default output stays byte-identical.
    list_marker,
    table_border,
    table_header,
    task_checkbox_done,
    task_checkbox_todo,
    hr,
    code_fence_banner,
    frontmatter_key,
    frontmatter_value,
    frontmatter_cap,
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
