const std = @import("std");
const viewport = @import("viewport.zig");

pub fn format(allocator: std.mem.Allocator, title: []const u8, width: usize, view: viewport.Viewport, in_help: bool, status_message: ?[]const u8) ![]u8 {
    const short_title = baseName(title);
    const meta = try std.fmt.allocPrint(
        allocator,
        " {d}-{d}/{d} {d}%  e edit  r reload  ? {s} ",
        .{ if (view.total == 0) 0 else view.top + 1, view.visibleEnd(), view.total, view.progressPercent(), if (in_help) "back" else "help" },
    );
    defer allocator.free(meta);

    if (status_message) |message| {
        const clipped = try clipTitleAlloc(allocator, message, width -| 2);
        defer allocator.free(clipped);
        return std.fmt.allocPrint(allocator, " {s}", .{clipped});
    }

    const reserved = @min(meta.len, width);
    const available_title = width -| reserved -| 1;
    const clipped_title = try clipTitleAlloc(allocator, short_title, available_title);
    defer allocator.free(clipped_title);

    return std.fmt.allocPrint(allocator, " {s}{s}", .{ clipped_title, meta });
}

fn baseName(title: []const u8) []const u8 {
    return std.fs.path.basename(title);
}

fn clipTitleAlloc(allocator: std.mem.Allocator, title: []const u8, width: usize) ![]u8 {
    if (title.len <= width) return allocator.dupe(u8, title);
    if (width <= 1) return allocator.dupe(u8, "");
    if (width <= 3) return allocator.dupe(u8, title[0..width]);
    return std.fmt.allocPrint(allocator, "{s}…", .{title[0 .. width - 1]});
}

test "formats status line" {
    const allocator = std.testing.allocator;
    var view = viewport.Viewport{};
    view.setMetrics(10, 30);
    view.lineDown(5);

    const text = try format(allocator, "/tmp/README.md", 64, view, false, null);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "6-15/30") != null);
}
