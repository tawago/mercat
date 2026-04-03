const std = @import("std");

/// Inline content that preserves AST structure from markdown parsing.
/// Replaces the previous approach of flattening to text with markers.
pub const Inline = union(enum) {
    text: []const u8,
    emphasis: []Inline,
    strong: []Inline,
    strikethrough: []Inline,
    code: []const u8,
    link: Link,
    image: Image,
    html: []const u8,
    soft_break,
    line_break,

    pub const Link = struct {
        text: []Inline,
        url: []const u8,
    };

    pub const Image = struct {
        alt: []Inline,
        url: []const u8,
    };

    pub fn deinit(self: Inline, allocator: std.mem.Allocator) void {
        switch (self) {
            .text, .code, .html => |text| allocator.free(text),
            .emphasis, .strong, .strikethrough => |children| {
                for (children) |child| child.deinit(allocator);
                allocator.free(children);
            },
            .link => |link| {
                for (link.text) |child| child.deinit(allocator);
                allocator.free(link.text);
                allocator.free(link.url);
            },
            .image => |image| {
                for (image.alt) |child| child.deinit(allocator);
                allocator.free(image.alt);
                allocator.free(image.url);
            },
            .soft_break, .line_break => {},
        }
    }
};

pub const BlockTag = enum {
    heading,
    paragraph,
    unordered_list_item,
    ordered_list_item,
    task_list_item,
    fenced_code,
    html_block,
    thematic_break,
    table,
    blockquote,
};

pub const Block = union(enum) {
    heading: Heading,
    paragraph: Paragraph,
    unordered_list_item: ListItem,
    ordered_list_item: ListItem,
    task_list_item: TaskItem,
    fenced_code: CodeBlock,
    html_block: []const u8,
    thematic_break,
    table: Table,
    blockquote: BlockQuote,

    pub const Heading = struct {
        level: u8,
        content: []Inline,
    };

    pub const Paragraph = struct {
        content: []Inline,
        indent: u8 = 0,
    };

    pub const ListItem = struct {
        marker: []const u8, // "- " or "1. " etc.
        content: []Inline,
        nested: []Block, // nested lists
    };

    pub const TaskItem = struct {
        checked: bool,
        content: []Inline,
    };

    pub const CodeBlock = struct {
        language: []const u8,
        code: []const u8,
    };

    pub const Table = struct {
        rows: []TableRow,
        alignments: []Alignment,

        pub const Alignment = enum { none, left, center, right };
    };

    pub const TableRow = struct {
        cells: [][]Inline,
    };

    pub const BlockQuote = struct {
        blocks: []Block,
        depth: u8,
    };

    pub fn deinit(self: Block, allocator: std.mem.Allocator) void {
        switch (self) {
            .heading => |h| {
                freeInlines(allocator, h.content);
            },
            .paragraph => |p| {
                freeInlines(allocator, p.content);
            },
            .unordered_list_item, .ordered_list_item => |item| {
                allocator.free(item.marker);
                freeInlines(allocator, item.content);
                for (item.nested) |nested| nested.deinit(allocator);
                allocator.free(item.nested);
            },
            .task_list_item => |item| {
                freeInlines(allocator, item.content);
            },
            .fenced_code => |code| {
                allocator.free(code.language);
                allocator.free(code.code);
            },
            .html_block => |html| {
                allocator.free(html);
            },
            .thematic_break => {},
            .table => |table| {
                for (table.rows) |row| {
                    for (row.cells) |cell| freeInlines(allocator, cell);
                    allocator.free(row.cells);
                }
                allocator.free(table.rows);
                allocator.free(table.alignments);
            },
            .blockquote => |bq| {
                for (bq.blocks) |block| block.deinit(allocator);
                allocator.free(bq.blocks);
            },
        }
    }

    pub fn tag(self: Block) BlockTag {
        return switch (self) {
            .heading => .heading,
            .paragraph => .paragraph,
            .unordered_list_item => .unordered_list_item,
            .ordered_list_item => .ordered_list_item,
            .task_list_item => .task_list_item,
            .fenced_code => .fenced_code,
            .html_block => .html_block,
            .thematic_break => .thematic_break,
            .table => .table,
            .blockquote => .blockquote,
        };
    }
};

pub const Document = struct {
    blocks: []Block,

    pub fn deinit(self: Document, allocator: std.mem.Allocator) void {
        for (self.blocks) |block| block.deinit(allocator);
        allocator.free(self.blocks);
    }
};

fn freeInlines(allocator: std.mem.Allocator, inlines: []Inline) void {
    for (inlines) |inline_| inline_.deinit(allocator);
    allocator.free(inlines);
}
