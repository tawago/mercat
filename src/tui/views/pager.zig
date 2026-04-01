const std = @import("std");
const config = @import("../../core/config.zig");
const markdown = @import("../../core/markdown.zig");
const render_model = @import("../../core/render_model.zig");
const Viewport = @import("../widgets/viewport.zig").Viewport;

pub const PagerView = struct {
    allocator: std.mem.Allocator,
    title: []const u8,
    document: *const markdown.Document,
    active_theme: config.Theme,
    syntax_theme: config.SyntaxTheme,
    show_heading_markers: bool = true,
    viewport: Viewport = .{},
    width: usize = 0,
    lines: []render_model.Line = &.{},

    pub fn init(allocator: std.mem.Allocator, title: []const u8, document: *const markdown.Document, active_theme: config.Theme, syntax_theme: config.SyntaxTheme, show_heading_markers: bool) PagerView {
        return .{
            .allocator = allocator,
            .title = title,
            .document = document,
            .active_theme = active_theme,
            .syntax_theme = syntax_theme,
            .show_heading_markers = show_heading_markers,
        };
    }

    pub fn deinit(self: *PagerView) void {
        self.freeLines();
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

    pub fn reload(self: *PagerView) !void {
        try self.reflow();
    }

    fn reflow(self: *PagerView) !void {
        self.freeLines();

        var rendered = try render_model.renderDocument(self.allocator, self.document.*, .{
            .width = if (self.width == 0) 80 else self.width,
            .show_heading_markers = self.show_heading_markers,
        });
        self.lines = rendered.lines;
        rendered.lines = &.{};
        self.viewport.setMetrics(self.viewport.height, self.lines.len);
    }

    fn freeLines(self: *PagerView) void {
        for (self.lines) |line| line.deinit(self.allocator);
        self.allocator.free(self.lines);
        self.lines = &.{};
    }
};

test "reflows rendered text into lines" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\# Title
        \\
        \\- one
        \\- two
    );
    defer document.deinit(allocator);

    var pager = PagerView.init(allocator, "fixture", &document, .dark, .default, true);
    defer pager.deinit();
    try pager.resize(20, 5);

    try std.testing.expect(pager.lines.len >= 3);
    try std.testing.expect(pager.lines[0].spans.len >= 1);
}
