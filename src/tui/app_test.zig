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

test "reload picks up changes on disk" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);

    try fx.tmp.dir.writeFile(.{ .sub_path = "doc.md", .data = "# Changed\n" });
    try std.testing.expect(!try fx.app.handleKeyPress(key("r")));
    try std.testing.expectEqualStrings("Reloaded doc.md", fx.status());
    try std.testing.expectEqualStrings("# Changed\n", fx.app.current_content);
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

test "smart case: an uppercase query matches exactly" {
    const allocator = std.testing.allocator;
    const fx = try Fixture.init(allocator, sample, "vim");
    defer fx.deinit(allocator);

    _ = try fx.app.handleKeyPress(key("/"));
    try typeText(&fx.app, "MERMAID");
    _ = try fx.app.handleKeyPress(special(vaxis.Key.enter));
    try std.testing.expectEqualStrings("[1/1] /MERMAID", fx.status());
}

test "search prompt: q is text, Esc cancels, Ctrl-C quits, misses are reported" {
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
    try std.testing.expect(try fx.app.handleKeyPress(ctrl('c')));
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
