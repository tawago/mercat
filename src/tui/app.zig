const std = @import("std");
const vaxis = @import("vaxis");
const markdown = @import("../core/markdown.zig");
const config = @import("../core/config.zig");
const render_model = @import("../core/render_model.zig");
const theme = @import("../core/theme.zig");
const editor = @import("../platform/editor.zig");
const PagerView = @import("views/pager.zig").PagerView;
const HelpView = @import("views/help.zig").HelpView;
const input = @import("input.zig");
const statusbar = @import("widgets/statusbar.zig");
const args = @import("../cli/args.zig");

const ViewMode = enum {
    pager,
    help,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Event),
    tty: vaxis.Tty,
    tty_buffer: [4096]u8,

    // Document state
    title: []const u8,
    input_source: args.Input,
    current_content: []u8,
    current_document: markdown.Document,
    editor_command: []const u8,

    // View state
    pager: PagerView,
    view_mode: ViewMode,
    status_message: ?[]const u8,
    needs_redraw: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        title: []const u8,
        input_source: args.Input,
        initial_content: []const u8,
        editor_command: []const u8,
        active_theme: config.Theme,
        syntax_theme: config.SyntaxTheme,
        show_heading_markers: bool,
    ) !App {
        var self: App = undefined;
        self.allocator = allocator;
        self.title = title;
        self.input_source = input_source;
        self.editor_command = editor_command;
        self.tty_buffer = undefined;

        self.tty = try vaxis.Tty.init(&self.tty_buffer);
        errdefer self.tty.deinit();

        self.vx = try vaxis.init(allocator, .{});
        errdefer self.vx.deinit(allocator, self.tty.writer());

        self.loop = .{ .tty = undefined, .vaxis = undefined };

        self.current_content = try allocator.dupe(u8, initial_content);
        errdefer allocator.free(self.current_content);

        self.current_document = try markdown.parse(allocator, self.current_content);
        errdefer self.current_document.deinit(allocator);

        self.pager = PagerView.init(allocator, title, &self.current_document, active_theme, syntax_theme, show_heading_markers);

        self.view_mode = .pager;
        self.status_message = null;
        self.needs_redraw = true;

        return self;
    }

    pub fn deinit(self: *App) void {
        self.clearStatusMessage();
        self.pager.deinit();
        self.current_document.deinit(self.allocator);
        self.allocator.free(self.current_content);
        self.loop.stop();
        const writer = self.tty.writer();
        self.vx.deinit(self.allocator, writer);
        self.tty.deinit();
    }

    pub fn run(self: *App) !void {
        try self.initLoop();
        const writer = self.tty.writer();

        try self.loop.start();
        try self.vx.enterAltScreen(writer);
        try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);

        try self.pager.resize(self.vx.window().width, self.vx.window().height -| 1);

        while (true) {
            if (self.needs_redraw) {
                try self.drawAndRender();
                self.needs_redraw = false;
            }

            const event = self.loop.nextEvent();
            switch (event) {
                .winsize => |ws| try self.handleResize(ws),
                .key_press => |key| {
                    if (try self.handleKeyPress(key)) break;
                },
                .focus_in => {
                    try self.pager.resize(self.vx.window().width, self.vx.window().height -| 1);
                    self.needs_redraw = true;
                },
            }
        }

        try writer.flush();
    }

    fn initLoop(self: *App) !void {
        self.loop.tty = &self.tty;
        self.loop.vaxis = &self.vx;
        try self.loop.init();
    }

    fn handleKeyPress(self: *App, key: vaxis.Key) !bool {
        switch (input.mapKey(key)) {
            .quit => return true,
            .toggle_help => self.view_mode = if (self.view_mode == .help) .pager else .help,
            .edit => {
                try self.handleEdit();
                return false;
            },
            .reload => {
                try self.handleReload();
                return false;
            },
            .line_up => self.pager.lineUp(),
            .line_down => self.pager.lineDown(),
            .page_up => self.pager.pageUp(),
            .page_down => self.pager.pageDown(),
            .top => self.pager.toTop(),
            .bottom => self.pager.toBottom(),
            .follow_link => {
                _ = self.pager.followFootnoteLink();
            },
            .none => return false,
        }
        self.clearStatusMessage();
        self.needs_redraw = true;
        return false;
    }

    fn handleResize(self: *App, ws: vaxis.Winsize) !void {
        const writer = self.tty.writer();
        try self.vx.resize(self.allocator, writer, ws);
        try self.pager.resize(self.vx.window().width, self.vx.window().height -| 1);
        self.needs_redraw = true;
    }

    fn handleEdit(self: *App) !void {
        switch (self.input_source) {
            .file => |path| {
                self.clearStatusMessage();
                const writer = self.tty.writer();
                self.loop.stop();
                try self.vx.exitAltScreen(writer);
                try editor.openFile(self.allocator, self.editor_command, path);
                try self.loop.start();
                try self.vx.enterAltScreen(writer);
                try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);

                try self.reloadDocument(path);
                try self.setStatusMessage(try std.fmt.allocPrint(self.allocator, "Reloaded {s}", .{std.fs.path.basename(path)}), true);
                self.needs_redraw = true;
            },
            else => {
                try self.setStatusMessage("Edit mode is only available for file inputs.", false);
                self.needs_redraw = true;
            },
        }
    }

    fn handleReload(self: *App) !void {
        switch (self.input_source) {
            .file => |path| {
                try self.reloadDocument(path);
                try self.setStatusMessage(try std.fmt.allocPrint(self.allocator, "Reloaded {s}", .{std.fs.path.basename(path)}), true);
                self.needs_redraw = true;
            },
            else => {
                try self.setStatusMessage("Reload is only available for file inputs.", false);
                self.needs_redraw = true;
            },
        }
    }

    fn reloadDocument(self: *App, path: []const u8) !void {
        const reloaded = try std.fs.cwd().readFileAlloc(self.allocator, path, std.math.maxInt(usize));
        self.allocator.free(self.current_content);
        self.current_content = reloaded;
        self.current_document.deinit(self.allocator);
        self.current_document = try markdown.parse(self.allocator, self.current_content);
        self.pager.document = &self.current_document;
        self.pager.width = self.vx.window().width;
        self.pager.viewport.setMetrics(self.vx.window().height -| 1, self.pager.viewport.total);
        try self.pager.reload();
    }

    fn clearStatusMessage(self: *App) void {
        if (self.status_message) |message| {
            self.allocator.free(message);
            self.status_message = null;
        }
    }

    fn setStatusMessage(self: *App, message: []const u8, owned: bool) !void {
        self.clearStatusMessage();
        self.status_message = if (owned) message else try self.allocator.dupe(u8, message);
    }

    fn drawAndRender(self: *App) !void {
        const root = self.vx.window();
        const content_height: usize = root.height -| 1;
        _ = try syncPagerSize(&self.pager, root.width, content_height);

        root.clear();

        if (self.view_mode == .pager) {
            var row: usize = 0;
            while (row < content_height and self.pager.viewport.top + row < self.pager.lines.len) : (row += 1) {
                const segments = try toVaxisSegments(self.allocator, self.pager.lines[self.pager.viewport.top + row], self.pager.active_theme, self.pager.syntax_theme);
                defer self.allocator.free(segments);
                _ = root.print(segments, .{
                    .row_offset = @intCast(row),
                    .col_offset = 0,
                    .wrap = .none,
                });
            }
        }

        const status_text = try statusbar.format(self.allocator, self.pager.title, root.width, self.pager.viewport, self.view_mode == .help, self.status_message);
        defer self.allocator.free(status_text);
        const status_style: vaxis.Style = .{ .reverse = true };
        _ = root.print(&.{.{ .text = status_text, .style = status_style }}, .{
            .row_offset = root.height -| 1,
            .col_offset = 0,
            .wrap = .none,
        });

        if (self.view_mode == .help) {
            drawHelp(root);
        }

        const writer = self.tty.writer();
        try self.vx.render(writer);
        try writer.flush();
    }
};

/// Entry point for TUI mode - creates and runs the App
pub fn run(allocator: std.mem.Allocator, title: []const u8, input_source: args.Input, initial_content: []const u8, editor_command: []const u8, active_theme: config.Theme, syntax_theme: config.SyntaxTheme, show_heading_markers: bool) !void {
    var app = try App.init(allocator, title, input_source, initial_content, editor_command, active_theme, syntax_theme, show_heading_markers);
    defer app.deinit();
    try app.run();
}

fn toVaxisSegments(allocator: std.mem.Allocator, line: render_model.Line, active_theme: config.Theme, syntax_theme: config.SyntaxTheme) ![]vaxis.Segment {
    const palette = theme.palette(active_theme, syntax_theme);
    const segments = try allocator.alloc(vaxis.Segment, line.spans.len);
    for (line.spans, 0..) |span, index| {
        var segment: vaxis.Segment = .{
            .text = span.text,
            .style = theme.vaxisStyle(theme.token(palette, span.style)),
        };
        if (span.url) |url| {
            segment.link = .{ .uri = url };
        }
        segments[index] = segment;
    }
    return segments;
}

fn syncPagerSize(pager: *PagerView, width: usize, height: usize) !bool {
    if (pager.width == width and pager.viewport.height == height) return false;
    try pager.resize(width, height);
    return true;
}

fn drawHelp(root: vaxis.Window) void {
    const help_lines = HelpView.lines();
    const width = @min(root.width -| 4, HelpView.width() + 4);
    const height = @min(root.height -| 2, help_lines.len + 2);
    const x_off = (root.width -| width) / 2;
    const y_off = (root.height -| height) / 2;
    const box = root.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = width,
        .height = height,
        .border = .{ .where = .all, .style = .{ .reverse = true } },
    });
    var row: usize = 0;
    while (row < help_lines.len and row + 1 < height) : (row += 1) {
        _ = box.print(&.{.{ .text = help_lines[row], .style = .{ .reverse = true } }}, .{
            .row_offset = @intCast(row + 1),
            .col_offset = 1,
            .wrap = .none,
        });
    }
}

test "toVaxisSegments borrows render-model span text" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\# Title
    );
    defer document.deinit(allocator);
    var rendered = try render_model.renderDocument(allocator, document, .{ .width = 20 });
    defer rendered.deinit(allocator);

    const segments = try toVaxisSegments(allocator, rendered.lines[0], .dark, .default);
    defer allocator.free(segments);

    try std.testing.expectEqual(@intFromPtr(rendered.lines[0].spans[0].text.ptr), @intFromPtr(segments[0].text.ptr));
}

test "initLoop binds loop to app-owned tty and vaxis" {
    const allocator = std.testing.allocator;

    var app = try App.init(allocator, "fixture", .none, "# Title\n", "vim", .dark, .default, true);
    defer app.deinit();

    try app.initLoop();

    try std.testing.expectEqual(@intFromPtr(&app.tty), @intFromPtr(app.loop.tty));
    try std.testing.expectEqual(@intFromPtr(&app.vx), @intFromPtr(app.loop.vaxis));
}

test "syncPagerSize reflows when draw detects width change" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\A paragraph with enough text to wrap differently when the viewport width changes.
    );
    defer document.deinit(allocator);

    var pager = PagerView.init(allocator, "fixture", &document, .dark, .default, true);
    defer pager.deinit();

    try pager.resize(60, 5);
    const original_line_count = pager.lines.len;

    const changed = try syncPagerSize(&pager, 20, 5);

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 20), pager.width);
    try std.testing.expect(pager.lines.len > original_line_count);
}
