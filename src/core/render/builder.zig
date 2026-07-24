const std = @import("std");
const types = @import("types.zig");
const Line = types.Line;
const Span = types.Span;
const SpanStyle = types.SpanStyle;

pub const Builder = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(Line),
    current: std.ArrayList(Span),
    left_padding: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .lines = .empty,
            .current = .empty,
        };
    }

    pub fn deinit(self: *Builder) void {
        for (self.current.items) |span| {
            self.allocator.free(span.text);
            if (span.url) |url| self.allocator.free(url);
        }
        self.current.deinit(self.allocator);
        for (self.lines.items) |line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
    }

    pub fn appendSpan(self: *Builder, style: SpanStyle, text: []const u8) !void {
        try self.appendSpanWithUrl(style, text, null);
    }

    pub fn appendSpanWithUrl(self: *Builder, style: SpanStyle, text: []const u8, url: ?[]const u8) !void {
        if (text.len == 0) return;
        if (self.current.items.len == 0 and self.left_padding != 0) {
            const padding = try self.allocator.alloc(u8, self.left_padding);
            errdefer self.allocator.free(padding);
            @memset(padding, ' ');
            try self.current.append(self.allocator, .{ .text = padding, .style = .body });
        }
        const can_merge = if (self.current.items.len != 0) blk: {
            const last = &self.current.items[self.current.items.len - 1];
            const urls_match = (last.url == null and url == null) or
                             (last.url != null and url != null and std.mem.eql(u8, last.url.?, url.?));
            break :blk last.style == style and urls_match;
        } else false;

        if (can_merge) {
            const last = &self.current.items[self.current.items.len - 1];
            const joined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ last.text, text });
            self.allocator.free(last.text);
            last.text = joined;
            return;
        }
        const duped_url = if (url) |u| try self.allocator.dupe(u8, u) else null;
        errdefer if (duped_url) |u| self.allocator.free(u);
        const duped_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(duped_text);
        try self.current.append(self.allocator, .{ .text = duped_text, .style = style, .url = duped_url });
    }

    pub fn newline(self: *Builder) !void {
        const spans = try self.current.toOwnedSlice(self.allocator);
        errdefer {
            for (spans) |span| {
                self.allocator.free(span.text);
                if (span.url) |u| self.allocator.free(u);
            }
            self.allocator.free(spans);
        }
        try self.lines.append(self.allocator, .{ .spans = spans });
        self.current = .empty;
    }

    pub fn finish(self: *Builder) ![]Line {
        if (self.current.items.len != 0 or self.lines.items.len == 0) {
            try self.newline();
        }
        return try self.lines.toOwnedSlice(self.allocator);
    }
};

fn buildForLeakTest(allocator: std.mem.Allocator) !void {
    var b = Builder.init(allocator);
    defer b.deinit();
    b.left_padding = 2;
    try b.appendSpanWithUrl(.body, "link", "https://example.com");
    try b.appendSpan(.emphasis, "text");
    try b.newline();
    try b.appendSpan(.body, "more");
    const lines = try b.finish();
    for (lines) |line| line.deinit(allocator);
    allocator.free(lines);
}

test "Builder leaks no spans under injected allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildForLeakTest, .{});
}
