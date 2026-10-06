//! The TUI key table. One table drives key dispatch (`mapKey`), the help
//! overlay (`views/help.zig`) and the README key table (checked by a test), so
//! a binding cannot exist in one place and be missing from the others.
const std = @import("std");
const vaxis = @import("vaxis");

const Key = vaxis.Key;

pub const Action = enum {
    none,
    quit,
    toggle_help,
    edit,
    reload,
    toggle_subgraph_edges,
    toggle_metadata,
    line_up,
    line_down,
    page_up,
    page_down,
    half_page_up,
    half_page_down,
    top,
    bottom,
    follow_link,
    /// Clears the selection, else the search highlights.
    escape,
    search_start,
    search_next,
    search_prev,
    suspend_app,
};

/// Help overlay groups, in display order.
pub const Section = enum {
    move,
    search,
    file,
    view,
    other,

    pub fn title(self: Section) []const u8 {
        return switch (self) {
            .move => "Move",
            .search => "Search",
            .file => "File",
            .view => "View",
            .other => "Other",
        };
    }
};

/// One key: what the terminal reports (`codepoint` + `mods`) and how the
/// help overlay and README spell it (`name`).
pub const Chord = struct {
    codepoint: u21,
    mods: Key.Modifiers = .{},
    name: []const u8,

    pub fn matches(self: Chord, key: Key) bool {
        return key.matches(self.codepoint, self.mods);
    }
};

/// A help row. `chords` is empty for a mouse-only row, which `label` names.
pub const Binding = struct {
    section: Section,
    action: Action,
    chords: []const Chord,
    description: []const u8,
    label: ?[]const u8 = null,
};

fn plain(comptime cp: u21) Chord {
    return .{ .codepoint = cp, .name = std.fmt.comptimePrint("{u}", .{cp}) };
}

fn ctrl(comptime letter: u8) Chord {
    const name = "Ctrl-" ++ [_]u8{std.ascii.toUpper(letter)};
    return .{ .codepoint = letter, .mods = .{ .ctrl = true }, .name = name };
}

fn named(cp: u21, name: []const u8) Chord {
    return .{ .codepoint = cp, .name = name };
}

const ctrl_c = ctrl('c');
const ctrl_z = ctrl('z');

pub const bindings = [_]Binding{
    .{ .section = .move, .action = .line_down, .description = "Line down", .chords = &.{ plain('j'), named(Key.down, "↓"), ctrl('e'), ctrl('n') } },
    .{ .section = .move, .action = .line_up, .description = "Line up", .chords = &.{ plain('k'), named(Key.up, "↑"), ctrl('y'), ctrl('p') } },
    .{ .section = .move, .action = .page_down, .description = "Page down", .chords = &.{ named(' ', "Space"), plain('f'), named(Key.page_down, "PgDn"), ctrl('f') } },
    .{ .section = .move, .action = .page_up, .description = "Page up", .chords = &.{ plain('b'), named(Key.page_up, "PgUp"), ctrl('b') } },
    .{ .section = .move, .action = .half_page_down, .description = "Half page down", .chords = &.{ plain('d'), ctrl('d') } },
    .{ .section = .move, .action = .half_page_up, .description = "Half page up", .chords = &.{ plain('u'), ctrl('u') } },
    .{ .section = .move, .action = .top, .description = "Top", .chords = &.{ plain('g'), named(Key.home, "Home"), plain('<') } },
    .{ .section = .move, .action = .bottom, .description = "Bottom", .chords = &.{ plain('G'), named(Key.end, "End"), plain('>') } },
    .{ .section = .move, .action = .follow_link, .description = "Follow footnote", .chords = &.{named(Key.enter, "Enter")} },
    .{ .section = .search, .action = .search_start, .description = "Search", .chords = &.{plain('/')} },
    .{ .section = .search, .action = .search_next, .description = "Next match", .chords = &.{plain('n')} },
    .{ .section = .search, .action = .search_prev, .description = "Previous match", .chords = &.{plain('N')} },
    .{ .section = .search, .action = .escape, .description = "Clear highlights", .chords = &.{named(Key.escape, "Esc")} },
    .{ .section = .file, .action = .edit, .description = "Edit + reload", .chords = &.{plain('e')} },
    .{ .section = .file, .action = .reload, .description = "Reload", .chords = &.{plain('r')} },
    .{ .section = .view, .action = .toggle_metadata, .description = "Front matter", .chords = &.{plain('m')} },
    .{ .section = .view, .action = .toggle_subgraph_edges, .description = "Subgraph edges", .chords = &.{plain('B')} },
    .{ .section = .view, .action = .none, .description = "Select and copy", .chords = &.{}, .label = "mouse drag" },
    .{ .section = .other, .action = .toggle_help, .description = "Toggle help", .chords = &.{ plain('?'), named(Key.f1, "F1") } },
    .{ .section = .other, .action = .suspend_app, .description = "Suspend", .chords = &.{ctrl_z} },
    .{ .section = .other, .action = .quit, .description = "Quit", .chords = &.{ plain('q'), ctrl_c } },
};

pub fn mapKey(key: Key) Action {
    for (bindings) |binding| {
        for (binding.chords) |chord| {
            if (chord.matches(key)) return binding.action;
        }
    }
    return .none;
}

pub fn isCtrlC(key: Key) bool {
    return ctrl_c.matches(key);
}

/// What a key does while the '/' prompt is open: everything except the
/// control keys below edits the query.
pub const PromptAction = union(enum) {
    cancel,
    /// Cancel the prompt, then suspend (Ctrl-Z).
    suspend_app,
    commit,
    backspace,
    clear,
    insert: []const u8,
    ignore,
};

pub fn mapPromptKey(key: Key) PromptAction {
    if (ctrl_c.matches(key)) return .cancel;
    if (ctrl_z.matches(key)) return .suspend_app;
    if (key.matches(Key.escape, .{}) or key.matches('g', .{ .ctrl = true })) return .cancel;
    if (key.matches(Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) return .commit;
    if (key.matches(Key.backspace, .{}) or key.matches('h', .{ .ctrl = true })) return .backspace;
    if (key.matches('u', .{ .ctrl = true })) return .clear;
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return .ignore;
    if (key.text) |text| {
        if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) return .{ .insert = text };
    }
    return .ignore;
}

/// Rewrites a Home/End key sequence at the start of `seq` in place, before
/// the vaxis parser sees it. vaxis decodes `CSI 7 ~` / `CSI 8 ~` (rxvt) and
/// `CSI H` / `CSI F`, but drops `CSI 1 ~` / `CSI 4 ~` — what tmux, GNU screen
/// and the Linux console send — so they become `CSI 7 ~` / `CSI 8 ~`, keeping
/// any modifier parameter. A sequence that is not complete yet is left alone;
/// the caller retries once more bytes arrive.
pub fn normalizeHomeEnd(seq: []u8) void {
    if (seq.len < 4 or seq[0] != 0x1b or seq[1] != '[') return;
    if (seq[2] != '1' and seq[2] != '4') return;
    if (seq[3] != '~' and seq[3] != ';') return;
    var i: usize = 3;
    while (i < seq.len) : (i += 1) {
        const c = seq[i];
        if (c >= 0x40 and c <= 0x7e) break;
        if (c < 0x20 or c > 0x3f) return;
    }
    if (i == seq.len or seq[i] != '~') return;
    seq[2] = if (seq[2] == '1') '7' else '8';
}

test {
    _ = @import("input_test.zig");
}
