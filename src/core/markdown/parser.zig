const std = @import("std");
const koino = @import("koino");
const preprocess = @import("preprocess.zig");
const frontmatter = @import("frontmatter.zig");
const SourceMap = @import("source_map.zig").SourceMap;
const unicode = @import("unicode");
const encoding = @import("../encoding.zig");
pub const document = @import("document.zig");

pub const Inline = document.Inline;
pub const Block = document.Block;
pub const BlockTag = document.BlockTag;
pub const Document = document.Document;

/// Parses `source` into blocks. Every string in the result is display-safe
/// text (see `clean`); `source` itself may hold anything, since invalid
/// UTF-8 is decoded lossily first (callers that warn about it decode before
/// calling, so this is only a safety net).
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Document {
    if (!std.unicode.utf8ValidateSlice(source)) {
        const valid = try encoding.toValidUtf8(allocator, source);
        defer allocator.free(valid);
        return parse(allocator, valid);
    }
    const front = frontmatter.split(source);

    const preprocessed = try preprocess.preprocess(allocator, front.body);
    errdefer allocator.free(preprocessed);

    const root = try koino.parse(allocator, preprocessed, .{
        .extensions = .{
            .table = true,
            .strikethrough = true,
            .autolink = true,
        },
    });
    defer root.deinit();

    var blocks: std.ArrayList(Block) = .empty;
    defer {
        for (blocks.items) |block| block.deinit(allocator);
        blocks.deinit(allocator);
    }
    var recorder: SourceRecorder = .{ .map = try SourceMap.init(allocator, preprocessed) };
    defer recorder.deinit(allocator);

    if (front.yaml) |yaml| {
        try appendFrontMatterBlock(allocator, &blocks, yaml);
        try recorder.sources.append(allocator, std.mem.trimRight(u8, blocks.items[0].frontmatter.raw, "\r\n"));
    }
    try collectBlocksWithSource(allocator, &blocks, root, &recorder);
    std.debug.assert(recorder.sources.items.len == blocks.items.len);

    const sources = try recorder.sources.toOwnedSlice(allocator);
    errdefer allocator.free(sources);
    return .{
        .blocks = try blocks.toOwnedSlice(allocator),
        .sources = sources,
        .source_buffer = preprocessed,
    };
}

/// A document holding one mermaid diagram: a bare `.mmd` file or stdin that
/// looks like mermaid. The source gets the same cleanup as markdown text.
pub fn parseMermaid(allocator: std.mem.Allocator, source: []const u8) !Document {
    const language = try allocator.dupe(u8, "mermaid");
    errdefer allocator.free(language);
    const valid = try encoding.toValidUtf8(allocator, source);
    defer allocator.free(valid);
    const code = try clean(allocator, valid);
    errdefer allocator.free(code);

    const blocks = try allocator.alloc(Block, 1);
    blocks[0] = .{ .fenced_code = .{ .language = language, .code = code } };
    return .{ .blocks = blocks };
}

/// Records, for every top-level block, the raw markdown it was parsed from.
const SourceRecorder = struct {
    map: SourceMap,
    sources: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *SourceRecorder, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.sources.deinit(allocator);
    }

    /// Attributes every block appended since the last call to `node`.
    fn record(self: *SourceRecorder, allocator: std.mem.Allocator, block_count: usize, node: *koino.nodes.AstNode) !void {
        const raw = self.map.nodeSource(node);
        while (self.sources.items.len < block_count) try self.sources.append(allocator, raw);
    }
};

fn appendFrontMatterBlock(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), yaml: []const u8) !void {
    const raw = try clean(allocator, yaml);
    errdefer allocator.free(raw);
    const entries = try frontmatter.parseEntries(allocator, raw);
    errdefer allocator.free(entries);
    try blocks.append(allocator, .{ .frontmatter = .{ .raw = raw, .entries = entries } });
}

fn collectBlocksWithSource(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), node: *koino.nodes.AstNode, recorder: *SourceRecorder) !void {
    const source = recorder.map.text;
    var child = node.first_child;
    while (child) |current| : (child = current.next) {
        switch (current.data.value) {
            .Heading => |heading| try appendHeadingBlock(allocator, blocks, current, heading),
            .Paragraph => try appendParagraphBlockWithSource(allocator, blocks, current, source),
            .CodeBlock => |code| try appendCodeBlock(allocator, blocks, code),
            .HtmlBlock => |html| try appendHtmlBlock(allocator, blocks, html),
            .ThematicBreak => try blocks.append(allocator, .thematic_break),
            .BlockQuote => try appendBlockQuote(allocator, blocks, current),
            .Table => try appendTable(allocator, blocks, current),
            .List => |list| {
                var item = current.first_child;
                var index: usize = list.start;
                while (item) |list_item| : (item = list_item.next) {
                    if (list_item.data.value != .Item) continue;
                    try appendListItem(allocator, blocks, list_item, list.list_type, index);
                    try recorder.record(allocator, blocks.items.len, list_item);
                    index += 1;
                }
            },
            else => if (current.first_child != null) try collectBlocksWithSource(allocator, blocks, current, recorder),
        }
        try recorder.record(allocator, blocks.items.len, current);
    }
}

fn appendHeadingBlock(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), node: *koino.nodes.AstNode, heading: koino.nodes.NodeHeading) !void {
    const content = try collectInlines(allocator, node);
    errdefer freeInlines(allocator, content);
    if (content.len == 0) {
        allocator.free(content);
        return;
    }
    try blocks.append(allocator, .{ .heading = .{ .level = heading.level, .content = content } });
}

fn appendParagraphBlockWithSource(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), node: *koino.nodes.AstNode, source: []const u8) !void {
    const content = try collectInlines(allocator, node);
    errdefer freeInlines(allocator, content);
    if (content.len == 0) {
        allocator.free(content);
        return;
    }

    var indent: u8 = 0;
    const start_line = node.data.start_line;
    if (start_line == 0) {
        try blocks.append(allocator, .{ .paragraph = .{ .content = content, .indent = 0 } });
        return;
    }

    var line_start: usize = 0;
    var current_line: usize = 1;

    for (source, 0..) |char, idx| {
        if (current_line == start_line) {
            line_start = idx;
            break;
        }
        if (char == '\n') {
            current_line += 1;
        }
    }

    var spaces: u8 = 0;
    var idx = line_start;
    while (idx < source.len) : (idx += 1) {
        const char = source[idx];
        if (char == ' ') {
            spaces += 1;
        } else if (char == '\t') {
            spaces +|= 4;
        } else if (char == '\n' or char == '\r') {
            break;
        } else {
            break;
        }
    }
    if (spaces < 4) {
        indent = @min(spaces, 255);
    }

    try blocks.append(allocator, .{ .paragraph = .{ .content = content, .indent = indent } });
}

fn appendParagraphBlock(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), node: *koino.nodes.AstNode) !void {
    const content = try collectInlines(allocator, node);
    errdefer freeInlines(allocator, content);
    if (content.len == 0) {
        allocator.free(content);
        return;
    }
    try blocks.append(allocator, .{ .paragraph = .{ .content = content, .indent = 0 } });
}

fn appendCodeBlock(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), code: koino.nodes.NodeCodeBlock) !void {
    const info = if (code.info) |value| std.mem.trim(u8, value, " \t") else "";
    const language = try clean(allocator, info);
    errdefer allocator.free(language);
    const code_text = try clean(allocator, code.literal.items);
    errdefer allocator.free(code_text);
    try blocks.append(allocator, .{ .fenced_code = .{ .language = language, .code = code_text } });
}

fn appendHtmlBlock(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), html: koino.nodes.NodeHtmlBlock) !void {
    const text = try clean(allocator, std.mem.trimRight(u8, html.literal.items, "\n"));
    errdefer allocator.free(text);
    try blocks.append(allocator, .{ .html_block = text });
}

fn appendBlockQuote(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), node: *koino.nodes.AstNode) !void {
    const result = try collectBlockQuoteBlocks(allocator, node, 1);
    errdefer {
        for (result.blocks) |block| block.deinit(allocator);
        allocator.free(result.blocks);
    }
    if (result.blocks.len == 0) {
        allocator.free(result.blocks);
        return;
    }
    try blocks.append(allocator, .{ .blockquote = result });
}

fn collectBlockQuoteBlocks(allocator: std.mem.Allocator, node: *koino.nodes.AstNode, depth: u8) anyerror!Block.BlockQuote {
    var result: std.ArrayList(Block) = .empty;
    errdefer {
        for (result.items) |block| block.deinit(allocator);
        result.deinit(allocator);
    }

    var child = node.first_child;
    while (child) |current| : (child = current.next) {
        try appendChildBlock(allocator, &result, current, depth + 1);
    }

    return .{
        .blocks = try result.toOwnedSlice(allocator),
        .depth = depth,
    };
}

/// Appends the block(s) for one container child (a block quote's or a list
/// item's). Nested quotes take `quote_depth`; everything else keeps its own
/// structure so the renderer can lay it out (code stays a code block, etc.).
fn appendChildBlock(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), node: *koino.nodes.AstNode, quote_depth: u8) anyerror!void {
    switch (node.data.value) {
        .Heading => |heading| try appendHeadingBlock(allocator, blocks, node, heading),
        .Paragraph => try appendParagraphBlock(allocator, blocks, node),
        .CodeBlock => |code| try appendCodeBlock(allocator, blocks, code),
        .HtmlBlock => |html| try appendHtmlBlock(allocator, blocks, html),
        .ThematicBreak => try blocks.append(allocator, .thematic_break),
        .BlockQuote => {
            const nested = try collectBlockQuoteBlocks(allocator, node, quote_depth);
            errdefer (Block{ .blockquote = nested }).deinit(allocator);
            try blocks.append(allocator, .{ .blockquote = nested });
        },
        .Table => try appendTable(allocator, blocks, node),
        .List => |list| try appendList(allocator, blocks, node, list),
        else => {
            var child = node.first_child;
            while (child) |current| : (child = current.next) {
                try appendChildBlock(allocator, blocks, current, quote_depth);
            }
        },
    }
}

fn appendList(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), list_node: *koino.nodes.AstNode, list: koino.nodes.NodeList) anyerror!void {
    var item = list_node.first_child;
    var index: usize = list.start;
    while (item) |list_item| : (item = list_item.next) {
        if (list_item.data.value != .Item) continue;
        try appendListItem(allocator, blocks, list_item, list.list_type, index);
        index += 1;
    }
}

/// Appends one list item. Its first paragraph (or heading) becomes the item's
/// text; every later child (paragraphs, code, quotes, tables, HTML, nested
/// lists) is kept in source order as a block rendered under the text column.
fn appendListItem(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), item_node: *koino.nodes.AstNode, list_type: koino.nodes.ListType, index: usize) anyerror!void {
    var child = item_node.first_child;
    const inlines: []Inline = blk: {
        if (child) |first| switch (first.data.value) {
            .Paragraph, .Heading => {
                child = first.next;
                break :blk try collectInlines(allocator, first);
            },
            else => {},
        };
        break :blk try allocator.alloc(Inline, 0);
    };
    var content = inlines;
    errdefer freeInlines(allocator, content);

    var nested: std.ArrayList(Block) = .empty;
    errdefer {
        for (nested.items) |block| block.deinit(allocator);
        nested.deinit(allocator);
    }
    while (child) |current| : (child = current.next) {
        try appendChildBlock(allocator, &nested, current, 1);
    }
    const owned_nested = try nested.toOwnedSlice(allocator);
    errdefer {
        for (owned_nested) |block| block.deinit(allocator);
        allocator.free(owned_nested);
    }

    if (isTaskItem(content)) |checked| {
        const task_content = try skipTaskMarker(allocator, content);
        freeInlines(allocator, content);
        content = task_content;
        try blocks.append(allocator, .{ .task_list_item = .{
            .checked = checked,
            .content = content,
            .nested = owned_nested,
        } });
        return;
    }

    const marker = switch (list_type) {
        .Bullet => try allocator.dupe(u8, "- "),
        .Ordered => try std.fmt.allocPrint(allocator, "{d}. ", .{index}),
    };
    errdefer allocator.free(marker);
    const list_item: Block.ListItem = .{ .marker = marker, .content = content, .nested = owned_nested };
    try blocks.append(allocator, switch (list_type) {
        .Bullet => .{ .unordered_list_item = list_item },
        .Ordered => .{ .ordered_list_item = list_item },
    });
}

fn appendTable(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), table: *koino.nodes.AstNode) !void {
    var rows: std.ArrayList(Block.TableRow) = .empty;
    defer {
        for (rows.items) |row| {
            for (row.cells) |cell| freeInlines(allocator, cell);
            allocator.free(row.cells);
        }
        rows.deinit(allocator);
    }

    const koino_alignments = switch (table.data.value) {
        .Table => |value| value,
        else => unreachable,
    };

    var alignments: std.ArrayList(Block.Table.Alignment) = .empty;
    errdefer alignments.deinit(allocator);

    for (koino_alignments) |alignment| {
        const a: Block.Table.Alignment = switch (alignment) {
            .Left => .left,
            .Center => .center,
            .Right => .right,
            .None => .none,
        };
        try alignments.append(allocator, a);
    }

    var row = table.first_child;
    while (row) |table_row| : (row = table_row.next) {
        if (table_row.data.value != .TableRow) continue;

        var cells: std.ArrayList([]Inline) = .empty;
        errdefer {
            for (cells.items) |cell| freeInlines(allocator, cell);
            cells.deinit(allocator);
        }

        var cell = table_row.first_child;
        while (cell) |table_cell| : (cell = table_cell.next) {
            const inlines = try collectInlines(allocator, table_cell);
            errdefer freeInlines(allocator, inlines);
            try cells.append(allocator, inlines);
        }

        try rows.append(allocator, .{ .cells = try cells.toOwnedSlice(allocator) });
    }

    if (rows.items.len == 0) return;

    try blocks.append(allocator, .{ .table = .{
        .rows = try rows.toOwnedSlice(allocator),
        .alignments = try alignments.toOwnedSlice(allocator),
    } });
}

fn isTaskItem(inlines: []const Inline) ?bool {
    if (inlines.len == 0) return null;
    const first = inlines[0];
    if (first != .text) return null;
    const text = first.text;
    if (text.len < 3) return null;
    if (text[0] != '[' or text[2] != ']') return null;
    return text[1] == 'x' or text[1] == 'X';
}

fn skipTaskMarker(allocator: std.mem.Allocator, inlines: []const Inline) ![]Inline {
    if (inlines.len == 0) return try allocator.alloc(Inline, 0);

    var result: std.ArrayList(Inline) = .empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }

    for (inlines, 0..) |inline_, i| {
        if (i == 0) {
            if (inline_ == .text) {
                const text = inline_.text;
                if (text.len > 3) {
                    const rest = std.mem.trimLeft(u8, text[3..], " \t");
                    if (rest.len > 0) {
                        try result.append(allocator, .{ .text = try allocator.dupe(u8, rest) });
                    }
                }
                continue;
            }
        }
        try result.append(allocator, try dupeInline(allocator, inline_));
    }

    return try result.toOwnedSlice(allocator);
}

fn dupeInline(allocator: std.mem.Allocator, inline_: Inline) anyerror!Inline {
    return switch (inline_) {
        .text => |t| .{ .text = try allocator.dupe(u8, t) },
        .code => |c| .{ .code = try allocator.dupe(u8, c) },
        .html => |h| .{ .html = try allocator.dupe(u8, h) },
        .emphasis => |children| .{ .emphasis = try dupeInlines(allocator, children) },
        .strong => |children| .{ .strong = try dupeInlines(allocator, children) },
        .strikethrough => |children| .{ .strikethrough = try dupeInlines(allocator, children) },
        .link => |link| .{ .link = .{
            .text = try dupeInlines(allocator, link.text),
            .url = try allocator.dupe(u8, link.url),
        } },
        .image => |image| .{ .image = .{
            .alt = try dupeInlines(allocator, image.alt),
            .url = try allocator.dupe(u8, image.url),
        } },
        .soft_break => .soft_break,
        .line_break => .line_break,
    };
}

fn dupeInlines(allocator: std.mem.Allocator, inlines: []const Inline) anyerror![]Inline {
    var result = try allocator.alloc(Inline, inlines.len);
    errdefer allocator.free(result);
    for (inlines, 0..) |inline_, i| {
        result[i] = try dupeInline(allocator, inline_);
    }
    return result;
}

fn collectInlines(allocator: std.mem.Allocator, node: *koino.nodes.AstNode) ![]Inline {
    var result: std.ArrayList(Inline) = .empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }
    try appendInlineNode(allocator, &result, node);
    return try result.toOwnedSlice(allocator);
}

fn appendInlineNode(allocator: std.mem.Allocator, result: *std.ArrayList(Inline), node: *koino.nodes.AstNode) anyerror!void {
    switch (node.data.value) {
        .Emph => {
            const children = try collectChildInlines(allocator, node);
            errdefer freeInlines(allocator, children);
            try result.append(allocator, .{ .emphasis = children });
        },
        .Strong => {
            const children = try collectChildInlines(allocator, node);
            errdefer freeInlines(allocator, children);
            try result.append(allocator, .{ .strong = children });
        },
        .Strikethrough => {
            const children = try collectChildInlines(allocator, node);
            errdefer freeInlines(allocator, children);
            try result.append(allocator, .{ .strikethrough = children });
        },
        .Link => |link| {
            const children = try collectChildInlines(allocator, node);
            errdefer freeInlines(allocator, children);
            const url = try clean(allocator, link.url);
            errdefer allocator.free(url);
            try result.append(allocator, .{ .link = .{ .text = children, .url = url } });
        },
        .Image => |image| {
            const children = try collectChildInlines(allocator, node);
            errdefer freeInlines(allocator, children);
            const url = try clean(allocator, image.url);
            errdefer allocator.free(url);
            try result.append(allocator, .{ .image = .{ .alt = children, .url = url } });
        },
        else => {
            if (node.first_child == null) {
                if (try leafInline(allocator, node.data.value)) |inline_| {
                    try result.append(allocator, inline_);
                }
                return;
            }
            var child = node.first_child;
            while (child) |current| : (child = current.next) {
                try appendInlineNode(allocator, result, current);
            }
        },
    }
}

fn collectChildInlines(allocator: std.mem.Allocator, node: *koino.nodes.AstNode) ![]Inline {
    var result: std.ArrayList(Inline) = .empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }
    var child = node.first_child;
    while (child) |current| : (child = current.next) {
        try appendInlineNode(allocator, &result, current);
    }
    return try result.toOwnedSlice(allocator);
}

fn leafInline(allocator: std.mem.Allocator, value: koino.nodes.NodeValue) !?Inline {
    return switch (value) {
        .Text => |text| .{ .text = try clean(allocator, text) },
        .Code => |text| .{ .code = try clean(allocator, text) },
        .HtmlInline => |text| .{ .html = try clean(allocator, text) },
        .SoftBreak => .soft_break,
        .LineBreak => .line_break,
        else => null,
    };
}

/// Copies document text so it can reach a terminal safely: controls (ESC
/// included) become U+FFFD and invisible format characters such as the soft
/// hyphen or bidi overrides are dropped, whether they came from the raw
/// source or from a character reference like `&#27;` (`unicode.sanitize`).
fn clean(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return unicode.sanitize(allocator, text);
}

fn freeInlines(allocator: std.mem.Allocator, inlines: []Inline) void {
    for (inlines) |inline_| inline_.deinit(allocator);
    allocator.free(inlines);
}

test "parses headings lists fences and tables" {
    const fixture =
        \\# mercat
        \\
        \\- [x] Parse task lists
        \\- Parse headings
        \\1. Parse ordered lists
        \\
        \\| Feature | Status |
        \\| ------- | ------ |
        \\| Tables  | Yes    |
        \\
        \\```zig
        \\const hello = "world";
        \\```
    ;
    var doc = try parse(std.testing.allocator, fixture);
    defer doc.deinit(std.testing.allocator);

    var saw_heading = false;
    var saw_task = false;
    var saw_fence = false;
    var saw_table = false;

    for (doc.blocks) |block| {
        switch (block) {
            .heading => saw_heading = true,
            .task_list_item => saw_task = true,
            .fenced_code => |code| saw_fence = std.mem.indexOf(u8, code.code, "const hello") != null,
            .table => saw_table = true,
            else => {},
        }
    }

    try std.testing.expect(saw_heading);
    try std.testing.expect(saw_task);
    try std.testing.expect(saw_fence);
    try std.testing.expect(saw_table);
}

test "parses paragraph with inline styles" {
    const allocator = std.testing.allocator;

    {
        var doc = try parse(allocator, "Hello *emphasis* world");
        defer doc.deinit(allocator);
        var found = false;
        for (doc.blocks[0].paragraph.content) |inline_| {
            if (inline_ == .emphasis) found = true;
        }
        try std.testing.expect(found);
    }

    {
        var doc = try parse(allocator, "Hello **strong** world");
        defer doc.deinit(allocator);
        var found = false;
        for (doc.blocks[0].paragraph.content) |inline_| {
            if (inline_ == .strong) found = true;
        }
        try std.testing.expect(found);
    }

    {
        var doc = try parse(allocator, "Hello `code` world");
        defer doc.deinit(allocator);
        var found = false;
        for (doc.blocks[0].paragraph.content) |inline_| {
            if (inline_ == .code) found = true;
        }
        try std.testing.expect(found);
    }

    {
        var doc = try parse(allocator, "Hello [link](url) world");
        defer doc.deinit(allocator);
        var found = false;
        for (doc.blocks[0].paragraph.content) |inline_| {
            if (inline_ == .link) found = true;
        }
        try std.testing.expect(found);
    }
}

test "parses thematic breaks and html blocks" {
    const source =
        \\<aside>raw html</aside>
        \\
        \\---
    ;
    var doc = try parse(std.testing.allocator, source);
    defer doc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .html_block);
    try std.testing.expect(doc.blocks[1] == .thematic_break);
    try std.testing.expectEqualStrings("<aside>raw html</aside>", doc.blocks[0].html_block);
}

test "preserves paragraph indentation" {
    const allocator = std.testing.allocator;

    {
        var doc = try parse(allocator, "   Indented paragraph");
        defer doc.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
        try std.testing.expect(doc.blocks[0] == .paragraph);
        try std.testing.expectEqual(@as(u8, 3), doc.blocks[0].paragraph.indent);
    }

    {
        var doc = try parse(allocator, "Normal paragraph");
        defer doc.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
        try std.testing.expect(doc.blocks[0] == .paragraph);
        try std.testing.expectEqual(@as(u8, 0), doc.blocks[0].paragraph.indent);
    }

    {
        var doc = try parse(allocator, " Single space indent");
        defer doc.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
        try std.testing.expect(doc.blocks[0] == .paragraph);
        try std.testing.expectEqual(@as(u8, 1), doc.blocks[0].paragraph.indent);
    }

    {
        var doc = try parse(allocator, "    Code block");
        defer doc.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
        try std.testing.expect(doc.blocks[0] == .fenced_code);
    }
}

test "strikethrough preprocessing converts to unicode" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "~~hello~~");
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const para = doc.blocks[0].paragraph;

    var has_combining = false;
    for (para.content) |inline_| {
        if (inline_ == .text) {
            const text = inline_.text;
            if (std.mem.indexOf(u8, text, "\xcc\xb6") != null) {
                has_combining = true;
            }
        }
        if (inline_ == .strikethrough) {
            std.debug.print("ERROR: Found strikethrough inline - preprocessing failed\n", .{});
        }
    }
    try std.testing.expect(has_combining);
}

test {
    _ = frontmatter;
    _ = @import("parser_test.zig");
    _ = @import("source_map.zig");
}
