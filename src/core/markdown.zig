const std = @import("std");
const koino = @import("koino");
pub const document = @import("document.zig");

pub const Inline = document.Inline;
pub const Block = document.Block;
pub const BlockTag = document.BlockTag;
pub const Document = document.Document;

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Document {
    const root = try koino.parse(allocator, source, .{
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

    try collectBlocksWithSource(allocator, &blocks, root, source);
    return .{ .blocks = try blocks.toOwnedSlice(allocator) };
}

fn collectBlocksWithSource(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), node: *koino.nodes.AstNode, source: []const u8) !void {
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
            .List => |list| try appendList(allocator, blocks, current, list),
            else => if (current.first_child != null) try collectBlocksWithSource(allocator, blocks, current, source),
        }
    }
}

fn collectBlocks(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), node: *koino.nodes.AstNode) !void {
    var child = node.first_child;
    while (child) |current| : (child = current.next) {
        switch (current.data.value) {
            .Heading => |heading| try appendHeadingBlock(allocator, blocks, current, heading),
            .Paragraph => try appendParagraphBlock(allocator, blocks, current),
            .CodeBlock => |code| try appendCodeBlock(allocator, blocks, code),
            .HtmlBlock => |html| try appendHtmlBlock(allocator, blocks, html),
            .ThematicBreak => try blocks.append(allocator, .thematic_break),
            .BlockQuote => try appendBlockQuote(allocator, blocks, current),
            .Table => try appendTable(allocator, blocks, current),
            .List => |list| try appendList(allocator, blocks, current, list),
            else => if (current.first_child != null) try collectBlocks(allocator, blocks, current),
        }
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

    // Detect leading indentation from source using start_line
    var indent: u8 = 0;
    const start_line = node.data.start_line;

    var line_start: usize = 0;
    var current_line: usize = 0;

    // Find the start of the target line
    for (source, 0..) |char, idx| {
        if (current_line == start_line) {
            line_start = idx;
            break;
        }
        if (char == '\n') {
            current_line += 1;
        }
    }

    // Count leading spaces on that line
    var spaces: u8 = 0;
    var idx = line_start;
    while (idx < source.len) : (idx += 1) {
        const char = source[idx];
        if (char == ' ') {
            spaces += 1;
        } else if (char == '\t') {
            spaces +|= 4;
        } else if (char == '\n' or char == '\r') {
            // Empty line
            break;
        } else {
            // Hit non-whitespace content
            break;
        }
    }
    // Only count indentation if it's less than 4 spaces (not a code block)
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
    const language = try allocator.dupe(u8, info);
    errdefer allocator.free(language);
    const code_text = try allocator.dupe(u8, code.literal.items);
    errdefer allocator.free(code_text);
    try blocks.append(allocator, .{ .fenced_code = .{ .language = language, .code = code_text } });
}

fn appendHtmlBlock(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), html: koino.nodes.NodeHtmlBlock) !void {
    const text = try allocator.dupe(u8, std.mem.trimRight(u8, html.literal.items, "\n"));
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

const BlockQuoteBlocksResult = struct {
    blocks: []Block,
    depth: u8,
};

fn collectBlockQuoteBlocks(allocator: std.mem.Allocator, node: *koino.nodes.AstNode, depth: u8) !Block.BlockQuote {
    var result: std.ArrayList(Block) = .empty;
    errdefer {
        for (result.items) |block| block.deinit(allocator);
        result.deinit(allocator);
    }

    var child = node.first_child;
    while (child) |current| : (child = current.next) {
        switch (current.data.value) {
            .Heading => |heading| {
                try appendHeadingBlock(allocator, &result, current, heading);
            },
            .Paragraph => {
                try appendParagraphBlock(allocator, &result, current);
            },
            .CodeBlock => |code| {
                try appendCodeBlock(allocator, &result, code);
            },
            .HtmlBlock => |html| {
                try appendHtmlBlock(allocator, &result, html);
            },
            .ThematicBreak => {
                try result.append(allocator, .thematic_break);
            },
            .BlockQuote => {
                const nested = try collectBlockQuoteBlocks(allocator, current, depth + 1);
                try result.append(allocator, .{ .blockquote = nested });
            },
            .Table => {
                try appendTable(allocator, &result, current);
            },
            .List => |list| {
                try appendList(allocator, &result, current, list);
            },
            else => {},
        }
    }

    return .{
        .blocks = try result.toOwnedSlice(allocator),
        .depth = depth,
    };
}

fn collectBlockQuoteInlines(allocator: std.mem.Allocator, node: *koino.nodes.AstNode) ![]Inline {
    var result: std.ArrayList(Inline) = .empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }

    var child = node.first_child;
    var first = true;
    while (child) |current| : (child = current.next) {
        switch (current.data.value) {
            .Paragraph, .Heading, .TableCell => {
                if (!first) try result.append(allocator, .soft_break);
                first = false;
                const inlines = try collectInlines(allocator, current);
                defer allocator.free(inlines);
                for (inlines) |inline_| try result.append(allocator, inline_);
            },
            .CodeBlock => |code| {
                if (!first) try result.append(allocator, .soft_break);
                first = false;
                try result.append(allocator, .{ .code = try allocator.dupe(u8, code.literal.items) });
            },
            .List => |list| {
                const list_inlines = try collectListInlines(allocator, current, list, 0);
                defer allocator.free(list_inlines);
                for (list_inlines) |inline_| {
                    if (!first or result.items.len > 0) {
                        if (result.items.len > 0) try result.append(allocator, .soft_break);
                    }
                    first = false;
                    try result.append(allocator, inline_);
                }
            },
            .BlockQuote => {
                const nested = try collectBlockQuoteInlines(allocator, current);
                defer allocator.free(nested);
                for (nested) |inline_| {
                    if (!first) try result.append(allocator, .soft_break);
                    first = false;
                    try result.append(allocator, inline_);
                }
            },
            else => {
                const nested = try collectBlockInlines(allocator, current);
                defer allocator.free(nested);
                for (nested) |inline_| {
                    if (!first) try result.append(allocator, .soft_break);
                    first = false;
                    try result.append(allocator, inline_);
                }
            },
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn collectListInlines(allocator: std.mem.Allocator, list_node: *koino.nodes.AstNode, list: koino.nodes.NodeList, depth: usize) anyerror![]Inline {
    var result: std.ArrayList(Inline) = .empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }

    var item = list_node.first_child;
    var index: usize = list.start;
    while (item) |list_item| : (item = list_item.next) {
        if (list_item.data.value != .Item) continue;

        // Build marker
        const indent = try allocator.alloc(u8, depth * 2);
        @memset(indent, ' ');
        defer allocator.free(indent);

        const marker = switch (list.list_type) {
            .Bullet => try std.fmt.allocPrint(allocator, "{s}- ", .{indent}),
            .Ordered => blk: {
                const m = try std.fmt.allocPrint(allocator, "{s}{d}. ", .{ indent, index });
                index += 1;
                break :blk m;
            },
        };
        defer allocator.free(marker);

        // Collect item content
        const item_inlines = try collectListItemInlines(allocator, list_item, depth);
        defer allocator.free(item_inlines);

        // Add marker as text, then content
        try result.append(allocator, .{ .text = try allocator.dupe(u8, marker) });
        for (item_inlines) |inline_| try result.append(allocator, inline_);
    }

    return try result.toOwnedSlice(allocator);
}

fn collectListItemInlines(allocator: std.mem.Allocator, item_node: *koino.nodes.AstNode, depth: usize) anyerror![]Inline {
    var result: std.ArrayList(Inline) = .empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }

    var child = item_node.first_child;
    var first = true;
    while (child) |current| : (child = current.next) {
        switch (current.data.value) {
            .Paragraph, .Heading, .TableCell => {
                if (!first) try result.append(allocator, .soft_break);
                first = false;
                const inlines = try collectInlines(allocator, current);
                defer allocator.free(inlines);
                for (inlines) |inline_| try result.append(allocator, inline_);
            },
            .CodeBlock => |code| {
                if (!first) try result.append(allocator, .soft_break);
                first = false;
                try result.append(allocator, .{ .text = try allocator.dupe(u8, code.literal.items) });
            },
            .List => |nested_list| {
                if (!first) try result.append(allocator, .soft_break);
                first = false;
                const nested = try collectListInlines(allocator, current, nested_list, depth + 1);
                defer allocator.free(nested);
                for (nested) |inline_| try result.append(allocator, inline_);
            },
            else => {
                const nested = try collectBlockInlines(allocator, current);
                defer allocator.free(nested);
                for (nested) |inline_| {
                    if (!first) try result.append(allocator, .soft_break);
                    first = false;
                    try result.append(allocator, inline_);
                }
            },
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn collectBlockInlines(allocator: std.mem.Allocator, node: *koino.nodes.AstNode) ![]Inline {
    if (node.first_child == null) {
        var result: std.ArrayList(Inline) = .empty;
        const leaf = try leafInline(allocator, node.data.value);
        if (leaf) |inline_| {
            try result.append(allocator, inline_);
        }
        return try result.toOwnedSlice(allocator);
    }

    var result: std.ArrayList(Inline) = .empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }

    var child = node.first_child;
    var first = true;
    while (child) |current| : (child = current.next) {
        switch (current.data.value) {
            .Paragraph, .Heading, .TableCell => {
                if (!first) try result.append(allocator, .soft_break);
                first = false;
                const inlines = try collectInlines(allocator, current);
                defer allocator.free(inlines);
                for (inlines) |inline_| try result.append(allocator, inline_);
            },
            .CodeBlock => |code| {
                if (!first) try result.append(allocator, .soft_break);
                first = false;
                try result.append(allocator, .{ .text = try allocator.dupe(u8, code.literal.items) });
            },
            else => {
                const nested = try collectBlockInlines(allocator, current);
                defer allocator.free(nested);
                for (nested) |inline_| {
                    if (!first) try result.append(allocator, .soft_break);
                    first = false;
                    try result.append(allocator, inline_);
                }
            },
        }
    }

    return try result.toOwnedSlice(allocator);
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

    // Get alignments from table node
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

fn appendList(allocator: std.mem.Allocator, blocks: *std.ArrayList(Block), list_node: *koino.nodes.AstNode, list: koino.nodes.NodeList) !void {
    var item = list_node.first_child;
    var index: usize = list.start;
    while (item) |list_item| : (item = list_item.next) {
        if (list_item.data.value != .Item) continue;

        const content = try collectListItemContent(allocator, list_item);
        errdefer freeInlines(allocator, content.inlines);
        errdefer {
            for (content.nested) |nested| nested.deinit(allocator);
            allocator.free(content.nested);
        }

        // Check for task item
        if (isTaskItem(content.inlines)) |checked| {
            const task_content = try skipTaskMarker(allocator, content.inlines);
            freeInlines(allocator, content.inlines);
            try blocks.append(allocator, .{ .task_list_item = .{ .checked = checked, .content = task_content } });
            for (content.nested) |nested| nested.deinit(allocator);
            allocator.free(content.nested);
        } else switch (list.list_type) {
            .Bullet => {
                try blocks.append(allocator, .{ .unordered_list_item = .{
                    .marker = try allocator.dupe(u8, "- "),
                    .content = content.inlines,
                    .nested = content.nested,
                } });
            },
            .Ordered => {
                const marker = try std.fmt.allocPrint(allocator, "{d}. ", .{index});
                try blocks.append(allocator, .{ .ordered_list_item = .{
                    .marker = marker,
                    .content = content.inlines,
                    .nested = content.nested,
                } });
                index += 1;
            },
        }
    }
}

const ListItemContent = struct {
    inlines: []Inline,
    nested: []Block,
};

fn collectListItemContent(allocator: std.mem.Allocator, item_node: *koino.nodes.AstNode) anyerror!ListItemContent {
    var inlines: std.ArrayList(Inline) = .empty;
    errdefer {
        for (inlines.items) |item| item.deinit(allocator);
        inlines.deinit(allocator);
    }

    var nested: std.ArrayList(Block) = .empty;
    errdefer {
        for (nested.items) |block| block.deinit(allocator);
        nested.deinit(allocator);
    }

    var child = item_node.first_child;
    var first = true;
    while (child) |current| : (child = current.next) {
        switch (current.data.value) {
            .Paragraph, .Heading, .TableCell => {
                if (!first) try inlines.append(allocator, .soft_break);
                first = false;
                const collected = try collectInlines(allocator, current);
                defer allocator.free(collected);
                for (collected) |inline_| try inlines.append(allocator, inline_);
            },
            .CodeBlock => |code| {
                if (!first) try inlines.append(allocator, .soft_break);
                first = false;
                try inlines.append(allocator, .{ .text = try allocator.dupe(u8, code.literal.items) });
            },
            .List => |nested_list| {
                // Collect nested list as blocks
                try appendNestedList(allocator, &nested, current, nested_list);
            },
            else => {
                const collected = try collectBlockInlines(allocator, current);
                defer allocator.free(collected);
                for (collected) |inline_| {
                    if (!first) try inlines.append(allocator, .soft_break);
                    first = false;
                    try inlines.append(allocator, inline_);
                }
            },
        }
    }

    return .{
        .inlines = try inlines.toOwnedSlice(allocator),
        .nested = try nested.toOwnedSlice(allocator),
    };
}

fn appendNestedList(allocator: std.mem.Allocator, nested: *std.ArrayList(Block), list_node: *koino.nodes.AstNode, list: koino.nodes.NodeList) anyerror!void {
    var item = list_node.first_child;
    var index: usize = list.start;
    while (item) |list_item| : (item = list_item.next) {
        if (list_item.data.value != .Item) continue;

        const content = try collectListItemContent(allocator, list_item);
        errdefer freeInlines(allocator, content.inlines);
        errdefer {
            for (content.nested) |n| n.deinit(allocator);
            allocator.free(content.nested);
        }

        switch (list.list_type) {
            .Bullet => {
                try nested.append(allocator, .{ .unordered_list_item = .{
                    .marker = try allocator.dupe(u8, "- "),
                    .content = content.inlines,
                    .nested = content.nested,
                } });
            },
            .Ordered => {
                const marker = try std.fmt.allocPrint(allocator, "{d}. ", .{index});
                try nested.append(allocator, .{ .ordered_list_item = .{
                    .marker = marker,
                    .content = content.inlines,
                    .nested = content.nested,
                } });
                index += 1;
            },
        }
    }
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
            const url = try allocator.dupe(u8, link.url);
            errdefer allocator.free(url);
            try result.append(allocator, .{ .link = .{ .text = children, .url = url } });
        },
        .Image => |image| {
            const children = try collectChildInlines(allocator, node);
            errdefer freeInlines(allocator, children);
            const url = try allocator.dupe(u8, image.url);
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
        .Text => |text| .{ .text = try allocator.dupe(u8, text) },
        .Code => |text| .{ .code = try allocator.dupe(u8, text) },
        .HtmlInline => |text| .{ .html = try allocator.dupe(u8, text) },
        .SoftBreak => .soft_break,
        .LineBreak => .line_break,
        else => null,
    };
}

fn freeInlines(allocator: std.mem.Allocator, inlines: []Inline) void {
    for (inlines) |inline_| inline_.deinit(allocator);
    allocator.free(inlines);
}

test "parses headings lists fences and tables" {
    const fixture =
        \\# mdv
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

    // Test emphasis
    {
        var doc = try parse(allocator, "Hello *emphasis* world");
        defer doc.deinit(allocator);
        var found = false;
        for (doc.blocks[0].paragraph.content) |inline_| {
            if (inline_ == .emphasis) found = true;
        }
        try std.testing.expect(found);
    }

    // Test strong
    {
        var doc = try parse(allocator, "Hello **strong** world");
        defer doc.deinit(allocator);
        var found = false;
        for (doc.blocks[0].paragraph.content) |inline_| {
            if (inline_ == .strong) found = true;
        }
        try std.testing.expect(found);
    }

    // Test code
    {
        var doc = try parse(allocator, "Hello `code` world");
        defer doc.deinit(allocator);
        var found = false;
        for (doc.blocks[0].paragraph.content) |inline_| {
            if (inline_ == .code) found = true;
        }
        try std.testing.expect(found);
    }

    // Test link
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

    // Test 3-space indentation
    {
        var doc = try parse(allocator, "   Indented paragraph");
        defer doc.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
        try std.testing.expect(doc.blocks[0] == .paragraph);
        try std.testing.expectEqual(@as(u8, 3), doc.blocks[0].paragraph.indent);
    }

    // Test no indentation
    {
        var doc = try parse(allocator, "Normal paragraph");
        defer doc.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
        try std.testing.expect(doc.blocks[0] == .paragraph);
        try std.testing.expectEqual(@as(u8, 0), doc.blocks[0].paragraph.indent);
    }

    // Test 1-space indentation
    {
        var doc = try parse(allocator, " Single space indent");
        defer doc.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
        try std.testing.expect(doc.blocks[0] == .paragraph);
        try std.testing.expectEqual(@as(u8, 1), doc.blocks[0].paragraph.indent);
    }

    // Test that 4 spaces becomes code block, not indented paragraph
    {
        var doc = try parse(allocator, "    Code block");
        defer doc.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
        try std.testing.expect(doc.blocks[0] == .fenced_code);
    }
}
