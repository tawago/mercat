const std = @import("std");
const vaxis = @import("vaxis");

pub const Action = enum {
    none,
    quit,
    toggle_help,
    edit,
    reload,
    cycle_layout,
    toggle_subgraph_edges,
    toggle_metadata,
    line_up,
    line_down,
    page_up,
    page_down,
    top,
    bottom,
    follow_link,
    clear_selection,
    search_start,
    search_next,
    search_prev,
    suspend_app,
};

pub fn mapKey(key: vaxis.Key) Action {
    if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) return .quit;
    if (key.matches('z', .{ .ctrl = true })) return .suspend_app;
    if (key.matches('/', .{})) return .search_start;
    if (key.matches('n', .{})) return .search_next;
    if (key.matches('N', .{})) return .search_prev;
    if (key.matches('?', .{}) or key.matches('h', .{})) return .toggle_help;
    if (key.matches('e', .{})) return .edit;
    if (key.matches('r', .{})) return .reload;
    if (key.matches('l', .{})) return .cycle_layout;
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) return .line_up;
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) return .line_down;
    if (key.matches('b', .{})) return .toggle_subgraph_edges;
    if (key.matches('m', .{})) return .toggle_metadata;
    if (key.matches('b', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) return .page_up;
    if (key.matches(' ', .{}) or key.matches(vaxis.Key.page_down, .{})) return .page_down;
    if (key.matches('g', .{})) return .top;
    if (key.matches('G', .{})) return .bottom;
    if (key.matches(vaxis.Key.home, .{})) return .top;
    if (key.matches(vaxis.Key.end, .{})) return .bottom;
    if (key.matches('f', .{}) or key.matches(vaxis.Key.enter, .{})) return .follow_link;
    if (key.matches(vaxis.Key.escape, .{})) return .clear_selection;
    return .none;
}

/// What a key does while the '/' prompt is open: everything except Ctrl-C
/// edits the query.
pub const PromptAction = union(enum) {
    quit,
    cancel,
    commit,
    backspace,
    clear,
    insert: []const u8,
    ignore,
};

pub fn mapPromptKey(key: vaxis.Key) PromptAction {
    if (key.matches('c', .{ .ctrl = true })) return .quit;
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('g', .{ .ctrl = true })) return .cancel;
    if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) return .commit;
    if (key.matches(vaxis.Key.backspace, .{}) or key.matches('h', .{ .ctrl = true })) return .backspace;
    if (key.matches('u', .{ .ctrl = true })) return .clear;
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return .ignore;
    if (key.text) |text| {
        if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) return .{ .insert = text };
    }
    return .ignore;
}

test "search keys map to search actions" {
    try std.testing.expectEqual(Action.search_start, mapKey(.{ .codepoint = '/', .text = "/" }));
    try std.testing.expectEqual(Action.search_next, mapKey(.{ .codepoint = 'n', .text = "n" }));
    try std.testing.expectEqual(Action.search_prev, mapKey(.{ .codepoint = 'N', .text = "N", .shifted_codepoint = 'N' }));
    try std.testing.expectEqual(Action.suspend_app, mapKey(.{ .codepoint = 'z', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(Action.quit, mapKey(.{ .codepoint = 'q', .text = "q" }));
}

test "prompt keys edit the query; only Ctrl-C quits" {
    try std.testing.expectEqualStrings("q", mapPromptKey(.{ .codepoint = 'q', .text = "q" }).insert);
    try std.testing.expectEqualStrings("é", mapPromptKey(.{ .codepoint = 0xe9, .text = "é" }).insert);
    try std.testing.expectEqual(PromptAction.quit, mapPromptKey(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(PromptAction.cancel, mapPromptKey(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(PromptAction.commit, mapPromptKey(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expectEqual(PromptAction.backspace, mapPromptKey(.{ .codepoint = vaxis.Key.backspace }));
    try std.testing.expectEqual(PromptAction.clear, mapPromptKey(.{ .codepoint = 'u', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(PromptAction.ignore, mapPromptKey(.{ .codepoint = vaxis.Key.up }));
}
