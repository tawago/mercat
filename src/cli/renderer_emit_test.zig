const std = @import("std");
const renderer = @import("renderer.zig");
const render_model = @import("../core/markdown/render.zig");
const theme = @import("../core/theme.zig");
const Color = @import("../core/theme/color.zig").Color;

fn sample(spans0: []render_model.Span, spans1: []render_model.Span, lines: *[2]render_model.Line) render_model.Rendered {
    lines[0] = .{ .spans = spans0 };
    lines[1] = .{ .spans = spans1 };
    return .{ .lines = lines };
}

test "color off: same text and line breaks, no SGR, no OSC 8, no canvas padding" {
    const allocator = std.testing.allocator;
    var spans0 = [_]render_model.Span{
        .{ .text = "see ", .style = .body },
        .{ .text = "docs", .style = .link, .url = "https://example.com" },
    };
    var spans1 = [_]render_model.Span{.{ .text = "bye", .style = .emphasis }};
    var lines: [2]render_model.Line = undefined;
    const rendered = sample(&spans0, &spans1, &lines);

    const out = try renderer.serializeWith(
        allocator,
        rendered,
        theme.neutralDark,
        .{ .bg = Color{ .index = 236 }, .width = 40 },
        .{ .color = false, .hyperlinks = false },
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("see docs\nbye", out);
}

test "color on, hyperlinks off: SGR kept, OSC 8 dropped" {
    const allocator = std.testing.allocator;
    var spans0 = [_]render_model.Span{.{ .text = "docs", .style = .link, .url = "https://example.com" }};
    var spans1 = [_]render_model.Span{};
    var lines: [2]render_model.Line = undefined;
    const rendered = sample(&spans0, &spans1, &lines);

    const out = try renderer.serializeWith(allocator, rendered, theme.neutralDark, null, .{ .color = true, .hyperlinks = false });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]8;") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "docs") != null);
}

test "default emit keeps OSC 8 hyperlinks" {
    const allocator = std.testing.allocator;
    var spans0 = [_]render_model.Span{.{ .text = "docs", .style = .link, .url = "https://example.com" }};
    var spans1 = [_]render_model.Span{};
    var lines: [2]render_model.Line = undefined;
    const rendered = sample(&spans0, &spans1, &lines);

    const out = try renderer.serialize(allocator, rendered, theme.neutralDark, null);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]8;;https://example.com") != null);
}
