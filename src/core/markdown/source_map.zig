const std = @import("std");
const koino = @import("koino");

/// Maps parsed nodes back to the markdown lines they came from, so a block
/// that cannot be rendered can still be shown as its raw source.
pub const SourceMap = struct {
    text: []const u8,
    /// Byte offset of each line start; `line_starts[0]` is line 1.
    line_starts: []usize,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !SourceMap {
        var starts: std.ArrayList(usize) = .empty;
        errdefer starts.deinit(allocator);
        try starts.append(allocator, 0);
        for (text, 0..) |ch, i| {
            if (ch == '\n' and i + 1 < text.len) try starts.append(allocator, i + 1);
        }
        return .{ .text = text, .line_starts = try starts.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: SourceMap, allocator: std.mem.Allocator) void {
        allocator.free(self.line_starts);
    }

    /// Lines `first..last` (1-based, inclusive; `last == null` runs to the end),
    /// without trailing blank lines. Out-of-range requests yield "".
    pub fn lines(self: SourceMap, first: usize, last: ?usize) []const u8 {
        if (first == 0 or first > self.line_starts.len) return "";
        const begin = self.line_starts[first - 1];
        const end = if (last) |l|
            (if (l < self.line_starts.len) self.line_starts[l] else self.text.len)
        else
            self.text.len;
        if (end <= begin) return "";
        return std.mem.trimRight(u8, self.text[begin..end], " \t\r\n");
    }

    /// The raw source of `node`: from its start line up to the line before the
    /// next node that follows it (koino records start lines only).
    pub fn nodeSource(self: SourceMap, node: *koino.nodes.AstNode) []const u8 {
        return self.lines(node.data.start_line, endLine(node));
    }
};

fn endLine(node: *koino.nodes.AstNode) ?usize {
    var current = node;
    while (true) {
        if (current.next) |next| {
            if (next.data.start_line > 0) return next.data.start_line - 1;
        }
        current = current.parent orelse return null;
    }
}

test "lines slices inclusive 1-based ranges and trims trailing blanks" {
    const allocator = std.testing.allocator;
    const map = try SourceMap.init(allocator, "a\nb\n\n  c\nd\n");
    defer map.deinit(allocator);
    try std.testing.expectEqualStrings("a", map.lines(1, 1));
    try std.testing.expectEqualStrings("a\nb", map.lines(1, 3));
    try std.testing.expectEqualStrings("  c\nd", map.lines(4, null));
    try std.testing.expectEqualStrings("", map.lines(0, 2));
    try std.testing.expectEqualStrings("", map.lines(9, null));
    try std.testing.expectEqualStrings("d", map.lines(5, 99));
}
