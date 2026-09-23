const std = @import("std");
const markdown = @import("parser.zig");
const types = @import("render/types.zig");
const builder_mod = @import("render/builder.zig");
const blocks = @import("render/blocks.zig");
const render_frontmatter = @import("render/frontmatter.zig");
const decor_mod = @import("render/decor.zig");

pub const Options = types.Options;
pub const SpanStyle = types.SpanStyle;
pub const Span = types.Span;
pub const Line = types.Line;
pub const Rendered = types.Rendered;

pub fn renderDocument(allocator: std.mem.Allocator, document: markdown.Document, options: Options) !Rendered {
    var builder = builder_mod.Builder.init(allocator);
    builder.left_padding = options.left_padding;
    defer builder.deinit();

    var previous: ?markdown.Block = null;
    for (document.blocks) |block| {
        if (block == .frontmatter and
            render_frontmatter.rendersNothing(block.frontmatter, options.frontmatter_style)) continue;
        if (previous) |prev| {
            try builder.newline();
            if (!blocks.isCompactBlockPair(prev, block)) try builder.newline();
        }
        try blocks.renderBlock(allocator, &builder, block, options);
        previous = block;
    }

    const lines = try builder.finish();
    try materializeLineFill(allocator, lines, options);
    return .{ .lines = lines };
}

fn materializeLineFill(allocator: std.mem.Allocator, lines: []Line, options: Options) !void {
    for (lines) |*line| {
        var fill_style: ?SpanStyle = null;
        for (line.spans) |span| {
            const slot = decor_mod.Slot.fromSpanStyle(span.style);
            if (options.decor.slot(slot).full_line_bg) {
                fill_style = span.style;
                break;
            }
        }
        const style = fill_style orelse continue;
        const cur = line.displayWidth();
        if (cur >= options.width) continue;
        const pad = options.width - cur;

        const new_spans = try allocator.alloc(Span, line.spans.len + 1);
        @memcpy(new_spans[0..line.spans.len], line.spans);
        const buf = try allocator.alloc(u8, pad);
        @memset(buf, ' ');
        new_spans[line.spans.len] = .{ .text = buf, .style = style };
        allocator.free(line.spans);
        line.spans = new_spans;
        line.display_columns = options.width;
    }
}

test {
    _ = @import("render_test.zig");
}
