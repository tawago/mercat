const std = @import("std");
const markdown = @import("parser.zig");
const types = @import("render/types.zig");
const builder_mod = @import("render/builder.zig");
const blocks = @import("render/blocks.zig");
const render_frontmatter = @import("render/frontmatter.zig");
const decor_mod = @import("render/decor.zig");
const inline_mod = @import("render/inline.zig");
const unicode = @import("unicode");

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
            return renderRawSource(allocator, builder, block, source);
        },
    };
    try builder.absorb(&scratch, pending);
}

fn renderAndSeal(allocator: std.mem.Allocator, scratch: *Builder, block: markdown.Block, options: Options) anyerror!bool {
    try blocks.renderBlock(allocator, scratch, block, options);
    return scratch.seal();
}

/// Emits a failed block's raw source as muted lines, cleaned with the same
/// rules as all document text (`unicode.sanitize`). This cannot fail on
/// content: if a cleaned line were still rejected, it is shown again with
/// every byte outside printable ASCII replaced by `?`, so the text is never
/// replaced by a placeholder. A block without recorded source (a document
/// built without a source map) shows the text the block itself holds.
fn renderRawSource(allocator: std.mem.Allocator, builder: *Builder, block: markdown.Block, source: ?[]const u8) !void {
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);
    const text = source orelse blk: {
        owned = try blockText(allocator, block);
        break :blk owned.?;
    };
    for ([_]RawMode{ .sanitized, .ascii }) |mode| {
        var scratch = Builder.init(allocator);
        defer scratch.deinit();
        scratch.left_padding = builder.left_padding;
        const pending = writeRawSource(allocator, &scratch, text, mode) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        try builder.absorb(&scratch, pending);
        return;
    }
    unreachable; // printable ASCII always passes the display checks
}

const RawMode = enum { sanitized, ascii };

fn writeRawSource(allocator: std.mem.Allocator, scratch: *Builder, text: []const u8, mode: RawMode) !bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try scratch.newline();
        first = false;
        const clean = switch (mode) {
            .sanitized => try sanitize(allocator, std.mem.trimRight(u8, line, "\r")),
            .ascii => try asciiOnly(allocator, line),
        };
        defer allocator.free(clean);
        try scratch.appendSpan(.muted, clean);
    }
    return scratch.seal();
}

/// The text a block carries, for blocks with no recorded source.
fn blockText(allocator: std.mem.Allocator, block: markdown.Block) ![]u8 {
    return switch (block) {
        .frontmatter => |fm| allocator.dupe(u8, fm.raw),
        .heading => |h| inline_mod.inlinesToText(allocator, h.content),
        .paragraph => |p| inline_mod.inlinesToText(allocator, p.content),
        .unordered_list_item, .ordered_list_item => |item| inline_mod.inlinesToText(allocator, item.content),
        .task_list_item => |item| inline_mod.inlinesToText(allocator, item.content),
        .fenced_code => |code| allocator.dupe(u8, code.code),
        .html_block => |html| allocator.dupe(u8, html),
        .thematic_break, .table, .blockquote => allocator.dupe(u8, ""),
    };
}

/// Makes one source line displayable with the rules of `unicode.sanitize`:
/// invalid UTF-8, controls and other non-displayable scalars become U+FFFD,
/// and invisible format characters (soft hyphen, zero-width space, bidi
/// marks, ...) are dropped. Tab is kept; a stray CR or LF becomes a space.
pub fn sanitize(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const clean = try unicode.sanitize(allocator, text);
    for (clean) |*byte| {
        if (byte.* == '\r' or byte.* == '\n') byte.* = ' ';
    }
    return clean;
}

/// The last-resort form of a line: printable ASCII kept, tab as a space,
/// every other byte `?`.
fn asciiOnly(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, text);
    for (out) |*byte| {
        if (byte.* == '\t') {
            byte.* = ' ';
        } else if (byte.* < 0x20 or byte.* > 0x7e) {
            byte.* = '?';
        }
    }
    return out;
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
