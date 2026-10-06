//! Incremental, smart-case text search over the pager's rendered lines.
const std = @import("std");
const unicode = @import("unicode");
const line_mod = @import("../core/markdown/render/line.zig");
const Viewport = @import("widgets/viewport.zig").Viewport;

const Line = line_mod.Line;

/// One occurrence, in display columns of a rendered line.
pub const Match = struct {
    line: usize,
    col_start: usize,
    col_end: usize,
};

pub const Highlight = enum { none, match, current };

pub const Direction = enum { forward, backward };

/// Smart case: a pattern with any uppercase ASCII letter matches case
/// sensitively; an all-lowercase pattern ignores case.
pub fn isCaseSensitive(pattern: []const u8) bool {
    for (pattern) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

/// Appends every non-overlapping occurrence of `pattern` in `text` (a whole
/// rendered line) to `out`, converting byte offsets to display columns.
pub fn findInLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Match),
    line_idx: usize,
    text: []const u8,
    pattern: []const u8,
    case_sensitive: bool,
) !void {
    if (pattern.len == 0) return;
    var pos: usize = 0;
    var col: usize = 0;
    var col_pos: usize = 0;
    while (pos + pattern.len <= text.len) {
        const found = if (case_sensitive)
            std.mem.indexOfPos(u8, text, pos, pattern)
        else
            std.ascii.indexOfIgnoreCasePos(text, pos, pattern);
        const start = found orelse break;
        const end = start + pattern.len;
        col += unicode.displayWidth(text[col_pos..start]);
        const width = unicode.displayWidth(text[start..end]);
        try out.append(allocator, .{ .line = line_idx, .col_start = col, .col_end = col + @max(width, 1) });
        col += width;
        col_pos = end;
        pos = end;
    }
}

pub const Search = struct {
    allocator: std.mem.Allocator,
    pattern: std.ArrayList(u8) = .empty,
    matches: std.ArrayList(Match) = .empty,
    current: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) Search {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Search) void {
        self.pattern.deinit(self.allocator);
        self.matches.deinit(self.allocator);
    }

    pub fn hasPattern(self: Search) bool {
        return self.pattern.items.len != 0;
    }

    /// Replaces the pattern and recomputes matches over `lines`; no match is
    /// current until `selectFrom`/`step` picks one.
    pub fn setPattern(self: *Search, pattern: []const u8, lines: []const Line) !void {
        self.pattern.clearRetainingCapacity();
        try self.pattern.appendSlice(self.allocator, pattern);
        try self.recompute(lines);
    }

    pub fn clear(self: *Search) void {
        self.pattern.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.current = null;
    }

    /// Re-runs the pattern over freshly rendered lines (after a reflow,
    /// resize or reload). The current match is dropped; callers reselect.
    pub fn recompute(self: *Search, lines: []const Line) !void {
        self.matches.clearRetainingCapacity();
        self.current = null;
        if (!self.hasPattern()) return;
        const case_sensitive = isCaseSensitive(self.pattern.items);
        for (lines, 0..) |line, idx| {
            const text = try line.joinedText(self.allocator);
            defer self.allocator.free(text);
            try findInLine(self.allocator, &self.matches, idx, text, self.pattern.items, case_sensitive);
        }
    }

    /// Makes current the first match on or after `line` (forward) or the last
    /// match before `line` (backward), wrapping around the document.
    pub fn selectFrom(self: *Search, line: usize, direction: Direction) ?Match {
        const items = self.matches.items;
        if (items.len == 0) {
            self.current = null;
            return null;
        }
        const first_at_or_after = firstIndexAtOrAfter(items, line);
        const index = switch (direction) {
            .forward => if (first_at_or_after == items.len) 0 else first_at_or_after,
            .backward => if (first_at_or_after == 0) items.len - 1 else first_at_or_after - 1,
        };
        self.current = index;
        return items[index];
    }

    /// Moves to the next/previous match with wraparound. Without a current
    /// match (or when it scrolled out of `view`), starts from the view.
    pub fn step(self: *Search, direction: Direction, view: Viewport) ?Match {
        const items = self.matches.items;
        if (items.len == 0) {
            self.current = null;
            return null;
        }
        if (self.current) |cur| {
            const line = items[cur].line;
            if (line >= view.top and line < view.visibleEnd()) {
                const index = switch (direction) {
                    .forward => (cur + 1) % items.len,
                    .backward => (cur + items.len - 1) % items.len,
                };
                self.current = index;
                return items[index];
            }
        }
        return switch (direction) {
            .forward => self.selectFrom(view.top, .forward),
            .backward => self.selectFrom(view.visibleEnd(), .backward),
        };
    }

    pub fn currentMatch(self: Search) ?Match {
        const index = self.current orelse return null;
        if (index >= self.matches.items.len) return null;
        return self.matches.items[index];
    }

    /// The matches on one rendered line, in column order.
    pub fn matchesOnLine(self: Search, line: usize) []const Match {
        const items = self.matches.items;
        const start = firstIndexAtOrAfter(items, line);
        var end = start;
        while (end < items.len and items[end].line == line) end += 1;
        return items[start..end];
    }

    /// Whether `match` (an element of `matchesOnLine`) is the current match.
    pub fn isCurrent(self: Search, match: Match) bool {
        const cur = self.currentMatch() orelse return false;
        return cur.line == match.line and cur.col_start == match.col_start;
    }

    /// "[3/17] /pattern", or "Pattern not found: pattern".
    pub fn statusText(self: Search, allocator: std.mem.Allocator) ![]u8 {
        if (self.matches.items.len == 0) {
            return std.fmt.allocPrint(allocator, "Pattern not found: {s}", .{self.pattern.items});
        }
        const position = if (self.current) |cur| cur + 1 else 0;
        return std.fmt.allocPrint(allocator, "[{d}/{d}] /{s}", .{ position, self.matches.items.len, self.pattern.items });
    }
};

/// Scrolls `view` so `line` is visible, placing it a third of the way down
/// when it was off screen; leaves the view alone when already visible.
pub fn reveal(view: *Viewport, line: usize) void {
    if (line >= view.top and line < view.visibleEnd()) return;
    view.top = line -| (view.height / 3);
    view.setMetrics(view.height, view.total);
}

/// The '/' prompt: edits a query, searching incrementally as it changes.
/// Esc restores the previous pattern and scroll position; Enter commits.
pub const Prompt = struct {
    allocator: std.mem.Allocator,
    active: bool = false,
    query: std.ArrayList(u8) = .empty,
    origin_top: usize = 0,
    saved_pattern: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Prompt {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Prompt) void {
        self.query.deinit(self.allocator);
        self.saved_pattern.deinit(self.allocator);
    }

    pub fn begin(self: *Prompt, search: *const Search, view: Viewport) !void {
        self.active = true;
        self.query.clearRetainingCapacity();
        self.origin_top = view.top;
        self.saved_pattern.clearRetainingCapacity();
        try self.saved_pattern.appendSlice(self.allocator, search.pattern.items);
    }

    /// Appends typed text and re-runs the search from where the prompt opened.
    pub fn insert(self: *Prompt, text: []const u8, search: *Search, view: *Viewport, lines: []const Line) !void {
        try self.query.appendSlice(self.allocator, text);
        try self.update(search, view, lines);
    }

    /// Deletes the last character; returns false (and cancels) when the
    /// query was already empty, like vim and less.
    pub fn backspace(self: *Prompt, search: *Search, view: *Viewport, lines: []const Line) !bool {
        if (self.query.items.len == 0) {
            try self.cancel(search, view, lines);
            return false;
        }
        var cut = self.query.items.len - 1;
        while (cut > 0 and (self.query.items[cut] & 0xC0) == 0x80) cut -= 1;
        self.query.shrinkRetainingCapacity(cut);
        try self.update(search, view, lines);
        return true;
    }

    pub fn clearQuery(self: *Prompt, search: *Search, view: *Viewport, lines: []const Line) !void {
        self.query.clearRetainingCapacity();
        try self.update(search, view, lines);
    }

    pub fn cancel(self: *Prompt, search: *Search, view: *Viewport, lines: []const Line) !void {
        self.active = false;
        view.top = self.origin_top;
        view.setMetrics(view.height, view.total);
        try search.setPattern(self.saved_pattern.items, lines);
        if (search.hasPattern()) _ = search.selectFrom(view.top, .forward);
    }

    /// Commits the query (an empty one repeats the previous pattern). On no
    /// match the view returns to where the prompt opened.
    pub fn commit(self: *Prompt, search: *Search, view: *Viewport, lines: []const Line) !void {
        self.active = false;
        if (self.query.items.len == 0) {
            try self.query.appendSlice(self.allocator, self.saved_pattern.items);
        }
        try self.update(search, view, lines);
    }

    fn update(self: *Prompt, search: *Search, view: *Viewport, lines: []const Line) !void {
        try search.setPattern(self.query.items, lines);
        view.top = self.origin_top;
        view.setMetrics(view.height, view.total);
        if (!search.hasPattern()) return;
        const match = search.selectFrom(self.origin_top, .forward) orelse return;
        reveal(view, match.line);
    }
};

fn firstIndexAtOrAfter(items: []const Match, line: usize) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].line < line) lo = mid + 1 else hi = mid;
    }
    return lo;
}

test {
    _ = @import("search_test.zig");
}
