const std = @import("std");
const vaxis = @import("vaxis");
const markdown = @import("../core/markdown.zig");
const config = @import("../core/config.zig");
const render_model = @import("../core/render_model.zig");
const theme = @import("../core/theme.zig");
const mermaid_types = @import("../core/mermaid/types.zig");
const SubgraphEdges = @import("prim").SubgraphEdges;
const editor = @import("../platform/editor.zig");
const PagerView = @import("views/pager.zig").PagerView;
const HelpView = @import("views/help.zig").HelpView;
const MetadataOverlay = @import("views/metadata.zig").MetadataOverlay;
const input = @import("input.zig");
const statusbar = @import("widgets/statusbar.zig");
const args = @import("../cli/args.zig");
const clipboard = @import("../platform/clipboard.zig");
const unicode = @import("../lib/unicode.zig");

/// How long a copy confirmation toast stays visible.
const toast_duration_ms: i64 = 1400;

/// Maximum display columns of copied-text preview shown in the toast.
const copy_preview_cols: usize = 40;

const ViewMode = enum {
    pager,
    help,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    mouse: vaxis.Mouse,
};

fn isMermaidFile(input_source: args.Input) bool {
    return switch (input_source) {
        .file => |path| std.mem.endsWith(u8, path, ".mmd"),
        else => false,
    };
}

fn parseContent(allocator: std.mem.Allocator, content: []const u8, input_source: args.Input) !markdown.Document {
    if (isMermaidFile(input_source)) {
        const language = try allocator.dupe(u8, "mermaid");
        errdefer allocator.free(language);
        const code = try allocator.dupe(u8, content);
        errdefer allocator.free(code);
        const blocks = try allocator.alloc(markdown.Block, 1);
        blocks[0] = .{ .fenced_code = .{ .language = language, .code = code } };
        return .{ .blocks = blocks };
    }
    return markdown.parse(allocator, content);
}

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

    // Mermaid layout override
    mermaid_layout: mermaid_types.ForceLayout,

    // Subgraph frame-border notation (config value; a later live toggle may
    // mutate it, mirroring `mermaid_layout`).
    mermaid_subgraph_edges: SubgraphEdges,

    // Copy confirmation toast (top-right overlay, auto-dismissed after a delay).
    toast_message: ?[]u8,
    toast_deadline_ms: i64,

    // Front matter metadata overlay (top-right panel toggled with `m`).
    metadata: MetadataOverlay,

    pub fn init(
        allocator: std.mem.Allocator,
        title: []const u8,
        input_source: args.Input,
        initial_content: []const u8,
        editor_command: []const u8,
        active_theme: config.Theme,
        syntax_theme: config.SyntaxTheme,
        theme_overrides: config.ThemeOverrides,
        glyphs: render_model.Glyphs,
        show_heading_markers: bool,
        frontmatter_style: config.FrontmatterStyle,
        initial_layout: mermaid_types.ForceLayout,
        initial_subgraph_edges: SubgraphEdges,
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

        self.current_document = try parseContent(allocator, self.current_content, input_source);
        errdefer self.current_document.deinit(allocator);

        self.mermaid_layout = initial_layout;
        self.mermaid_subgraph_edges = initial_subgraph_edges;
        self.pager = PagerView.init(allocator, title, &self.current_document, active_theme, syntax_theme, theme_overrides, glyphs, show_heading_markers, initial_layout, initial_subgraph_edges);
        self.pager.frontmatter_style = frontmatter_style;

        self.view_mode = .pager;
        self.status_message = null;
        self.needs_redraw = true;
        self.toast_message = null;
        self.toast_deadline_ms = 0;
        self.metadata = .{};

        return self;
    }

    pub fn deinit(self: *App) void {
        self.clearStatusMessage();
        self.clearToast();
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

        // Detect Apple Terminal and enable legacy SGR mode for color support
        if (std.posix.getenv("TERM_PROGRAM")) |prg| {
            if (std.mem.eql(u8, prg, "Apple_Terminal")) {
                self.vx.sgr = .legacy;
            }
        }

        try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);
        try self.vx.setMouseMode(writer, true);

        try self.pager.resize(self.vx.window().width, self.vx.window().height -| 1);

        while (true) {
            if (self.needs_redraw) {
                try self.drawAndRender();
                self.needs_redraw = false;
            }

            const event = self.waitEvent() orelse {
                // No event before the toast's deadline — dismiss it.
                self.clearToast();
                self.needs_redraw = true;
                continue;
            };
            switch (event) {
                .winsize => |ws| try self.handleResize(ws),
                .key_press => |key| {
                    if (try self.handleKeyPress(key)) break;
                },
                .focus_in => {
                    try self.pager.resize(self.vx.window().width, self.vx.window().height -| 1);
                    self.needs_redraw = true;
                },
                .mouse => |mouse| try self.handleMouse(mouse),
            }
        }

        try writer.flush();
    }

    fn initLoop(self: *App) !void {
        self.loop.tty = &self.tty;
        self.loop.vaxis = &self.vx;
        try self.loop.init();
    }

    /// Block for the next event. While a toast is showing, poll instead so the
    /// loop can wake to dismiss it; returns null when the toast's deadline
    /// passes with no event.
    fn waitEvent(self: *App) ?Event {
        if (self.toast_message == null) return self.loop.nextEvent();
        while (true) {
            if (self.loop.tryEvent()) |event| return event;
            if (std.time.milliTimestamp() >= self.toast_deadline_ms) return null;
            std.Thread.sleep(30 * std.time.ns_per_ms);
        }
    }

    fn handleKeyPress(self: *App, key: vaxis.Key) !bool {
        switch (input.mapKey(key)) {
            .quit => return true,
            .toggle_help => {
                self.view_mode = if (self.view_mode == .help) .pager else .help;
                // Keep overlays mutually exclusive so neither paints over the
                // other (z-order): opening help closes the metadata overlay.
                if (self.view_mode == .help) try self.setMetadataVisible(false);
            },
            .edit => {
                try self.handleEdit();
                return false;
            },
            .reload => {
                try self.handleReload();
                return false;
            },
            .cycle_layout => {
                self.mermaid_layout = self.mermaid_layout.next();
                try self.handleLayoutChange();
                return false;
            },
            .toggle_metadata => {
                try self.handleToggleMetadata();
                return false;
            },
            .toggle_subgraph_edges => {
                self.mermaid_subgraph_edges = self.mermaid_subgraph_edges.next();
                try self.handleSubgraphEdgesChange();
                return false;
            },
            // While the metadata overlay is open, navigation keys scroll it
            // rather than the document underneath.
            .line_up => if (self.metadata.visible) self.metadata.scrollBy(-1) else self.pager.lineUp(),
            .line_down => if (self.metadata.visible) self.metadata.scrollBy(1) else self.pager.lineDown(),
            .page_up => if (self.metadata.visible) self.metadata.scrollBy(-@as(isize, @intCast(self.metadata.visible_rows))) else self.pager.pageUp(),
            .page_down => if (self.metadata.visible) self.metadata.scrollBy(@as(isize, @intCast(self.metadata.visible_rows))) else self.pager.pageDown(),
            .top => if (self.metadata.visible) self.metadata.scrollTo(0) else self.pager.toTop(),
            .bottom => if (self.metadata.visible) self.metadata.scrollTo(std.math.maxInt(usize)) else self.pager.toBottom(),
            .follow_link => {
                _ = self.pager.followFootnoteLink();
            },
            .clear_selection => self.pager.clearSelection(),
            .none => return false,
        }
        self.clearStatusMessage();
        self.needs_redraw = true;
        return false;
    }

    fn handleMouse(self: *App, mouse: vaxis.Mouse) !void {
        // The metadata overlay is modal over its own area: swallow clicks so
        // they don't select the hidden document beneath it, and map the wheel
        // to overlay scrolling.
        if (self.metadata.visible and self.metadata.contains(mouse)) {
            switch (mouse.button) {
                .wheel_up => {
                    self.metadata.scrollBy(-1);
                    self.needs_redraw = true;
                },
                .wheel_down => {
                    self.metadata.scrollBy(1);
                    self.needs_redraw = true;
                },
                else => {},
            }
            return;
        }

        const content_height = self.vx.window().height -| 1;
        switch (mouse.button) {
            .wheel_up => {
                self.pager.lineUp();
                self.needs_redraw = true;
            },
            .wheel_down => {
                self.pager.lineDown();
                self.needs_redraw = true;
            },
            .left => {
                const col: usize = if (mouse.col < 0) 0 else @intCast(mouse.col);
                const row: usize = if (mouse.row < 0) 0 else @intCast(mouse.row);
                switch (mouse.type) {
                    .press => {
                        self.pager.beginSelectionAt(row, col);
                        self.clearStatusMessage();
                        self.needs_redraw = true;
                    },
                    .drag => {
                        // Auto-scroll when the drag reaches the top/bottom edge.
                        if (mouse.row <= 0) {
                            self.pager.lineUp();
                        } else if (content_height > 0 and mouse.row >= @as(i16, @intCast(content_height - 1))) {
                            self.pager.lineDown();
                        }
                        self.pager.extendSelectionAt(row, col);
                        self.needs_redraw = true;
                    },
                    .release => {
                        try self.copySelection();
                        self.needs_redraw = true;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    /// Overpaint reverse-video on the selected cells of the just-drawn `row`.
    fn highlightRow(self: *App, root: vaxis.Window, row: usize) void {
        const range = self.pager.selectionRangeForRow(row) orelse return;
        const cy: u16 = @intCast(row);
        var col: usize = range.start;
        while (col < range.end) : (col += 1) {
            const cx: u16 = @intCast(col);
            if (root.readCell(cx, cy)) |cell| {
                var highlighted = cell;
                highlighted.style.reverse = true;
                root.writeCell(cx, cy, highlighted);
            }
        }
    }

    fn copySelection(self: *App) !void {
        const text = try self.pager.selectedText(self.allocator);
        defer self.allocator.free(text);
        if (text.len == 0) return;

        const writer = self.tty.writer();
        clipboard.writeOsc52(writer, self.allocator, text) catch {};
        clipboard.writeNative(self.allocator, text);
        writer.flush() catch {};

        try self.showCopyToast(text);
    }

    /// Show a top-right toast previewing the copied text, e.g. `Copied "hi …"`.
    fn showCopyToast(self: *App, text: []const u8) !void {
        const message = try formatCopyPreview(self.allocator, text);
        self.clearToast();
        self.toast_message = message;
        self.toast_deadline_ms = std.time.milliTimestamp() + toast_duration_ms;
    }

    fn clearToast(self: *App) void {
        if (self.toast_message) |message| {
            self.allocator.free(message);
            self.toast_message = null;
        }
    }

    /// Draw the copy toast as a soft, themed panel in the top-right corner.
    fn drawToast(self: *App, root: vaxis.Window) void {
        const message = self.toast_message orelse return;
        // Box width = text + one space of padding each side + two borders.
        const width = @min(root.width -| 2, unicode.displayWidth(message) + 4);
        const height: usize = 3;
        if (width < 3 or root.height < height) return;

        const style = theme.toastStyle(self.pager.active_theme);
        const x_off = root.width -| width;

        // Fill the panel background, draw the rounded border over it, then print
        // the text directly onto the root window. (Printing onto the bordered
        // child window does not render reliably in this vaxis version.)
        const panel = root.child(.{ .x_off = x_off, .y_off = 0, .width = width, .height = height });
        panel.fill(.{ .style = style.fill });
        _ = root.child(.{
            .x_off = x_off,
            .y_off = 0,
            .width = width,
            .height = height,
            .border = .{ .where = .all, .glyphs = .single_rounded, .style = style.border },
        });
        _ = root.print(&.{.{ .text = message, .style = style.text }}, .{
            .row_offset = 1,
            .col_offset = x_off + 1,
            .wrap = .none,
        });
    }

    /// The document's front matter block, if any (always the first block).
    fn frontMatter(self: *App) ?markdown.Block.FrontMatter {
        for (self.current_document.blocks) |block| {
            if (block == .frontmatter) return block.frontmatter;
        }
        return null;
    }

    fn handleToggleMetadata(self: *App) !void {
        // `hidden` promises the front matter is stripped entirely (see
        // config.zig); the overlay must not reveal it either.
        if (self.pager.frontmatter_style == .hidden) {
            try self.setStatusMessage("Front matter is hidden (frontmatter = hidden).", false);
            self.needs_redraw = true;
            return;
        }
        if (self.frontMatter() == null) {
            try self.setStatusMessage("No front matter metadata in this document.", false);
            self.needs_redraw = true;
            return;
        }
        try self.setMetadataVisible(!self.metadata.visible);
        if (self.metadata.visible) {
            // Keep overlays mutually exclusive (z-order): opening metadata
            // dismisses the help dialog.
            self.view_mode = .pager;
        }
        self.clearStatusMessage();
        self.needs_redraw = true;
    }

    /// Show or hide the metadata overlay, keeping the document canvas in sync:
    /// while the overlay presents the front matter, the inline block is
    /// suppressed so the same data is not shown twice.
    fn setMetadataVisible(self: *App, visible: bool) !void {
        if (self.metadata.visible == visible) return;
        self.metadata.visible = visible;
        if (visible) self.metadata.scroll = 0;
        self.pager.suppress_frontmatter = visible;
        try self.pager.reload();
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
                try self.vx.setMouseMode(writer, false);
                try self.vx.exitAltScreen(writer);
                try editor.openFile(self.allocator, self.editor_command, path);
                try self.loop.start();
                try self.vx.enterAltScreen(writer);
                try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);
                try self.vx.setMouseMode(writer, true);

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

    fn handleLayoutChange(self: *App) !void {
        self.pager.mermaid_layout = self.mermaid_layout;
        try self.pager.reload();
        try self.setStatusMessage(try std.fmt.allocPrint(self.allocator, "Layout: {s}", .{self.mermaid_layout.displayName()}), true);
        self.needs_redraw = true;
    }

    fn handleSubgraphEdgesChange(self: *App) !void {
        self.pager.mermaid_subgraph_edges = self.mermaid_subgraph_edges;
        try self.pager.reload();
        try self.setStatusMessage(try std.fmt.allocPrint(self.allocator, "Subgraph edges: {s}", .{self.mermaid_subgraph_edges.displayName()}), true);
        self.needs_redraw = true;
    }

    fn reloadDocument(self: *App, path: []const u8) !void {
        const reloaded = try std.fs.cwd().readFileAlloc(self.allocator, path, std.math.maxInt(usize));
        self.allocator.free(self.current_content);
        self.current_content = reloaded;
        self.current_document.deinit(self.allocator);
        self.current_document = try parseContent(self.allocator, self.current_content, self.input_source);
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
                const segments = try toVaxisSegments(self.allocator, self.pager.lines[self.pager.viewport.top + row], self.pager.palette);
                defer self.allocator.free(segments);
                _ = root.print(segments, .{
                    .row_offset = @intCast(row),
                    .col_offset = 0,
                    .wrap = .none,
                });
                self.highlightRow(root, row);
            }
        }

        const status_text = try statusbar.format(self.allocator, self.pager.title, root.width, self.pager.viewport, self.view_mode == .help, self.status_message, self.mermaid_layout);
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

        // Frame-scoped storage for text handed to vaxis: screen cells borrow
        // the bytes until `vx.render` below has emitted them.
        var frame_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer frame_arena.deinit();
        // `hidden` keeps the front matter stripped (see config.zig); pass null
        // so the overlay never reveals it.
        const overlay_fm = if (self.pager.frontmatter_style == .hidden) null else self.frontMatter();
        try self.metadata.draw(root, frame_arena.allocator(), overlay_fm, self.pager.active_theme);
        self.drawToast(root);

        const writer = self.tty.writer();
        try self.vx.render(writer);
        try writer.flush();
    }
};

/// Entry point for TUI mode - creates and runs the App
pub fn run(allocator: std.mem.Allocator, title: []const u8, input_source: args.Input, initial_content: []const u8, editor_command: []const u8, active_theme: config.Theme, syntax_theme: config.SyntaxTheme, theme_overrides: config.ThemeOverrides, glyphs: render_model.Glyphs, show_heading_markers: bool, frontmatter_style: config.FrontmatterStyle, initial_layout: mermaid_types.ForceLayout, initial_subgraph_edges: SubgraphEdges) !void {
    var app = try App.init(allocator, title, input_source, initial_content, editor_command, active_theme, syntax_theme, theme_overrides, glyphs, show_heading_markers, frontmatter_style, initial_layout, initial_subgraph_edges);
    // Fix self-referential pointer invalidated by struct return copy.
    // App.init() stores &self.current_document where self is a local; after
    // the return-by-value copy into app, that pointer is stale.
    app.pager.document = &app.current_document;
    defer app.deinit();
    try app.run();
}

fn toVaxisSegments(allocator: std.mem.Allocator, line: render_model.Line, palette: theme.Palette) ![]vaxis.Segment {
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

/// Build the toast label previewing copied `text`, e.g. `Copied "hello …"`.
/// Runs of whitespace (including line breaks) collapse to a single space, and
/// the preview is truncated to `copy_preview_cols` display columns with a
/// trailing ` …`. Caller owns the returned slice.
fn formatCopyPreview(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var preview: std.ArrayList(u8) = .empty;
    defer preview.deinit(allocator);

    var cols: usize = 0;
    var index: usize = 0;
    var truncated = false;
    while (index < text.len) {
        const glyph = unicode.nextGlyph(text, index);
        index += glyph.bytes.len;
        const is_space = glyph.bytes.len == 1 and switch (glyph.bytes[0]) {
            ' ', '\t', '\n', '\r' => true,
            else => false,
        };
        if (is_space) {
            // Collapse runs of whitespace (incl. line breaks) to one space,
            // dropping any leading whitespace.
            if (preview.items.len == 0 or preview.items[preview.items.len - 1] == ' ') continue;
            try preview.append(allocator, ' ');
            cols += 1;
        } else {
            if (cols + glyph.width > copy_preview_cols) {
                truncated = true;
                break;
            }
            try preview.appendSlice(allocator, glyph.bytes);
            cols += glyph.width;
        }
    }
    if (preview.items.len > 0 and preview.items[preview.items.len - 1] == ' ') {
        preview.items.len -= 1;
    }

    return std.fmt.allocPrint(allocator, "Copied \"{s}{s}\"", .{
        preview.items,
        if (truncated) " …" else "",
    });
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

    const segments = try toVaxisSegments(allocator, rendered.lines[0], theme.palette(.dark, .default, .{}));
    defer allocator.free(segments);

    try std.testing.expectEqual(@intFromPtr(rendered.lines[0].spans[0].text.ptr), @intFromPtr(segments[0].text.ptr));
}

test "initLoop binds loop to app-owned tty and vaxis" {
    const allocator = std.testing.allocator;

    var app = try App.init(allocator, "fixture", .none, "# Title\n", "vim", .dark, .default, .{}, .{}, true, .panel, .auto, .bridge);
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

    var pager = PagerView.init(allocator, "fixture", &document, .dark, .default, .{}, .{}, true, .auto, .bridge);
    defer pager.deinit();

    try pager.resize(60, 5);
    const original_line_count = pager.lines.len;

    const changed = try syncPagerSize(&pager, 20, 5);

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 20), pager.width);
    try std.testing.expect(pager.lines.len > original_line_count);
}

test "toggle metadata is refused when front matter is hidden" {
    const allocator = std.testing.allocator;
    const content = "---\ntitle: Secret\n---\n# Body\n";
    var app = try App.init(allocator, "fixture", .none, content, "vim", .dark, .default, .{}, .{}, true, .hidden, .auto, .bridge);
    defer app.deinit();

    try app.handleToggleMetadata();
    // Hidden means stripped entirely — the overlay must not reveal it.
    try std.testing.expect(!app.metadata.visible);
    try std.testing.expect(app.status_message != null);
}

test "toggle metadata opens the overlay for visible front matter" {
    const allocator = std.testing.allocator;
    const content = "---\ntitle: Shown\n---\n# Body\n";
    var app = try App.init(allocator, "fixture", .none, content, "vim", .dark, .default, .{}, .{}, true, .panel, .auto, .bridge);
    defer app.deinit();

    try app.handleToggleMetadata();
    try std.testing.expect(app.metadata.visible);
}

test "opening the metadata overlay hides the inline front matter and closing restores it" {
    const allocator = std.testing.allocator;
    const content = "---\ntitle: Shown\n---\n# Body\n";
    var app = try App.init(allocator, "fixture", .none, content, "vim", .dark, .default, .{}, .{}, true, .panel, .auto, .bridge);
    defer app.deinit();

    try app.pager.resize(60, 20);
    const lines_with_frontmatter = app.pager.lines.len;

    try app.handleToggleMetadata();
    try std.testing.expect(app.metadata.visible);
    try std.testing.expect(app.pager.suppress_frontmatter);
    // The inline panel is gone from the canvas while the overlay shows it.
    try std.testing.expect(app.pager.lines.len < lines_with_frontmatter);

    try app.handleToggleMetadata();
    try std.testing.expect(!app.pager.suppress_frontmatter);
    try std.testing.expectEqual(lines_with_frontmatter, app.pager.lines.len);
}

test "toggle metadata is refused when the document has no front matter" {
    const allocator = std.testing.allocator;
    const content = "# Body only\n"; // no --- fenced block
    var app = try App.init(allocator, "fixture", .none, content, "vim", .dark, .default, .{}, .{}, true, .panel, .auto, .bridge);
    defer app.deinit();

    try app.handleToggleMetadata();
    try std.testing.expect(!app.metadata.visible);
    try std.testing.expect(app.status_message != null);
    try std.testing.expectEqualStrings("No front matter metadata in this document.", app.status_message.?);
}

test "formatCopyPreview quotes short text" {
    const allocator = std.testing.allocator;
    const message = try formatCopyPreview(allocator, "hello");
    defer allocator.free(message);
    try std.testing.expectEqualStrings("Copied \"hello\"", message);
}

test "formatCopyPreview collapses whitespace and drops leading padding" {
    const allocator = std.testing.allocator;
    const message = try formatCopyPreview(allocator, "  first\nsecond\t third  ");
    defer allocator.free(message);
    try std.testing.expectEqualStrings("Copied \"first second third\"", message);
}

test "formatCopyPreview truncates long text with an ellipsis" {
    const allocator = std.testing.allocator;
    const long = "a" ** 60;
    const message = try formatCopyPreview(allocator, long);
    defer allocator.free(message);
    const expected = "Copied \"" ++ ("a" ** copy_preview_cols) ++ " …\"";
    try std.testing.expectEqualStrings(expected, message);
}
