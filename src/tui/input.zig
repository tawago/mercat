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
};

pub fn mapKey(key: vaxis.Key) Action {
    if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) return .quit;
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
