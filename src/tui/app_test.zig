const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("app.zig");
const theme_resolve = @import("../core/theme/resolve.zig");

const App = app_mod.App;

fn key(text: []const u8) vaxis.Key {
    const cp = std.unicode.utf8Decode(text) catch unreachable;
    return .{ .codepoint = cp, .text = text };
}

fn special(cp: u21) vaxis.Key {
    return .{ .codepoint = cp };
}

fn ctrl(cp: u21) vaxis.Key {
    return .{ .codepoint = cp, .mods = .{ .ctrl = true } };
}

fn typeText(app: *App, text: []const u8) !void {
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepointSlice()) |slice| {
        try std.testing.expect(!try app.handleKeyPress(key(slice)));
    }
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    rt: theme_resolve.ResolvedTheme,
    app: App = undefined,

    fn init(allocator: std.mem.Allocator, content: []const u8, editor_command: []const u8) !*Fixture {
        const self = try allocator.create(Fixture);
        errdefer allocator.destroy(self);
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(.{ .sub_path = "doc.md", .data = content });
        self.path = try self.tmp.dir.realpathAlloc(allocator, "doc.md");
        errdefer allocator.free(self.path);
        self.rt = theme_resolve.builtinResolved(allocator, "dark");
        try self.app.init(allocator, self.path, .{ .file = self.path }, content, editor_command, &self.rt, null, true, .panel, .auto, .bridge);
        try self.app.pager.resize(80, 10);
        return self;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.app.deinit();
        allocator.free(self.path);
        self.tmp.cleanup();
        allocator.destroy(self);
    }

    fn writeScript(self: *Fixture, allocator: std.mem.Allocator, name: []const u8, body: []const u8) ![]u8 {
        const file = try self.tmp.dir.createFile(name, .{ .mode = 0o755 });
        defer file.close();
        try file.writeAll(body);
        return self.tmp.dir.realpathAlloc(allocator, name);
    }

    fn status(self: *Fixture) []const u8 {
        return self.app.status_message orelse "";
    }
};

const sample =
    \\# Mermaid notes
    \\
    \\First mermaid paragraph.
    \\
    \\Plain text in between.
    \\
    \\Another MERMAID mention and mermaid again.
    \\
;

test "reload of a deleted file keeps the document and explains why" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);
    const lines_before = fx.app.pager.lines.len;

    try fx.tmp.dir.deleteFile("doc.md");
    try std.testing.expect(!try fx.app.handleKeyPress(key("r")));

    try std.testing.expectEqualStrings("Reload failed: doc.md no longer exists", fx.status());
    try std.testing.expectEqualStrings(sample, fx.app.current_content);
    try std.testing.expectEqual(lines_before, fx.app.pager.lines.len);
}

test "reload of invalid UTF-8 warns and keeps the warning as long as a startup warning" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);

    try fx.tmp.dir.writeFile(.{ .sub_path = "doc.md", .data = "# Bad \xff byte\n" });
    try std.testing.expect(!try fx.app.handleKeyPress(key("r")));
    try std.testing.expect(std.mem.indexOf(u8, fx.status(), "invalid UTF-8") != null);
    try std.testing.expectEqualStrings("# Bad \u{FFFD} byte\n", fx.app.current_content);

    const now = std.time.milliTimestamp();
    fx.app.expireTransient(now + 3000);
    try std.testing.expect(fx.app.status_message != null);
    fx.app.expireTransient(now + 6000);
    try std.testing.expect(fx.app.status_message == null);
}

test "edit with a missing editor reports it and keeps running" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "/nonexistent-dir/nosuchedit --wait");
    defer fx.deinit(allocator);

    try std.testing.expect(!try fx.app.handleKeyPress(key("e")));
    try std.testing.expectEqualStrings("Editor '/nonexistent-dir/nosuchedit' not found — set $EDITOR or [general] editor", fx.status());
    try std.testing.expectEqualStrings(sample, fx.app.current_content);
}

test "edit runs a command with arguments and reloads the result" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);
    const script = try fx.writeScript(allocator, "fake-editor",
        \\#!/bin/sh
        \\[ "$1" = "--wait" ] || exit 9
        \\printf '# Edited\n' > "$2"
        \\
    );
    defer allocator.free(script);
    const command = try std.fmt.allocPrint(allocator, "'{s}' --wait", .{script});
    defer allocator.free(command);
    fx.app.editor_command = command;

    try std.testing.expect(!try fx.app.handleKeyPress(key("e")));
    try std.testing.expectEqualStrings("Reloaded doc.md", fx.status());
    try std.testing.expectEqualStrings("# Edited\n", fx.app.current_content);
}

test "an editor that exits with an error still reloads and says so" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);
    const script = try fx.writeScript(allocator, "bad-editor", "#!/bin/sh\nexit 1\n");
    defer allocator.free(script);
    fx.app.editor_command = script;

    try std.testing.expect(!try fx.app.handleKeyPress(key("e")));
    try std.testing.expect(std.mem.endsWith(u8, fx.status(), "' exited with an error; reloaded doc.md"));
}

test "edit and reload are refused for stdin input" {
    const allocator = std.testing.allocator;
    const rt = theme_resolve.builtinResolved(allocator, "dark");
    var app: App = undefined;
    try app.init(allocator, "stdin", .stdin, sample, "vim", &rt, null, true, .panel, .auto, .bridge);
    defer app.deinit();

    try std.testing.expect(!try app.handleKeyPress(key("e")));
    try std.testing.expectEqualStrings("Edit mode is only available for file inputs.", app.status_message.?);
    try std.testing.expect(!try app.handleKeyPress(key("r")));
    try std.testing.expectEqualStrings("Reload is only available for file inputs.", app.status_message.?);
}

test "slash search counts matches, n/N step with wraparound" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);

    try std.testing.expect(!try fx.app.handleKeyPress(key("/")));
    try std.testing.expect(fx.app.search_prompt.active);
    try typeText(&fx.app, "mermaid");
    try std.testing.expect(!try fx.app.handleKeyPress(special(vaxis.Key.enter)));
    try std.testing.expect(!fx.app.search_prompt.active);
    try std.testing.expectEqualStrings("[1/4] /mermaid", fx.status());

    try std.testing.expect(!try fx.app.handleKeyPress(key("n")));
    try std.testing.expectEqualStrings("[2/4] /mermaid", fx.status());
    try std.testing.expect(!try fx.app.handleKeyPress(key("N")));
    try std.testing.expect(!try fx.app.handleKeyPress(key("N")));
    try std.testing.expectEqualStrings("[4/4] /mermaid", fx.status());
}

test "search prompt: q is text, Esc cancels, Ctrl-C cancels, misses are reported" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);

    _ = try fx.app.handleKeyPress(key("/"));
    try typeText(&fx.app, "zzq");
    try std.testing.expectEqualStrings("zzq", fx.app.search_prompt.query.items);
    try std.testing.expect(!try fx.app.handleKeyPress(special(vaxis.Key.escape)));
    try std.testing.expect(!fx.app.search_prompt.active);
    try std.testing.expect(!fx.app.pager.search.hasPattern());

    _ = try fx.app.handleKeyPress(key("/"));
    try typeText(&fx.app, "zzz");
    _ = try fx.app.handleKeyPress(special(vaxis.Key.enter));
    try std.testing.expectEqualStrings("Pattern not found: zzz", fx.status());

    _ = try fx.app.handleKeyPress(key("/"));
    try typeText(&fx.app, "mer");
    try std.testing.expect(!try fx.app.handleKeyPress(ctrl('c')));
    try std.testing.expect(!fx.app.search_prompt.active);
    try std.testing.expectEqualStrings("zzz", fx.app.pager.search.pattern.items);
    // Outside the prompt Ctrl-C quits.
    try std.testing.expect(try fx.app.handleKeyPress(ctrl('c')));
}

test "Ctrl-Z in the prompt cancels it before suspending" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);
    _ = try fx.app.handleKeyPress(key("/"));
    try typeText(&fx.app, "mermaid");
    try std.testing.expect(fx.app.pager.search.hasPattern());
    try std.testing.expect(!try fx.app.handleKeyPress(ctrl('z')));
    try std.testing.expect(!fx.app.search_prompt.active);
    try std.testing.expect(!fx.app.pager.search.hasPattern());
}

test "Esc clears the selection first, then the search highlights" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);
    _ = try fx.app.handleKeyPress(key("/"));
    try typeText(&fx.app, "mermaid");
    _ = try fx.app.handleKeyPress(special(vaxis.Key.enter));
    fx.app.pager.beginSelectionAt(0, 0);
    fx.app.pager.extendSelectionAt(0, 5);

    _ = try fx.app.handleKeyPress(special(vaxis.Key.escape));
    try std.testing.expect(!fx.app.pager.selection.active);
    try std.testing.expect(fx.app.pager.search.hasPattern());

    _ = try fx.app.handleKeyPress(special(vaxis.Key.escape));
    try std.testing.expect(!fx.app.pager.search.hasPattern());
    try std.testing.expectEqual(@as(usize, 0), fx.app.pager.search.matches.items.len);
}

test "help: ? and F1 open it, q and Esc close it without quitting, Ctrl-C quits" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);

    _ = try fx.app.handleKeyPress(key("?"));
    try std.testing.expect(fx.app.view_mode == .help);
    try std.testing.expect(!try fx.app.handleKeyPress(key("q")));
    try std.testing.expect(fx.app.view_mode == .pager);

    _ = try fx.app.handleKeyPress(special(vaxis.Key.f1));
    try std.testing.expect(fx.app.view_mode == .help);
    // Movement scrolls the card, not the document.
    fx.app.help.max_scroll = 5;
    fx.app.help.page_rows = 3;
    _ = try fx.app.handleKeyPress(key("j"));
    _ = try fx.app.handleKeyPress(special(vaxis.Key.page_down));
    try std.testing.expectEqual(@as(usize, 4), fx.app.help.scroll);
    _ = try fx.app.handleKeyPress(.{ .codepoint = 'G', .text = "G" });
    try std.testing.expectEqual(@as(usize, 5), fx.app.help.scroll);
    try std.testing.expectEqual(@as(usize, 0), fx.app.pager.viewport.top);
    // Keys outside the overlay's set do nothing while it is open.
    _ = try fx.app.handleKeyPress(key("e"));
    try std.testing.expect(fx.app.view_mode == .help);
    _ = try fx.app.handleKeyPress(special(vaxis.Key.escape));
    try std.testing.expect(fx.app.view_mode == .pager);

    _ = try fx.app.handleKeyPress(key("?"));
    try std.testing.expectEqual(@as(usize, 0), fx.app.help.scroll);
    try std.testing.expect(try fx.app.handleKeyPress(ctrl('c')));
}

test "B toggles subgraph edges" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);

    _ = try fx.app.handleKeyPress(.{ .codepoint = 'B', .text = "B" });
    try std.testing.expectEqualStrings("Subgraph edges: cross", fx.status());
    try std.testing.expect(fx.app.mermaid_subgraph_edges == .cross);
}

test "half-page and less-style movement keys scroll the document" {
    const allocator = std.testing.allocator;
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(allocator);
    for (0..100) |i| {
        const line = try std.fmt.allocPrint(allocator, "Line {d}\n\n", .{i});
        defer allocator.free(line);
        try long.appendSlice(allocator, line);
    }
    const fx = try Fixture.init(allocator, long.items, "vim");
    defer fx.deinit(allocator);
    const view = &fx.app.pager.viewport;

    _ = try fx.app.handleKeyPress(key("d"));
    try std.testing.expectEqual(@as(usize, 5), view.top);
    _ = try fx.app.handleKeyPress(ctrl('e'));
    try std.testing.expectEqual(@as(usize, 6), view.top);
    _ = try fx.app.handleKeyPress(key("f"));
    try std.testing.expectEqual(@as(usize, 16), view.top);
    _ = try fx.app.handleKeyPress(ctrl('u'));
    try std.testing.expectEqual(@as(usize, 11), view.top);
    _ = try fx.app.handleKeyPress(key(">"));
    try std.testing.expectEqual(view.total - view.height, view.top);
    _ = try fx.app.handleKeyPress(key("<"));
    try std.testing.expectEqual(@as(usize, 0), view.top);
}

test "status messages are transient and outlive scrolling" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);
    _ = try fx.app.handleKeyPress(key("r"));
    const shown_at = std.time.milliTimestamp();
    try std.testing.expectEqualStrings("Reloaded doc.md", fx.status());
    _ = try fx.app.handleKeyPress(key("j"));
    fx.app.expireTransient(shown_at - 100);
    try std.testing.expectEqualStrings("Reloaded doc.md", fx.status());
    fx.app.expireTransient(shown_at + app_mod.message_duration_ms + 1000);
    try std.testing.expect(fx.app.status_message == null);
}

test "copy reports success only when the clipboard took it" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);

    try fx.app.reportCopy("hello", .{ .failed = .too_large });
    try std.testing.expect(fx.app.toast_message == null);
    try std.testing.expect(std.mem.startsWith(u8, fx.status(), "Copy failed: too large for OSC 52"));

    try fx.app.reportCopy("hello", .{ .copied = .osc52 });
    try std.testing.expectEqualStrings("Copied \"hello\"", fx.app.toast_message.?);
}

test "n without a previous search explains how to start one" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);
    _ = try fx.app.handleKeyPress(key("n"));
    try std.testing.expectEqualStrings("No previous search — press / to search", fx.status());
}

test "matches are recomputed on resize and reload" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);

    _ = try fx.app.handleKeyPress(key("/"));
    try typeText(&fx.app, "mermaid");
    _ = try fx.app.handleKeyPress(special(vaxis.Key.enter));
    const wide_lines = fx.app.pager.lines.len;

    try fx.app.pager.resize(12, 10);
    try std.testing.expect(fx.app.pager.lines.len > wide_lines);
    try std.testing.expectEqual(@as(usize, 4), fx.app.pager.search.matches.items.len);
    try std.testing.expect(fx.app.pager.search.currentMatch() != null);
    for (fx.app.pager.search.matches.items) |match| {
        try std.testing.expect(match.line < fx.app.pager.lines.len);
        try std.testing.expect(match.col_end <= 12);
    }

    try fx.tmp.dir.writeFile(.{ .sub_path = "doc.md", .data = "mermaid only once\n" });
    _ = try fx.app.handleKeyPress(key("r"));
    try std.testing.expectEqual(@as(usize, 1), fx.app.pager.search.matches.items.len);
}

test "resuming picks up a terminal resized while the TUI was stopped" {
    const resize = app_mod.resizeOnResume;
    const small: vaxis.Winsize = .{ .rows = 20, .cols = 60, .x_pixel = 0, .y_pixel = 0 };
    try std.testing.expectEqual(@as(?vaxis.Winsize, small), resize(100, 30, small));
    // Unchanged, unknown or empty sizes keep the current layout.
    try std.testing.expectEqual(@as(?vaxis.Winsize, null), resize(60, 20, small));
    try std.testing.expectEqual(@as(?vaxis.Winsize, null), resize(100, 30, null));
    const empty: vaxis.Winsize = .{ .rows = 0, .cols = 0, .x_pixel = 0, .y_pixel = 0 };
    try std.testing.expectEqual(@as(?vaxis.Winsize, null), resize(100, 30, empty));
}

test "resuming resizes only after entering the alternate screen" {
    const allocator = std.testing.allocator;
    const ws: vaxis.Winsize = .{ .rows = 30, .cols = 120, .x_pixel = 0, .y_pixel = 0 };
    // After Ctrl-Z vaxis still believes it is on the alt screen; after the
    // editor it knows it is not. Either way no clear may precede smcup.
    for ([_]bool{ true, false }) |was_alt| {
        var vx = try vaxis.init(allocator, .{});
        defer vx.deinit(allocator, @constCast(&std.Io.Writer.failing));
        vx.state.alt_screen = was_alt;
        vx.state.cursor.row = 5;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try app_mod.enterAltScreenResized(&vx, allocator, &out.writer, ws);
        const bytes = out.written();
        const smcup = std.mem.indexOf(u8, bytes, vaxis.ctlseqs.smcup) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 0), smcup);
        try std.testing.expect(std.mem.indexOf(u8, bytes, vaxis.ctlseqs.erase_below_cursor).? > smcup);
        try std.testing.expectEqual(@as(u16, 120), vx.screen.width);
        vx.state.alt_screen = false;
    }
}
