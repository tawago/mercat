const std = @import("std");
const markdown = @import("markdown.zig");
const types = @import("render/types.zig");
const builder_mod = @import("render/builder.zig");
const blocks = @import("render/blocks.zig");
const render_frontmatter = @import("render/frontmatter.zig");
const decor_mod = @import("render/decor.zig");

// Re-export types
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
        // Front matter that would render nothing is skipped before spacing so
        // the document starts flush at its first real block with no phantom
        // leading blank lines.
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

/// Post-pass for `full_line_bg` slots (markview headings): for any line carrying
/// a span whose slot tints the whole row, append a trailing padding span in that
/// slot's style so the background extends to the full render width. Backends are
/// dumb — they just paint each span's bg — so the fill materializes as ordinary
/// styled spaces here.
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
    }
}

test {
    _ = @import("render_model_test.zig");
}
