const std = @import("std");
const config = @import("../../core/config.zig");
const markdown = @import("../../core/markdown.zig");
const render_model = @import("../../core/render_model.zig");
const mermaid_types = @import("../../core/mermaid/types.zig");
const SubgraphEdges = @import("prim").SubgraphEdges;
const Viewport = @import("../widgets/viewport.zig").Viewport;
const selection_mod = @import("../selection.zig");

/// Maps a footnote number to the rendered line indices of its reference and
/// definition.  Both fields are null until at least one line with the
/// corresponding pseudo-URL is found.
pub const FootnoteEntry = struct {
    ref_line: ?usize = null,
    def_line: ?usize = null,
};

pub const PagerView = struct {
    allocator: std.mem.Allocator,
    title: []const u8,
    document: *const markdown.Document,
    active_theme: config.Theme,
    syntax_theme: config.SyntaxTheme,
    theme_overrides: config.ThemeOverrides = .{},
    glyphs: render_model.Glyphs = .{},
    show_heading_markers: bool = true,
    mermaid_layout: mermaid_types.ForceLayout = .auto,
    /// Subgraph frame-border notation (config value; a later live toggle may
    /// mutate it, mirroring `mermaid_layout`).
    mermaid_subgraph_edges: SubgraphEdges = .bridge,
    viewport: Viewport = .{},
    width: usize = 0,
    lines: []render_model.Line = &.{},
    /// Footnote index: footnote number N maps to footnote_index[N-1].
    /// Rebuilt whenever lines are re-rendered.
    footnote_index: []FootnoteEntry = &.{},
    /// Active mouse text selection, in (document line, display column) space.
    selection: selection_mod.Selection = .{},

    pub fn init(allocator: std.mem.Allocator, title: []const u8, document: *const markdown.Document, active_theme: config.Theme, syntax_theme: config.SyntaxTheme, theme_overrides: config.ThemeOverrides, glyphs: render_model.Glyphs, show_heading_markers: bool, mermaid_layout: mermaid_types.ForceLayout, subgraph_edges: SubgraphEdges) PagerView {
        return .{
            .allocator = allocator,
            .title = title,
            .document = document,
            .active_theme = active_theme,
            .syntax_theme = syntax_theme,
            .theme_overrides = theme_overrides,
            .glyphs = glyphs,
            .show_heading_markers = show_heading_markers,
            .mermaid_layout = mermaid_layout,
            .mermaid_subgraph_edges = subgraph_edges,
        };
    }

    pub fn deinit(self: *PagerView) void {
        self.freeLines();
        self.allocator.free(self.footnote_index);
        self.footnote_index = &.{};
    }

    pub fn resize(self: *PagerView, width: usize, height: usize) !void {
        const changed = self.width != width;
        self.width = width;
        self.viewport.setMetrics(height, self.viewport.total);
        if (changed or self.lines.len == 0) {
            try self.reflow();
        }
    }

    pub fn lineDown(self: *PagerView) void {
        self.viewport.lineDown(1);
    }

    pub fn lineUp(self: *PagerView) void {
        self.viewport.lineUp(1);
    }

    pub fn pageDown(self: *PagerView) void {
        self.viewport.pageDown();
    }

    pub fn pageUp(self: *PagerView) void {
        self.viewport.pageUp();
    }

    pub fn toTop(self: *PagerView) void {
        self.viewport.toTop();
    }

    pub fn toBottom(self: *PagerView) void {
        self.viewport.toBottom();
    }

    /// If any line currently visible in the viewport contains a footnote
    /// navigation span (pseudo-URL `#fn:N` or `#fnref:N`), jump to the
    /// corresponding target line.  Returns true if a jump occurred.
    pub fn followFootnoteLink(self: *PagerView) bool {
        const visible_start = self.viewport.top;
        const visible_end = self.viewport.visibleEnd();
        var line_idx: usize = visible_start;
        while (line_idx < visible_end and line_idx < self.lines.len) : (line_idx += 1) {
            for (self.lines[line_idx].spans) |span| {
                if (span.url) |url| {
                    if (std.mem.startsWith(u8, url, "#fn:")) {
                        const num_str = url[4..];
                        const num = std.fmt.parseInt(usize, num_str, 10) catch continue;
                        if (num >= 1 and num <= self.footnote_index.len) {
                            if (self.footnote_index[num - 1].def_line) |target| {
                                self.viewport.top = @min(target, self.viewport.total -| self.viewport.height);
                                return true;
                            }
                        }
                    } else if (std.mem.startsWith(u8, url, "#fnref:")) {
                        const num_str = url[7..];
                        const num = std.fmt.parseInt(usize, num_str, 10) catch continue;
                        if (num >= 1 and num <= self.footnote_index.len) {
                            if (self.footnote_index[num - 1].ref_line) |target| {
                                self.viewport.top = @min(target, self.viewport.total -| self.viewport.height);
                                return true;
                            }
                        }
                    }
                }
            }
        }
        return false;
    }

    /// Begin a text selection anchored at visible screen `row` and display `col`.
    pub fn beginSelectionAt(self: *PagerView, row: usize, col: usize) void {
        self.selection.begin(self.viewport.lineForRow(row), col);
    }

    /// Extend the active selection to visible screen `row` and display `col`.
    pub fn extendSelectionAt(self: *PagerView, row: usize, col: usize) void {
        self.selection.extendTo(self.viewport.lineForRow(row), col);
    }

    pub fn clearSelection(self: *PagerView) void {
        self.selection.clear();
    }

    /// Allocate and return the currently selected text (empty if none).
    pub fn selectedText(self: *PagerView, allocator: std.mem.Allocator) ![]u8 {
        return self.selection.extractText(allocator, self.lines);
    }

    /// Display-column range to highlight on visible screen `row`, or null when
    /// that row falls outside the content or the selection.
    pub fn selectionRangeForRow(self: *PagerView, row: usize) ?selection_mod.Range {
        const line_idx = self.viewport.top + row;
        if (line_idx >= self.lines.len) return null;
        return self.selection.rangeForLine(line_idx, self.lines[line_idx].displayWidth());
    }

    pub fn reload(self: *PagerView) !void {
        try self.reflow();
    }

    fn reflow(self: *PagerView) !void {
        // Line indices change when the document is re-rendered, so any existing
        // selection no longer refers to the same text.
        self.selection.clear();
        self.freeLines();
        self.allocator.free(self.footnote_index);
        self.footnote_index = &.{};

        var rendered = try render_model.renderDocument(self.allocator, self.document.*, .{
            .width = if (self.width == 0) 80 else self.width,
            .show_heading_markers = self.show_heading_markers,
            .glyphs = self.glyphs,
            .mermaid_force_layout = self.mermaid_layout,
            .mermaid_subgraph_edges = self.mermaid_subgraph_edges,
        });
        self.lines = rendered.lines;
        rendered.lines = &.{};
        self.viewport.setMetrics(self.viewport.height, self.lines.len);

        // Build footnote index: scan all lines for #fn:N and #fnref:N pseudo-URLs.
        var index: std.ArrayList(FootnoteEntry) = .empty;
        errdefer index.deinit(self.allocator);

        for (self.lines, 0..) |line, li| {
            for (line.spans) |span| {
                const url = span.url orelse continue;
                if (std.mem.startsWith(u8, url, "#fn:")) {
                    const n = std.fmt.parseInt(usize, url[4..], 10) catch continue;
                    if (n == 0) continue;
                    // Grow index if needed.
                    while (index.items.len < n) try index.append(self.allocator, .{});
                    if (index.items[n - 1].ref_line == null) index.items[n - 1].ref_line = li;
                } else if (std.mem.startsWith(u8, url, "#fnref:")) {
                    const n = std.fmt.parseInt(usize, url[7..], 10) catch continue;
                    if (n == 0) continue;
                    while (index.items.len < n) try index.append(self.allocator, .{});
                    if (index.items[n - 1].def_line == null) index.items[n - 1].def_line = li;
                }
            }
        }
        self.footnote_index = try index.toOwnedSlice(self.allocator);
    }

    fn freeLines(self: *PagerView) void {
        for (self.lines) |line| line.deinit(self.allocator);
        self.allocator.free(self.lines);
        self.lines = &.{};
    }
};

test "builds footnote index from rendered lines" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\See note[^note] here.
        \\
        \\[^note]: The definition.
    );
    defer document.deinit(allocator);

    var pager = PagerView.init(allocator, "fixture", &document, .dark, .default, .{}, .{}, true, .auto, .bridge);
    defer pager.deinit();
    try pager.resize(80, 20);

    // Should have exactly one footnote entry.
    try std.testing.expectEqual(@as(usize, 1), pager.footnote_index.len);
    // Both ref and def lines must have been found.
    try std.testing.expect(pager.footnote_index[0].ref_line != null);
    try std.testing.expect(pager.footnote_index[0].def_line != null);
    // The ref line must come before the def line.
    try std.testing.expect(pager.footnote_index[0].ref_line.? < pager.footnote_index[0].def_line.?);
}

test "followFootnoteLink jumps to definition" {
    const allocator = std.testing.allocator;
    // Use a longer document so there are enough lines to scroll.
    var document = try markdown.parse(allocator,
        \\See note[^note] here.
        \\
        \\Line 1.
        \\Line 2.
        \\Line 3.
        \\Line 4.
        \\Line 5.
        \\Line 6.
        \\Line 7.
        \\Line 8.
        \\Line 9.
        \\Line 10.
        \\
        \\[^note]: The definition.
    );
    defer document.deinit(allocator);

    var pager = PagerView.init(allocator, "fixture", &document, .dark, .default, .{}, .{}, true, .auto, .bridge);
    defer pager.deinit();
    // Small viewport so we can actually scroll.
    try pager.resize(80, 3);

    // Start at top (ref is visible on line 0).
    pager.viewport.top = 0;
    const jumped = pager.followFootnoteLink();
    try std.testing.expect(jumped);
    // After jump, the def line should be at or near the top of the viewport.
    const def_line = pager.footnote_index[0].def_line.?;
    try std.testing.expect(pager.viewport.top <= def_line);
    try std.testing.expect(pager.viewport.top + pager.viewport.height > def_line);
}

test "selection maps screen rows to document text" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "Hello world foo bar");
    defer document.deinit(allocator);

    var pager = PagerView.init(allocator, "fixture", &document, .dark, .default, .{}, .{}, true, .auto, .bridge);
    defer pager.deinit();
    try pager.resize(80, 10);

    // Columns 0-1 are the left padding; select "Hello" (display columns 2..7).
    pager.beginSelectionAt(0, 2);
    pager.extendSelectionAt(0, 7);

    const text = try pager.selectedText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello", text);

    const range = pager.selectionRangeForRow(0).?;
    try std.testing.expectEqual(@as(usize, 2), range.start);
    try std.testing.expectEqual(@as(usize, 7), range.end);
}

test "clearing selection stops highlighting and copying" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "Hello world");
    defer document.deinit(allocator);

    var pager = PagerView.init(allocator, "fixture", &document, .dark, .default, .{}, .{}, true, .auto, .bridge);
    defer pager.deinit();
    try pager.resize(80, 10);

    pager.beginSelectionAt(0, 2);
    pager.extendSelectionAt(0, 7);
    pager.clearSelection();

    try std.testing.expect(pager.selectionRangeForRow(0) == null);
    const empty = try pager.selectedText(allocator);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "selection is cleared when the document reflows" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "Hello world foo bar baz qux");
    defer document.deinit(allocator);

    var pager = PagerView.init(allocator, "fixture", &document, .dark, .default, .{}, .{}, true, .auto, .bridge);
    defer pager.deinit();
    try pager.resize(80, 10);

    pager.beginSelectionAt(0, 2);
    pager.extendSelectionAt(0, 5);
    try std.testing.expect(pager.selection.active);

    // Reflow at a new width invalidates line indices, so the selection drops.
    try pager.resize(20, 10);
    try std.testing.expect(!pager.selection.active);
}

test "reflows rendered text into lines" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\# Title
        \\
        \\- one
        \\- two
    );
    defer document.deinit(allocator);

    var pager = PagerView.init(allocator, "fixture", &document, .dark, .default, .{}, .{}, true, .auto, .bridge);
    defer pager.deinit();
    try pager.resize(20, 5);

    try std.testing.expect(pager.lines.len >= 3);
    try std.testing.expect(pager.lines[0].spans.len >= 1);
}
