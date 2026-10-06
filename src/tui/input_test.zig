const std = @import("std");
const vaxis = @import("vaxis");
const input = @import("input.zig");

const Action = input.Action;
const Key = vaxis.Key;
const mapKey = input.mapKey;
const mapPromptKey = input.mapPromptKey;
const PromptAction = input.PromptAction;

fn text(comptime s: []const u8) Key {
    const cp = comptime std.unicode.utf8Decode(s) catch unreachable;
    return .{ .codepoint = cp, .text = s };
}

fn special(cp: u21) Key {
    return .{ .codepoint = cp };
}

fn ctrl(cp: u21) Key {
    return .{ .codepoint = cp, .mods = .{ .ctrl = true } };
}

test "search keys map to search actions" {
    try std.testing.expectEqual(Action.search_start, mapKey(text("/")));
    try std.testing.expectEqual(Action.search_next, mapKey(text("n")));
    try std.testing.expectEqual(Action.search_prev, mapKey(.{ .codepoint = 'N', .text = "N", .shifted_codepoint = 'N' }));
    try std.testing.expectEqual(Action.suspend_app, mapKey(ctrl('z')));
    try std.testing.expectEqual(Action.quit, mapKey(text("q")));
    try std.testing.expectEqual(Action.quit, mapKey(ctrl('c')));
}

test "less/vim movement keys" {
    const cases = [_]struct { key: Key, action: Action }{
        .{ .key = text("j"), .action = .line_down },
        .{ .key = special(Key.down), .action = .line_down },
        .{ .key = ctrl('e'), .action = .line_down },
        .{ .key = ctrl('n'), .action = .line_down },
        .{ .key = text("k"), .action = .line_up },
        .{ .key = special(Key.up), .action = .line_up },
        .{ .key = ctrl('y'), .action = .line_up },
        .{ .key = ctrl('p'), .action = .line_up },
        .{ .key = text(" "), .action = .page_down },
        .{ .key = text("f"), .action = .page_down },
        .{ .key = special(Key.page_down), .action = .page_down },
        .{ .key = ctrl('f'), .action = .page_down },
        .{ .key = text("b"), .action = .page_up },
        .{ .key = special(Key.page_up), .action = .page_up },
        .{ .key = ctrl('b'), .action = .page_up },
        .{ .key = text("d"), .action = .half_page_down },
        .{ .key = ctrl('d'), .action = .half_page_down },
        .{ .key = text("u"), .action = .half_page_up },
        .{ .key = ctrl('u'), .action = .half_page_up },
        .{ .key = text("g"), .action = .top },
        .{ .key = special(Key.home), .action = .top },
        .{ .key = text("<"), .action = .top },
        .{ .key = .{ .codepoint = 'G', .text = "G" }, .action = .bottom },
        .{ .key = special(Key.end), .action = .bottom },
        .{ .key = text(">"), .action = .bottom },
        .{ .key = special(Key.enter), .action = .follow_link },
        .{ .key = special(Key.escape), .action = .escape },
        .{ .key = text("?"), .action = .toggle_help },
        .{ .key = special(Key.f1), .action = .toggle_help },
        .{ .key = text("e"), .action = .edit },
        .{ .key = text("r"), .action = .reload },
        .{ .key = text("m"), .action = .toggle_metadata },
        .{ .key = .{ .codepoint = 'B', .text = "B" }, .action = .toggle_subgraph_edges },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.action, mapKey(case.key));
    }
}

test "B toggles subgraph edges (kitty reports shift + b); h and l are free" {
    const kitty_shift_b: Key = .{ .codepoint = 'b', .shifted_codepoint = 'B', .mods = .{ .shift = true }, .text = "B" };
    try std.testing.expectEqual(Action.toggle_subgraph_edges, mapKey(kitty_shift_b));
    try std.testing.expectEqual(Action.page_up, mapKey(text("b")));
    try std.testing.expectEqual(Action.none, mapKey(text("h")));
    try std.testing.expectEqual(Action.none, mapKey(text("l")));
}

test "every binding has a unique chord and every action but none is reachable" {
    for (input.bindings, 0..) |binding, i| {
        for (binding.chords) |chord| {
            const key: Key = .{ .codepoint = chord.codepoint, .mods = chord.mods };
            try std.testing.expectEqual(binding.action, mapKey(key));
            for (input.bindings[i + 1 ..]) |other| {
                for (other.chords) |other_chord| {
                    try std.testing.expect(!std.mem.eql(u8, chord.name, other_chord.name));
                }
            }
        }
    }
    inline for (std.meta.fields(Action)) |field| {
        const action: Action = @enumFromInt(field.value);
        if (action == .none) continue;
        var found = false;
        for (input.bindings) |binding| found = found or binding.action == action;
        try std.testing.expect(found);
    }
}

/// The rows of the README "TUI Key Bindings" table.
fn readmeKeyTable(readme: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, readme, "## TUI Key Bindings") orelse return error.NoKeyTable;
    const rest = readme[start..];
    const end = std.mem.indexOfPos(u8, rest, 3, "\n## ") orelse rest.len;
    return rest[0..end];
}

test "the README key table lists every binding" {
    const table = try readmeKeyTable(@embedFile("readme_md"));
    var buf: [64]u8 = undefined;
    for (input.bindings) |binding| {
        if (binding.label) |label| {
            try expectInTable(table, label);
        }
        for (binding.chords) |chord| {
            const quoted = try std.fmt.bufPrint(&buf, "`{s}`", .{chord.name});
            try expectInTable(table, quoted);
        }
    }
}

fn expectInTable(table: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, table, needle) == null) {
        std.debug.print("README key table is missing {s}\n", .{needle});
        return error.MissingFromReadme;
    }
}

test "prompt keys edit the query; Ctrl-C and Esc cancel, Ctrl-Z suspends" {
    try std.testing.expectEqualStrings("q", mapPromptKey(text("q")).insert);
    try std.testing.expectEqualStrings("é", mapPromptKey(text("é")).insert);
    try std.testing.expectEqual(PromptAction.cancel, mapPromptKey(ctrl('c')));
    try std.testing.expectEqual(PromptAction.suspend_app, mapPromptKey(ctrl('z')));
    try std.testing.expectEqual(PromptAction.cancel, mapPromptKey(special(Key.escape)));
    try std.testing.expectEqual(PromptAction.commit, mapPromptKey(special(Key.enter)));
    try std.testing.expectEqual(PromptAction.backspace, mapPromptKey(special(Key.backspace)));
    try std.testing.expectEqual(PromptAction.clear, mapPromptKey(ctrl('u')));
    try std.testing.expectEqual(PromptAction.ignore, mapPromptKey(special(Key.up)));
}

fn parseKey(bytes: []const u8) !?Key {
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..bytes.len], bytes);
    input.normalizeHomeEnd(buf[0..bytes.len]);
    var parser: vaxis.Parser = .{};
    const result = try parser.parse(buf[0..bytes.len], null);
    try std.testing.expectEqual(bytes.len, result.n);
    const event = result.event orelse return null;
    return switch (event) {
        .key_press => |k| k,
        else => null,
    };
}

test "Home/End: CSI 1~ / 4~ (tmux, screen, linux console) decode like 7~ / 8~ and H / F" {
    const forms = [_]struct { bytes: []const u8, cp: u21 }{
        .{ .bytes = "\x1b[1~", .cp = Key.home },
        .{ .bytes = "\x1b[4~", .cp = Key.end },
        .{ .bytes = "\x1b[7~", .cp = Key.home },
        .{ .bytes = "\x1b[8~", .cp = Key.end },
        .{ .bytes = "\x1b[H", .cp = Key.home },
        .{ .bytes = "\x1b[F", .cp = Key.end },
    };
    for (forms) |form| {
        const key = (try parseKey(form.bytes)) orelse return error.NotDecoded;
        try std.testing.expectEqual(form.cp, key.codepoint);
    }
    try std.testing.expectEqual(Action.top, mapKey((try parseKey("\x1b[1~")).?));
    try std.testing.expectEqual(Action.bottom, mapKey((try parseKey("\x1b[4~")).?));
    const ctrl_home = (try parseKey("\x1b[1;5~")).?;
    try std.testing.expectEqual(Key.home, ctrl_home.codepoint);
    try std.testing.expect(ctrl_home.mods.ctrl);
}

test "normalizeHomeEnd leaves other sequences alone" {
    const untouched = [_][]const u8{
        "\x1b[1;5A", // Ctrl-Up
        "\x1b[15~", // F5
        "\x1b[11~", // F1
        "\x1b[4", // incomplete
        "\x1b[1", // incomplete
        "1~",
        "\x1b[2~",
    };
    for (untouched) |seq| {
        var buf: [16]u8 = undefined;
        @memcpy(buf[0..seq.len], seq);
        input.normalizeHomeEnd(buf[0..seq.len]);
        try std.testing.expectEqualStrings(seq, buf[0..seq.len]);
    }
}
