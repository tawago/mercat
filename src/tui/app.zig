const std = @import("std");
const vaxis = @import("vaxis");
const markdown = @import("../core/markdown/parser.zig");
const encoding = @import("../core/encoding.zig");
const cli_input = @import("../cli/input.zig");
const config = @import("../core/config.zig");
const render_model = @import("../core/markdown/render.zig");
const theme = @import("../core/theme.zig");
const theme_resolve = @import("../core/theme/resolve.zig");
const ResolvedTheme = theme_resolve.ResolvedTheme;
const SubgraphEdges = @import("../core/mermaid/mermaid.zig").SubgraphEdges;
const editor = @import("../platform/editor.zig");
const PagerView = @import("views/pager.zig").PagerView;
const HelpView = @import("views/help.zig").HelpView;
const MetadataOverlay = @import("views/metadata.zig").MetadataOverlay;
const input = @import("input.zig");
const statusbar = @import("widgets/statusbar.zig");
const args = @import("../cli/args.zig");
const clipboard = @import("../platform/clipboard.zig");
const unicode = @import("unicode");
const selection_mod = @import("selection.zig");
const search_mod = @import("search.zig");
const term_guard = @import("term_guard.zig");
const ctlseqs = vaxis.ctlseqs;

const toast_duration_ms: i64 = 1400;

const ViewMode = enum {
    pager,
    help,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    mouse: vaxis.Mouse,
    /// Posted by the terminal guard after the process continues from SIGTSTP.
    resumed,
};

fn parseContent(allocator: std.mem.Allocator, content: []const u8, input_source: args.Input) !markdown.Document {
    if (cli_input.isMermaidSource(input_source.filePath(), content)) return markdown.parseMermaid(allocator, content);
    return markdown.parse(allocator, content);
}

pub const App = struct {
    allocator: std.mem.Allocator,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Event),
    tty: vaxis.Tty,
    tty_buffer: [4096]u8,

    title: []const u8,
    input_source: args.Input,
    current_content: []u8,
    current_document: markdown.Document,
    editor_command: []const u8,

    pager: PagerView,
    view_mode: ViewMode,
    status_message: ?[]const u8,
    needs_redraw: bool,

    mermaid_layout: args.ForceLayout,

    mermaid_subgraph_edges: SubgraphEdges,

    toast_message: ?[]u8,
    toast_deadline_ms: i64,

    metadata: MetadataOverlay,

    search_prompt: search_mod.Prompt,

    pub fn init(
        self: *App,
        allocator: std.mem.Allocator,
        title: []const u8,
        input_source: args.Input,
        initial_content: []const u8,
        editor_command: []const u8,
        resolved: *const ResolvedTheme,
        theme_warning: ?[]const u8,
        show_heading_markers: bool,
        frontmatter_style: config.FrontmatterStyle,
        initial_layout: args.ForceLayout,
        initial_subgraph_edges: SubgraphEdges,
    ) !void {
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
        self.pager = PagerView.init(allocator, title, &self.current_document, resolved, show_heading_markers, initial_subgraph_edges);
        self.pager.frontmatter_style = frontmatter_style;

        self.view_mode = .pager;
        self.status_message = if (theme_warning) |w| try allocator.dupe(u8, w) else null;
        self.needs_redraw = true;
        self.toast_message = null;
        self.toast_deadline_ms = 0;
        self.metadata = .{};
        self.search_prompt = search_mod.Prompt.init(allocator);
    }

    pub fn deinit(self: *App) void {
        self.clearStatusMessage();
        self.clearToast();
        self.search_prompt.deinit();
        self.pager.deinit();
        self.current_document.deinit(self.allocator);
        self.allocator.free(self.current_content);
        self.loop.stop();
        const writer = self.tty.writer();
        self.vx.deinit(self.allocator, writer);
        term_guard.uninstall();
        self.tty.deinit();
    }

    pub fn run(self: *App) !void {
        try self.initLoop();
        const writer = self.tty.writer();

        try self.loop.start();
        try self.vx.enterAltScreen(writer);

        if (std.posix.getenv("TERM_PROGRAM")) |prg| {
            if (std.mem.eql(u8, prg, "Apple_Terminal")) {
                self.vx.sgr = .legacy;
            }
        }

        try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);
        try self.vx.setMouseMode(writer, true);
        if (cookedTermios(&self.tty)) |cooked| {
            try term_guard.install(self.tty.fd, cooked, .{ .context = self, .on_resume = onResume });
        }

        try self.pager.resize(self.vx.window().width, self.vx.window().height -| 1);

        while (true) {
            if (self.needs_redraw) {
                try self.drawAndRender();
                self.needs_redraw = false;
            }

            const event = self.waitEvent() orelse {
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
                .resumed => try self.reenterScreen(),
            }
        }

        try writer.flush();
    }

    fn initLoop(self: *App) !void {
        self.loop.tty = &self.tty;
        self.loop.vaxis = &self.vx;
        try self.loop.init();
    }

    fn waitEvent(self: *App) ?Event {
        if (self.toast_message == null) return self.loop.nextEvent();
        while (true) {
            if (self.loop.tryEvent()) |event| return event;
            if (std.time.milliTimestamp() >= self.toast_deadline_ms) return null;
            std.Thread.sleep(30 * std.time.ns_per_ms);
        }
    }

    pub fn handleKeyPress(self: *App, key: vaxis.Key) !bool {
        if (self.search_prompt.active) return self.handlePromptKey(key);
        switch (input.mapKey(key)) {
            .quit => return true,
            .search_start => {
                self.view_mode = .pager;
                try self.search_prompt.begin(&self.pager.search, self.pager.viewport);
                self.clearStatusMessage();
                self.needs_redraw = true;
                return false;
            },
            .search_next, .search_prev => {
                try self.stepSearch(if (input.mapKey(key) == .search_next) .forward else .backward);
                return false;
            },
            .suspend_app => {
                term_guard.suspendSelf();
                try self.reenterScreen();
                return false;
            },
            .toggle_help => {
                self.view_mode = if (self.view_mode == .help) .pager else .help;
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

    fn highlightRow(self: *App, root: vaxis.Window, row: usize) !void {
        const line_idx = self.pager.viewport.top + row;
        if (line_idx >= self.pager.lines.len) return;
        const range = self.pager.selection.rangeForRenderedLine(
            self.allocator,
            line_idx,
            self.pager.lines[line_idx],
        ) catch |err| switch (err) {
            error.InvalidUtf8, error.DisallowedControl, error.Overflow => |e| {
                try self.reportMeasureError("select text", e);
                return;
            },
            else => return err,
        } orelse return;
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

    /// Marks search matches on a drawn row: every match reversed, the current
    /// one in the theme accent so it stands out.
    fn highlightMatches(self: *App, root: vaxis.Window, row: usize) void {
        const search = &self.pager.search;
        if (!search.hasPattern()) return;
        const line_idx = self.pager.viewport.top + row;
        const current_style = searchCurrentStyle(self.pager.resolved);
        for (search.matchesOnLine(line_idx)) |match| {
            const is_current = search.isCurrent(match);
            var col = match.col_start;
            while (col < match.col_end and col < root.width) : (col += 1) {
                const cx: u16 = @intCast(col);
                const cy: u16 = @intCast(row);
                var cell = root.readCell(cx, cy) orelse continue;
                if (is_current) {
                    cell.style.fg = current_style.fg;
                    cell.style.bg = current_style.bg;
                    cell.style.bold = true;
                    cell.style.reverse = current_style.reverse;
                    cell.style.ul_style = .single;
                } else {
                    cell.style.reverse = true;
                }
                root.writeCell(cx, cy, cell);
            }
        }
    }

    fn copySelection(self: *App) !void {
        const text = self.pager.selectedText(self.allocator) catch |err| switch (err) {
            error.InvalidUtf8, error.DisallowedControl, error.Overflow => |e| {
                try self.reportMeasureError("copy selection", e);
                return;
            },
            else => return err,
        };
        defer self.allocator.free(text);
        if (text.len == 0) return;

        const writer = self.tty.writer();
        clipboard.writeOsc52(writer, self.allocator, text) catch {};
        clipboard.writeNative(self.allocator, text);
        writer.flush() catch {};

        try self.showCopyToast(text);
    }

    fn showCopyToast(self: *App, text: []const u8) !void {
        const message = selection_mod.formatCopyPreview(self.allocator, text) catch |err| switch (err) {
            error.InvalidUtf8, error.DisallowedControl, error.Overflow => |e| {
                try self.reportMeasureError("preview copied text", e);
                return;
            },
            else => return err,
        };
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

    fn drawToast(self: *App, root: vaxis.Window) !void {
        const message = self.toast_message orelse return;
        const message_width = unicode.rawDisplayWidth(message) catch |err| {
            try self.reportMeasureError("show copy preview", err);
            self.clearToast();
            return;
        };
        const width = @min(root.width -| 2, message_width +| 4);
        const height: usize = 3;
        if (width < 3 or root.height < height) return;

        const style = theme.toastStyle(self.pager.resolved.accent, self.pager.resolved.base_bg);
        const x_off = root.width -| width;

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

    fn frontMatter(self: *App) ?markdown.Block.FrontMatter {
        for (self.current_document.blocks) |block| {
            if (block == .frontmatter) return block.frontmatter;
        }
        return null;
    }

    fn handleToggleMetadata(self: *App) !void {
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
            self.view_mode = .pager;
        }
        self.clearStatusMessage();
        self.needs_redraw = true;
    }

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
        self.needs_redraw = true;
        const path = switch (self.input_source) {
            .file => |file_path| file_path,
            else => return self.setStatusMessage("Edit mode is only available for file inputs.", false),
        };
        const resolved = try editor.resolve(self.allocator, self.editor_command, editor.Env.fromProcess()) orelse
            return self.setStatusMessage("No editor found — set $EDITOR or [general] editor", false);
        defer resolved.deinit(self.allocator);
        const program = try editor.programName(self.allocator, resolved.command);
        defer self.allocator.free(program);
        if (!editor.programExists(std.posix.getenv("PATH"), program)) {
            return self.setStatusMessage(try editorNotFoundMessage(self.allocator, program), true);
        }

        const loop_was_running = try self.suspendForChild();
        term_guard.setChildRunning(true);
        const result = editor.openFileNotify(self.allocator, resolved.command, path, term_guard.setChildPid);
        term_guard.setChildRunning(false);
        try self.resumeFromChild(loop_was_running);
        result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EditorNotFound => return self.setStatusMessage(try editorNotFoundMessage(self.allocator, program), true),
            error.InvalidEditorCommand => return self.setStatusMessage(
                try std.fmt.allocPrint(self.allocator, "Invalid editor command: {s}", .{resolved.command}),
                true,
            ),
            error.EditorFailed => {
                if (!try self.reloadOrReport(path)) return;
                return self.setStatusMessage(
                    try std.fmt.allocPrint(self.allocator, "Editor '{s}' exited with an error; reloaded {s}", .{ program, std.fs.path.basename(path) }),
                    true,
                );
            },
        };
        _ = try self.reloadOrReport(path);
    }

    fn handleReload(self: *App) !void {
        self.needs_redraw = true;
        switch (self.input_source) {
            .file => |path| _ = try self.reloadOrReport(path),
            else => try self.setStatusMessage("Reload is only available for file inputs.", false),
        }
    }

    /// Reloads `path`; on failure keeps the current document and explains why
    /// in the status line instead of exiting. Returns whether it reloaded.
    fn reloadOrReport(self: *App, path: []const u8) !bool {
        const warning = self.reloadDocument(path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.setStatusMessage(try reloadFailureMessage(self.allocator, path, err), true);
                return false;
            },
        };
        if (warning) |message| {
            try self.setStatusMessage(message, true);
            return true;
        }
        try self.setStatusMessage(try std.fmt.allocPrint(self.allocator, "Reloaded {s}", .{std.fs.path.basename(path)}), true);
        return true;
    }

    /// Leaves the TUI so a child (the editor) owns the terminal. Returns
    /// whether the input loop was running (and so must be restarted).
    fn suspendForChild(self: *App) !bool {
        const writer = self.tty.writer();
        const loop_was_running = self.loop.thread != null;
        self.loop.stop();
        try self.vx.resetState(writer);
        try writer.flush();
        term_guard.enterCookedMode();
        return loop_was_running;
    }

    fn resumeFromChild(self: *App, restart_loop: bool) !void {
        term_guard.reenterRawMode();
        if (restart_loop) try self.loop.start();
        try self.reenterScreen();
    }

    /// Re-enables the alt screen, input modes and mouse after the terminal was
    /// reset (editor, Ctrl-Z, SIGTSTP) and forces a full repaint.
    fn reenterScreen(self: *App) !void {
        const writer = self.tty.writer();
        try self.vx.enterAltScreen(writer);
        self.vx.state.kitty_keyboard = false;
        try self.vx.enableDetectedFeatures(writer);
        if (self.vx.state.in_band_resize) try writer.writeAll(ctlseqs.in_band_resize_set);
        try self.vx.setMouseMode(writer, true);
        self.vx.queueRefresh();
        self.needs_redraw = true;
    }

    fn onResume(context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        _ = self.loop.tryPostEvent(.resumed);
    }

    fn handlePromptKey(self: *App, key: vaxis.Key) !bool {
        const prompt = &self.search_prompt;
        const search = &self.pager.search;
        const view = &self.pager.viewport;
        const lines = self.pager.lines;
        self.needs_redraw = true;
        switch (input.mapPromptKey(key)) {
            .quit => return true,
            .cancel => try prompt.cancel(search, view, lines),
            .commit => {
                try prompt.commit(search, view, lines);
                if (search.hasPattern()) try self.setStatusMessage(try search.statusText(self.allocator), true);
            },
            .backspace => _ = try prompt.backspace(search, view, lines),
            .clear => try prompt.clearQuery(search, view, lines),
            .insert => |text| try prompt.insert(text, search, view, lines),
            .ignore => self.needs_redraw = false,
        }
        return false;
    }

    fn stepSearch(self: *App, direction: search_mod.Direction) !void {
        self.needs_redraw = true;
        const search = &self.pager.search;
        if (!search.hasPattern()) return self.setStatusMessage("No previous search — press / to search", false);
        if (search.step(direction, self.pager.viewport)) |match| {
            search_mod.reveal(&self.pager.viewport, match.line);
        }
        try self.setStatusMessage(try search.statusText(self.allocator), true);
    }

    fn handleLayoutChange(self: *App) !void {
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

    /// Reloads `path`. Returns the warning for invalid input (owned), if any.
    fn reloadDocument(self: *App, path: []const u8) !?[]u8 {
        const raw = try std.fs.cwd().readFileAlloc(self.allocator, path, std.math.maxInt(usize));
        defer self.allocator.free(raw);
        const decoded = try encoding.decode(self.allocator, raw);
        const reloaded = if (decoded.owned) @constCast(decoded.text) else try self.allocator.dupe(u8, decoded.text);
        // Parse before swapping so a failure keeps the current document.
        const document = parseContent(self.allocator, reloaded, self.input_source) catch |err| {
            self.allocator.free(reloaded);
            return err;
        };
        self.allocator.free(self.current_content);
        self.current_content = reloaded;
        self.current_document.deinit(self.allocator);
        self.current_document = document;
        self.pager.document = &self.current_document;
        self.pager.width = self.vx.window().width;
        self.pager.viewport.setMetrics(self.vx.window().height -| 1, self.pager.viewport.total);
        try self.pager.reload();
        const issue = decoded.issue orelse return null;
        var buf: [512]u8 = undefined;
        return try self.allocator.dupe(u8, encoding.describeIssue(&buf, path, decoded.encoding, issue));
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

    fn reportMeasureError(self: *App, action: []const u8, err: unicode.MeasureError) !void {
        const reason: []const u8 = switch (err) {
            error.InvalidUtf8 => "invalid UTF-8",
            error.DisallowedControl => "unsupported control character",
            error.Overflow => "line is too wide",
        };
        const message = try std.fmt.allocPrint(self.allocator, "Cannot {s}: {s}.", .{ action, reason });
        try self.setStatusMessage(message, true);
    }

    fn drawAndRender(self: *App) !void {
        const root = self.vx.window();
        const content_height: usize = root.height -| 1;
        _ = try syncPagerSize(&self.pager, root.width, content_height);

        root.clear();

        if (self.pager.resolved.canvasBg()) |bg| {
            root.fill(.{ .style = .{ .bg = theme.toVaxisColor(bg) } });
        }

        if (self.view_mode == .pager) {
            var row: usize = 0;
            while (row < content_height and self.pager.viewport.top + row < self.pager.lines.len) : (row += 1) {
                const segments = try toVaxisSegments(self.allocator, self.pager.lines[self.pager.viewport.top + row], self.pager.resolved);
                defer self.allocator.free(segments);
                _ = root.print(segments, .{
                    .row_offset = @intCast(row),
                    .col_offset = 0,
                    .wrap = .none,
                });
                self.highlightMatches(root, row);
                try self.highlightRow(root, row);
            }
        }

        const prompt_text = if (self.search_prompt.active)
            try std.fmt.allocPrint(self.allocator, "/{s}", .{self.search_prompt.query.items})
        else
            null;
        defer if (prompt_text) |text| self.allocator.free(text);
        const status_text = try statusbar.format(self.allocator, self.pager.title, root.width, self.pager.viewport, self.view_mode == .help, prompt_text orelse self.status_message, self.mermaid_layout);
        defer self.allocator.free(status_text);
        const status_style: vaxis.Style = .{ .reverse = true };
        _ = root.print(&.{.{ .text = status_text, .style = status_style }}, .{
            .row_offset = root.height -| 1,
            .col_offset = 0,
            .wrap = .none,
        });
        if (prompt_text) |text| {
            const col = @min(1 + unicode.displayWidth(text), root.width -| 1);
            root.showCursor(@intCast(col), root.height -| 1);
        } else {
            root.hideCursor();
        }

        if (self.view_mode == .help) {
            drawHelp(root);
        }

        var frame_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer frame_arena.deinit();
        const overlay_fm = if (self.pager.frontmatter_style == .hidden) null else self.frontMatter();
        const metadata_style = theme.metadataPanelStyle(self.pager.resolved.accent, self.pager.resolved.base_bg);
        self.metadata.draw(root, frame_arena.allocator(), overlay_fm, metadata_style) catch |err| switch (err) {
            error.InvalidUtf8, error.DisallowedControl, error.Overflow => |e| try self.reportMeasureError("show metadata", e),
            else => return err,
        };
        try self.drawToast(root);

        const writer = self.tty.writer();
        try self.vx.render(writer);
        try writer.flush();
    }
};

pub fn run(allocator: std.mem.Allocator, title: []const u8, input_source: args.Input, initial_content: []const u8, editor_command: []const u8, resolved: *const ResolvedTheme, theme_warning: ?[]const u8, show_heading_markers: bool, frontmatter_style: config.FrontmatterStyle, initial_layout: args.ForceLayout, initial_subgraph_edges: SubgraphEdges) !void {
    var app: App = undefined;
    try app.init(allocator, title, input_source, initial_content, editor_command, resolved, theme_warning, show_heading_markers, frontmatter_style, initial_layout, initial_subgraph_edges);
    defer app.deinit();
    try app.run();
}

fn toVaxisSegments(allocator: std.mem.Allocator, line: render_model.Line, resolved: *const ResolvedTheme) ![]vaxis.Segment {
    const palette = resolved.styles;
    const canvas_bg = resolved.canvasBg();
    const segments = try allocator.alloc(vaxis.Segment, line.spans.len);
    for (line.spans, 0..) |span, index| {
        const token = theme.token(palette, span.style);
        var style = theme.vaxisStyle(token);
        if (canvas_bg) |bg| {
            if (token.bg == null) style.bg = theme.toVaxisColor(bg);
        }
        var segment: vaxis.Segment = .{ .text = span.text, .style = style };
        if (span.url) |url| {
            segment.link = .{ .uri = url };
        }
        segments[index] = segment;
    }
    return segments;
}

/// The current search match: accent background with the canvas (or black)
/// foreground; falls back to reverse video when the accent is the default.
fn searchCurrentStyle(resolved: *const ResolvedTheme) vaxis.Style {
    if (resolved.accent == .default) return .{ .reverse = true, .bold = true, .ul_style = .single };
    const fg: vaxis.Color = if (resolved.base_bg == .default) .{ .index = 0 } else theme.toVaxisColor(resolved.base_bg);
    return .{ .fg = fg, .bg = theme.toVaxisColor(resolved.accent), .bold = true, .ul_style = .single };
}

fn cookedTermios(tty: *vaxis.Tty) ?std.posix.termios {
    if (@hasField(vaxis.Tty, "termios")) return tty.termios;
    return null;
}

fn editorNotFoundMessage(allocator: std.mem.Allocator, program: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Editor '{s}' not found — set $EDITOR or [general] editor", .{program});
}

fn reloadFailureMessage(allocator: std.mem.Allocator, path: []const u8, err: anyerror) ![]u8 {
    const name = std.fs.path.basename(path);
    return switch (err) {
        error.FileNotFound => std.fmt.allocPrint(allocator, "Reload failed: {s} no longer exists", .{name}),
        error.AccessDenied, error.PermissionDenied => std.fmt.allocPrint(allocator, "Reload failed: permission denied reading {s}", .{name}),
        error.IsDir => std.fmt.allocPrint(allocator, "Reload failed: {s} is a directory", .{name}),
        else => std.fmt.allocPrint(allocator, "Reload failed: {s}: {s}", .{ name, @errorName(err) }),
    };
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
    // `box` is the bordered child's interior, so its rows start at 0.
    var row: usize = 0;
    while (row < help_lines.len and row < box.height) : (row += 1) {
        _ = box.print(&.{.{ .text = help_lines[row], .style = .{ .reverse = true } }}, .{
            .row_offset = @intCast(row),
            .col_offset = 1,
            .wrap = .none,
        });
    }
}

test "toVaxisSegments uses the resolved preset palette (dracula, not dark)" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\# Title
    );
    defer document.deinit(allocator);
    var rendered = try render_model.renderDocument(allocator, document, .{ .width = 20 });
    defer rendered.deinit(allocator);

    const dracula = theme_resolve.builtinResolved(allocator, "dracula");
    const dark = theme_resolve.builtinResolved(allocator, "dark");
    try std.testing.expect(!std.meta.eql(dracula.styles.heading1.fg, dark.styles.heading1.fg));

    const seg = try toVaxisSegments(allocator, rendered.lines[0], &dracula);
    defer allocator.free(seg);
    for (rendered.lines[0].spans, seg) |span, s| {
        const want = theme.vaxisStyle(theme.token(dracula.styles, span.style));
        try std.testing.expectEqual(want.fg, s.style.fg);
    }
}

test "toast/metadata panel styles derive from the resolved preset accent" {
    const allocator = std.testing.allocator;
    const pink = theme_resolve.builtinResolved(allocator, "pink");
    const dark = theme_resolve.builtinResolved(allocator, "dark");

    const pink_toast = theme.toastStyle(pink.accent, pink.base_bg);
    const dark_toast = theme.toastStyle(dark.accent, dark.base_bg);
    try std.testing.expect(!std.meta.eql(pink_toast.border.fg, dark_toast.border.fg));
    const pink_meta = theme.metadataPanelStyle(pink.accent, pink.base_bg);
    try std.testing.expectEqual(pink_toast.border.fg, pink_meta.border.fg);
    try std.testing.expect(!pink_meta.text.bold);
    try std.testing.expect(pink_toast.text.bold);
}

test "startup theme_warning surfaces in the status bar" {
    const allocator = std.testing.allocator;
    const rt = theme_resolve.builtinResolved(allocator, "dark");
    var app: App = undefined;
    try app.init(allocator, "fixture", .none, "# Title\n", "vim", &rt, "theme: unknown theme 'nope' (using dark)", true, .panel, .auto, .bridge);
    defer app.deinit();
    try std.testing.expect(app.status_message != null);
    try std.testing.expectEqualStrings("theme: unknown theme 'nope' (using dark)", app.status_message.?);
}

test "toVaxisSegments borrows render-model span text" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\# Title
    );
    defer document.deinit(allocator);
    var rendered = try render_model.renderDocument(allocator, document, .{ .width = 20 });
    defer rendered.deinit(allocator);

    const rt = theme_resolve.builtinResolved(allocator, "dark");
    const segments = try toVaxisSegments(allocator, rendered.lines[0], &rt);
    defer allocator.free(segments);

    try std.testing.expectEqual(@intFromPtr(rendered.lines[0].spans[0].text.ptr), @intFromPtr(segments[0].text.ptr));
}

test "initLoop binds loop to app-owned tty and vaxis" {
    const allocator = std.testing.allocator;

    const rt = theme_resolve.builtinResolved(allocator, "dark");
    var app: App = undefined;
    try app.init(allocator, "fixture", .none, "# Title\n", "vim", &rt, null, true, .panel, .auto, .bridge);
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

    const rt = theme_resolve.builtinResolved(allocator, "dark");
    var pager = PagerView.init(allocator, "fixture", &document, &rt, true, .bridge);
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
    const rt = theme_resolve.builtinResolved(allocator, "dark");
    var app: App = undefined;
    try app.init(allocator, "fixture", .none, content, "vim", &rt, null, true, .hidden, .auto, .bridge);
    defer app.deinit();

    try app.handleToggleMetadata();
    try std.testing.expect(!app.metadata.visible);
    try std.testing.expect(app.status_message != null);
}

test "toggle metadata opens the overlay for visible front matter" {
    const allocator = std.testing.allocator;
    const content = "---\ntitle: Shown\n---\n# Body\n";
    const rt = theme_resolve.builtinResolved(allocator, "dark");
    var app: App = undefined;
    try app.init(allocator, "fixture", .none, content, "vim", &rt, null, true, .panel, .auto, .bridge);
    defer app.deinit();

    try app.handleToggleMetadata();
    try std.testing.expect(app.metadata.visible);
}

test "opening the metadata overlay hides the inline front matter and closing restores it" {
    const allocator = std.testing.allocator;
    const content = "---\ntitle: Shown\n---\n# Body\n";
    const rt = theme_resolve.builtinResolved(allocator, "dark");
    var app: App = undefined;
    try app.init(allocator, "fixture", .none, content, "vim", &rt, null, true, .panel, .auto, .bridge);
    defer app.deinit();

    try app.pager.resize(60, 20);
    const lines_with_frontmatter = app.pager.lines.len;

    try app.handleToggleMetadata();
    try std.testing.expect(app.metadata.visible);
    try std.testing.expect(app.pager.suppress_frontmatter);
    try std.testing.expect(app.pager.lines.len < lines_with_frontmatter);

    try app.handleToggleMetadata();
    try std.testing.expect(!app.pager.suppress_frontmatter);
    try std.testing.expectEqual(lines_with_frontmatter, app.pager.lines.len);
}

test "toggle metadata is refused when the document has no front matter" {
    const allocator = std.testing.allocator;
    const content = "# Body only\n";
    const rt = theme_resolve.builtinResolved(allocator, "dark");
    var app: App = undefined;
    try app.init(allocator, "fixture", .none, content, "vim", &rt, null, true, .panel, .auto, .bridge);
    defer app.deinit();

    try app.handleToggleMetadata();
    try std.testing.expect(!app.metadata.visible);
    try std.testing.expect(app.status_message != null);
    try std.testing.expectEqualStrings("No front matter metadata in this document.", app.status_message.?);
}

test {
    _ = @import("app_test.zig");
}
