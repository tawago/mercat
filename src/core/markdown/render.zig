const std = @import("std");
const markdown = @import("parser.zig");
const types = @import("render/types.zig");
const builder_mod = @import("render/builder.zig");
const blocks = @import("render/blocks.zig");
const render_frontmatter = @import("render/frontmatter.zig");
const decor_mod = @import("render/decor.zig");

const Builder = builder_mod.Builder;

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
    var failures: Failures = .{};
    for (document.blocks, 0..) |block, index| {
        if (try rendersNothing(allocator, block, options)) continue;
        if (previous) |prev| {
            try builder.newline();
            if (!blocks.isCompactBlockPair(prev, block)) try builder.newline();
        }
        try renderIsolated(allocator, &builder, block, document.blockSource(index), options, &failures);
        previous = block;
    }
    if (options.fallback_count) |count| count.* = failures.count;
    if (failures.count != 0) {
        std.log.warn("{d} markdown block(s) could not be rendered and are shown as raw source (first error: {s})", .{
            failures.count, @errorName(failures.first.?),
        });
    }

    const lines = try builder.finish();
    try materializeLineFill(allocator, lines, options);
    return .{ .lines = lines };
}

fn rendersNothing(allocator: std.mem.Allocator, block: markdown.Block, options: Options) !bool {
    return switch (block) {
        .frontmatter => |fm| render_frontmatter.rendersNothing(fm, options.frontmatter_style),
        else => try blocks.rendersNothing(allocator, block),
    };
}

const Failures = struct {
    count: usize = 0,
    first: ?anyerror = null,
};

/// Renders one block on its own, so a block that fails (an unexpected error,
/// or output that is not valid display text) is replaced by its raw source,
/// muted, instead of failing the whole document.
fn renderIsolated(allocator: std.mem.Allocator, builder: *Builder, block: markdown.Block, source: ?[]const u8, options: Options, failures: *Failures) !void {
    var scratch = Builder.init(allocator);
    defer scratch.deinit();
    scratch.left_padding = builder.left_padding;
    const pending = renderAndSeal(allocator, &scratch, block, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            failures.count += 1;
            if (failures.first == null) failures.first = err;
            return renderRawSource(allocator, builder, source);
        },
    };
    try builder.absorb(&scratch, pending);
}

fn renderAndSeal(allocator: std.mem.Allocator, scratch: *Builder, block: markdown.Block, options: Options) anyerror!bool {
    try blocks.renderBlock(allocator, scratch, block, options);
    return scratch.seal();
}

const unrenderable = "[block could not be rendered]";

/// Emits `source` as muted lines, with anything that is not displayable
/// text replaced by U+FFFD; a placeholder when there is no usable source.
fn renderRawSource(allocator: std.mem.Allocator, builder: *Builder, source: ?[]const u8) !void {
    var scratch = Builder.init(allocator);
    defer scratch.deinit();
    scratch.left_padding = builder.left_padding;
    const pending = writeRawSource(allocator, &scratch, source orelse unrenderable) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try builder.appendSpan(.muted, unrenderable);
            return;
        },
    };
    try builder.absorb(&scratch, pending);
}

fn writeRawSource(allocator: std.mem.Allocator, scratch: *Builder, source: []const u8) !bool {
    const text = if (source.len == 0) unrenderable else source;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try scratch.newline();
        first = false;
        const clean = try sanitize(allocator, std.mem.trimRight(u8, line, "\r"));
        defer allocator.free(clean);
        try scratch.appendSpan(.muted, clean);
    }
    return scratch.seal();
}

/// Replaces invalid UTF-8 and control characters (other than tab) with U+FFFD.
pub fn sanitize(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        const cp: ?u21 = if (len == 0 or i + len > text.len) null else std.unicode.utf8Decode(text[i .. i + len]) catch null;
        if (cp) |c| {
            const control = (c < 0x20 and c != '\t') or (c >= 0x7f and c < 0xa0);
            try out.appendSlice(allocator, if (control) "\u{FFFD}" else text[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
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
