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

/// Walks colored output and fails on attribute bleed: an SGR prefix while a
/// run is still open, a newline inside a run or a link, or output that ends
/// inside one. Returns the text with every escape removed.
fn expectNoBleed(allocator: std.mem.Allocator, out: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var run_open = false;
    var link_open = false;
    var i: usize = 0;
    while (i < out.len) {
        if (std.mem.startsWith(u8, out[i..], "\x1b[")) {
            const end = std.mem.indexOfScalarPos(u8, out, i, 'm').? + 1;
            if (std.mem.eql(u8, out[i..end], "\x1b[0m")) {
                run_open = false;
            } else {
                if (run_open) return error.PrefixWhileRunOpen;
                run_open = true;
            }
            i = end;
        } else if (std.mem.startsWith(u8, out[i..], "\x1b]8;;")) {
            const end = std.mem.indexOfPos(u8, out, i, "\x1b\\").?;
            const opens = end > i + 5;
            if (opens == link_open) return error.UnbalancedOsc8;
            link_open = opens;
            i = end + 2;
        } else {
            if (out[i] == '\n' and (run_open or link_open)) return error.OpenAtLineEnd;
            try text.append(allocator, out[i]);
            i += 1;
        }
    }
    if (run_open or link_open) return error.OpenAtEnd;
    return text.toOwnedSlice(allocator);
}

test "color on: each run is reset before the next prefix and at line end; links are OSC 8" {
    const allocator = std.testing.allocator;
    var spans0 = [_]render_model.Span{
        .{ .text = "foo", .style = .body },
        .{ .text = "bar", .style = .emphasis },
        .{ .text = "docs", .style = .link, .url = "https://example.com" },
        .{ .text = "baz", .style = .body },
        .{ .text = "qux", .style = .table_header },
    };
    var spans1 = [_]render_model.Span{};
    var spans2 = [_]render_model.Span{.{ .text = "b", .style = .body }};
    var lines = [_]render_model.Line{ .{ .spans = &spans0 }, .{ .spans = &spans1 }, .{ .spans = &spans2 } };

    const out = try renderer.serialize(allocator, .{ .lines = &lines }, theme.neutralDark, null);
    defer allocator.free(out);
    const text = try expectNoBleed(allocator, out);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("foobardocsbazqux\n\nb", text);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]8;;https://example.com\x1b\\") != null);
}

test "color on with a canvas: short lines are padded to the canvas width" {
    const allocator = std.testing.allocator;
    var spans0 = [_]render_model.Span{.{ .text = "ab", .style = .body }};
    var spans1 = [_]render_model.Span{};
    var lines: [2]render_model.Line = undefined;
    const rendered = sample(&spans0, &spans1, &lines);

    const out = try renderer.serialize(allocator, rendered, theme.neutralDark, .{ .bg = Color{ .index = 236 }, .width = 6 });
    defer allocator.free(out);
    const text = try expectNoBleed(allocator, out);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("ab    \n      ", text);
    try std.testing.expect(std.mem.indexOf(u8, out, "48;5;236") != null);
}
