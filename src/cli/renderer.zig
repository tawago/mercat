const std = @import("std");
const render_model = @import("../core/markdown/render.zig");
const theme = @import("../core/theme.zig");
const ansi = @import("../lib/ansi.zig");
const Color = @import("../core/theme/color.zig").Color;

pub const Canvas = struct {
    bg: Color,
    width: usize,
};

pub fn serialize(
    allocator: std.mem.Allocator,
    rendered: render_model.Rendered,
    palette: theme.StyleMap,
    canvas: ?Canvas,
) ![]u8 {
    return serializeWith(allocator, rendered, palette, canvas, .{});
}

/// What the serializer may emit. With `color` off the output has the same
/// text and line breaks but no SGR, no canvas padding and no OSC 8.
pub const Emit = struct {
    color: bool = true,
    hyperlinks: bool = true,
};

pub fn serializeWith(
    allocator: std.mem.Allocator,
    rendered: render_model.Rendered,
    palette: theme.StyleMap,
    canvas_opt: ?Canvas,
    emit: Emit,
) ![]u8 {
    if (!emit.color) return serializeBare(allocator, rendered);
    const canvas = canvas_opt;
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    var run_token: ?theme.StyleToken = null;
    var run_open = false;

    const flushRun = struct {
        fn call(a: std.mem.Allocator, buf: *std.ArrayList(u8), tok: *?theme.StyleToken, open: *bool) !void {
            if (open.*) try buf.appendSlice(a, ansi.reset_sequence);
            tok.* = null;
            open.* = false;
        }
    }.call;

    for (rendered.lines, 0..) |line, line_index| {
        try flushRun(allocator, &buffer, &run_token, &run_open);
        if (line_index != 0) try buffer.append(allocator, '\n');
        for (line.spans) |span| {
            var token = theme.token(palette, span.style);
            if (canvas) |c| {
                if (token.bg == null) token.bg = c.bg;
            }
            if (span.url) |url| {
                try flushRun(allocator, &buffer, &run_token, &run_open);
                if (emit.hyperlinks) {
                    try ansi.writeHyperlink(allocator, &buffer, url, span.text, token);
                } else {
                    try ansi.writeTokenStyled(allocator, &buffer, token, span.text);
                }
            } else {
                if (run_token != null and !std.meta.eql(run_token.?, token)) {
                    try flushRun(allocator, &buffer, &run_token, &run_open);
                }
                run_token = token;
                if (span.text.len != 0) {
                    if (!run_open) {
                        try ansi.writeTokenPrefix(allocator, &buffer, token);
                        run_open = true;
                    }
                    try buffer.appendSlice(allocator, span.text);
                }
            }
        }
        if (canvas) |c| {
            try flushRun(allocator, &buffer, &run_token, &run_open);
            const cur = line.displayWidth();
            if (cur < c.width) {
                const pad = c.width - cur;
                const spaces = try allocator.alloc(u8, pad);
                defer allocator.free(spaces);
                @memset(spaces, ' ');
                try ansi.writeTokenStyled(allocator, &buffer, .{ .fg = .default, .bg = c.bg }, spaces);
            }
        }
    }
    try flushRun(allocator, &buffer, &run_token, &run_open);

    return try buffer.toOwnedSlice(allocator);
}

fn serializeBare(allocator: std.mem.Allocator, rendered: render_model.Rendered) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    for (rendered.lines, 0..) |line, line_index| {
        if (line_index != 0) try buffer.append(allocator, '\n');
        for (line.spans) |span| try buffer.appendSlice(allocator, span.text);
    }
    return try buffer.toOwnedSlice(allocator);
}

test {
    _ = @import("renderer_emit_test.zig");
}
