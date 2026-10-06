//! The status bar: one full-width row. Left: the file name and a transient
//! message, or the '/' prompt. Right: the position, which is never hidden.
//! Everything is measured and clipped in display columns at grapheme
//! boundaries, so wide (CJK) text is never split.
const std = @import("std");
const unicode = @import("unicode");
const viewport = @import("viewport.zig");

pub const Options = struct {
    title: []const u8,
    width: usize,
    view: viewport.Viewport,
    /// A transient message shown after the file name.
    message: ?[]const u8 = null,
    /// The search query while the '/' prompt is open.
    prompt: ?[]const u8 = null,
};

pub const Bar = struct {
    /// Exactly `width` display columns (unless the screen is narrower than
    /// one column of padding).
    text: []u8,
    /// Where the terminal cursor goes while the prompt is open.
    cursor_col: ?usize = null,

    pub fn deinit(self: Bar, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

const help_hint = "? help";

/// "Top", "Bot", "All" or "41%".
pub fn positionWord(buf: []u8, view: viewport.Viewport) []const u8 {
    if (view.total == 0 or view.height >= view.total) return "All";
    if (view.top == 0) return "Top";
    if (view.visibleEnd() >= view.total) return "Bot";
    return std.fmt.bufPrint(buf, "{d}%", .{view.progressPercent()}) catch "";
}

/// "L 30-58/897 41%" (or "... Top"/"Bot"/"All"); just the word when `width`
/// is too narrow for the line numbers.
pub fn position(buf: []u8, view: viewport.Viewport, width: usize) []const u8 {
    var word_buf: [8]u8 = undefined;
    const word = positionWord(&word_buf, view);
    const first = if (view.total == 0) 0 else view.top + 1;
    const full = std.fmt.bufPrint(buf, "L {d}-{d}/{d} {s}", .{ first, view.visibleEnd(), view.total, word }) catch word;
    if (full.len + 2 <= width) return full;
    @memmove(buf[0..word.len], word);
    return buf[0..word.len];
}

pub fn render(allocator: std.mem.Allocator, opts: Options) !Bar {
    var pos_buf: [96]u8 = undefined;
    const right_full = position(&pos_buf, opts.view, opts.width);
    // Narrower than the position itself: show what fits of it.
    const right = clipRight(right_full, opts.width -| 2);
    const right_width = unicode.displayWidth(right);
    const left_room = opts.width -| (right_width + 3);

    var left_buf: std.ArrayList(u8) = .empty;
    defer left_buf.deinit(allocator);
    var cursor_col: ?usize = null;
    var hint: []const u8 = "";

    if (opts.prompt) |query| {
        try left_buf.append(allocator, '/');
        try left_buf.appendSlice(allocator, query);
        if (unicode.displayWidth(left_buf.items) > left_room) {
            const tail = tailToWidth(left_buf.items, left_room -| 1);
            const kept = try std.fmt.allocPrint(allocator, "…{s}", .{tail});
            defer allocator.free(kept);
            left_buf.clearRetainingCapacity();
            if (left_room > 0) try left_buf.appendSlice(allocator, kept);
        }
        cursor_col = @min(1 + unicode.displayWidth(left_buf.items), opts.width -| 1);
    } else {
        const name = std.fs.path.basename(opts.title);
        if (opts.message) |message| {
            const both = unicode.displayWidth(name) + 2 + unicode.displayWidth(message);
            if (both <= left_room) {
                try left_buf.appendSlice(allocator, name);
                try left_buf.appendSlice(allocator, "  ");
            }
            try appendClipped(allocator, &left_buf, message, left_room);
        } else {
            try appendClipped(allocator, &left_buf, name, left_room);
            if (unicode.displayWidth(name) + help_hint.len + 2 <= left_room) hint = help_hint;
        }
    }

    const left_width = unicode.displayWidth(left_buf.items);
    const used = 1 + left_width + right_width + 1 + hint.len + @as(usize, if (hint.len > 0) 2 else 0);
    const gap = opts.width -| used;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (opts.width > 0) try out.append(allocator, ' ');
    try out.appendSlice(allocator, left_buf.items);
    try out.appendNTimes(allocator, ' ', gap);
    if (hint.len > 0) {
        try out.appendSlice(allocator, hint);
        try out.appendSlice(allocator, "  ");
    }
    try out.appendSlice(allocator, right);
    if (opts.width > right_width + 1) try out.append(allocator, ' ');
    return .{ .text = try out.toOwnedSlice(allocator), .cursor_col = cursor_col };
}

fn appendClipped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    if (unicode.displayWidth(text) <= width) return out.appendSlice(allocator, text);
    if (width == 0) return;
    try out.appendSlice(allocator, unicode.clipToWidth(text, width - 1));
    try out.appendSlice(allocator, "…");
}

fn clipRight(text: []const u8, width: usize) []const u8 {
    return unicode.clipToWidth(text, width);
}

/// The longest suffix of `text` that fits in `width` display columns,
/// starting at a grapheme boundary.
pub fn tailToWidth(text: []const u8, width: usize) []const u8 {
    const total = unicode.displayWidth(text);
    if (total <= width) return text;
    var cursor = unicode.LegacyCursor.init(text);
    var dropped: usize = 0;
    while (cursor.next()) |glyph| {
        dropped += glyph.width;
        if (total - dropped <= width) return text[cursor.index..];
    }
    return text[text.len..];
}

test {
    _ = @import("statusbar_test.zig");
}
