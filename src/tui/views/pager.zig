const std = @import("std");
const config = @import("../../core/config.zig");
const markdown = @import("../../core/markdown/parser.zig");
const render_model = @import("../../core/markdown/render.zig");
const resolveMod = @import("../../core/theme/resolve.zig");
const ResolvedTheme = resolveMod.ResolvedTheme;
const theme_color = @import("../../core/theme/color.zig");
const mermaid_types = @import("../../core/mermaid/types.zig");
const SubgraphEdges = @import("prim").SubgraphEdges;
const Viewport = @import("../widgets/viewport.zig").Viewport;
const selection_mod = @import("../selection.zig");

pub const FootnoteEntry = struct {
    ref_line: ?usize = null,
    def_line: ?usize = null,
};

pub const PagerView = struct {
    allocator: std.mem.Allocator,
    title: []const u8,
    document: *const markdown.Document,
    resolved: *const ResolvedTheme,
    show_heading_markers: bool = true,
    frontmatter_style: config.FrontmatterStyle = .panel,
    suppress_frontmatter: bool = false,
    mermaid_layout: mermaid_types.ForceLayout = .auto,
    mermaid_subgraph_edges: SubgraphEdges = .bridge,
    viewport: Viewport = .{},
    width: usize = 0,
    lines: []render_model.Line = &.{},
    footnote_index: []FootnoteEntry = &.{},
    selection: selection_mod.Selection = .{},

    pub fn init(allocator: std.mem.Allocator, title: []const u8, document: *const markdown.Document, resolved: *const ResolvedTheme, show_heading_markers: bool, mermaid_layout: mermaid_types.ForceLayout, subgraph_edges: SubgraphEdges) PagerView {
        return .{
            .allocator = allocator,
            .title = title,
            .document = document,
            .resolved = resolved,
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

    pub fn beginSelectionAt(self: *PagerView, row: usize, col: usize) void {
        self.selection.begin(self.viewport.lineForRow(row), col);
    }

    pub fn extendSelectionAt(self: *PagerView, row: usize, col: usize) void {
        self.selection.extendTo(self.viewport.lineForRow(row), col);
    }

    pub fn clearSelection(self: *PagerView) void {
        self.selection.clear();
    }

    pub fn selectedText(self: *PagerView, allocator: std.mem.Allocator) ![]u8 {
        return self.selection.extractText(allocator, self.lines);
    }

    pub fn selectionRangeForRow(self: *PagerView, row: usize) ?selection_mod.Range {
        const line_idx = self.viewport.top + row;
        if (line_idx >= self.lines.len) return null;
        return self.selection.rangeForLine(line_idx, self.lines[line_idx].displayWidth());
    }

    pub fn reload(self: *PagerView) !void {
        try self.reflow();
    }

    fn reflow(self: *PagerView) !void {
        self.selection.clear();
        self.freeLines();
        self.allocator.free(self.footnote_index);
        self.footnote_index = &.{};

        var rendered = try render_model.renderDocument(self.allocator, self.document.*, .{
            .width = if (self.width == 0) 80 else self.width,
            .show_heading_markers = self.show_heading_markers,
            .decor = &self.resolved.decor,
            .frontmatter_style = if (self.suppress_frontmatter) .hidden else self.frontmatter_style,
            .mermaid_force_layout = self.mermaid_layout,
            .mermaid_subgraph_edges = self.mermaid_subgraph_edges,
        });
        self.lines = rendered.lines;
        rendered.lines = &.{};
        self.viewport.setMetrics(self.viewport.height, self.lines.len);

        var index: std.ArrayList(FootnoteEntry) = .empty;
        errdefer index.deinit(self.allocator);

        for (self.lines, 0..) |line, li| {
            for (line.spans) |span| {
                const url = span.url orelse continue;
                if (std.mem.startsWith(u8, url, "#fn:")) {
                    const n = std.fmt.parseInt(usize, url[4..], 10) catch continue;
                    if (n == 0) continue;
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

    const rt = resolveMod.builtinResolved(allocator, "dark");
    var pager = PagerView.init(allocator, "fixture", &document, &rt, true, .auto, .bridge);
    defer pager.deinit();
    try pager.resize(80, 20);

    try std.testing.expectEqual(@as(usize, 1), pager.footnote_index.len);
    try std.testing.expect(pager.footnote_index[0].ref_line != null);
    try std.testing.expect(pager.footnote_index[0].def_line != null);
    try std.testing.expect(pager.footnote_index[0].ref_line.? < pager.footnote_index[0].def_line.?);
}

test "followFootnoteLink jumps to definition" {
    const allocator = std.testing.allocator;
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

    const rt = resolveMod.builtinResolved(allocator, "dark");
    var pager = PagerView.init(allocator, "fixture", &document, &rt, true, .auto, .bridge);
    defer pager.deinit();
    try pager.resize(80, 3);

    pager.viewport.top = 0;
    const jumped = pager.followFootnoteLink();
    try std.testing.expect(jumped);
    const def_line = pager.footnote_index[0].def_line.?;
    try std.testing.expect(pager.viewport.top <= def_line);
    try std.testing.expect(pager.viewport.top + pager.viewport.height > def_line);
}

test "selection maps screen rows to document text" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "Hello world foo bar");
    defer document.deinit(allocator);

    const rt = resolveMod.builtinResolved(allocator, "dark");
    var pager = PagerView.init(allocator, "fixture", &document, &rt, true, .auto, .bridge);
    defer pager.deinit();
    try pager.resize(80, 10);

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

    const rt = resolveMod.builtinResolved(allocator, "dark");
    var pager = PagerView.init(allocator, "fixture", &document, &rt, true, .auto, .bridge);
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

    const rt = resolveMod.builtinResolved(allocator, "dark");
    var pager = PagerView.init(allocator, "fixture", &document, &rt, true, .auto, .bridge);
    defer pager.deinit();
    try pager.resize(80, 10);

    pager.beginSelectionAt(0, 2);
    pager.extendSelectionAt(0, 5);
    try std.testing.expect(pager.selection.active);

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

    const rt = resolveMod.builtinResolved(allocator, "dark");
    var pager = PagerView.init(allocator, "fixture", &document, &rt, true, .auto, .bridge);
    defer pager.deinit();
    try pager.resize(20, 5);

    try std.testing.expect(pager.lines.len >= 3);
    try std.testing.expect(pager.lines[0].spans.len >= 1);
}
