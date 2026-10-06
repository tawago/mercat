//! Raw HTML blocks, shown the way a reader would see them rather than as
//! markup: comments are hidden, layout-only wrapper tags (`<p align=...>`,
//! `<div>`, `<details>`, `<center>`, ...) are dropped while their text is
//! kept, `<summary>X</summary>` becomes `▸ X`, `<br>` breaks the line, and
//! `<img>` / `<a href>` render like markdown images and links. Whitespace is
//! collapsed as in HTML, except that `<pre>` keeps its line breaks and inner
//! spacing. Tags it does not know are kept, muted.
const std = @import("std");
const markdown = @import("../parser.zig");
const builder_mod = @import("builder.zig");
const wrap = @import("wrap.zig");
const decor_mod = @import("decor.zig");

const Inline = markdown.Inline;
const Builder = builder_mod.Builder;

pub const summary_marker = "\u{25B8}";

/// Renders `html` as wrapped body text, one output line per HTML line break.
/// Renders nothing when the block has no visible content (see `isEmpty`).
pub fn render(allocator: std.mem.Allocator, builder: *Builder, html: []const u8, width: usize, decor: *const decor_mod.Decor) !void {
    const inlines = try toInlines(allocator, html);
    defer freeInlines(allocator, inlines);

    var start: usize = 0;
    var first = true;
    for (inlines, 0..) |inline_, index| {
        if (inline_ != .line_break) continue;
        try renderLine(allocator, builder, inlines[start..index], width, first, decor);
        first = false;
        start = index + 1;
    }
    if (start < inlines.len) try renderLine(allocator, builder, inlines[start..], width, first, decor);
}

fn renderLine(allocator: std.mem.Allocator, builder: *Builder, inlines: []const Inline, width: usize, first: bool, decor: *const decor_mod.Decor) !void {
    if (!first) try builder.newline();
    try wrap.renderWrappedInlines(allocator, builder, inlines, width, .body, "", .body, "", .body, decor);
}

/// True when the block shows nothing (only comments, wrapper tags and
/// whitespace), e.g. a lone `</details>`; the document skips such blocks.
pub fn isEmpty(allocator: std.mem.Allocator, html: []const u8) !bool {
    const inlines = try toInlines(allocator, html);
    defer freeInlines(allocator, inlines);
    return inlines.len == 0;
}

const TagKind = enum {
    /// Dropped; separates lines (`<p>`, `<div>`, `<details>`, `<center>`, ...).
    block_wrapper,
    /// Dropped without a break (`<span>`, `<b>`, `<picture>`, ...).
    inline_wrapper,
    /// A table cell: dropped, leaves a space between cells.
    cell,
    line_break,
    summary,
    image,
    anchor,
    /// Kept verbatim: inline styling (`<sup>`, `<sub>`, `<mark>`) or unknown.
    keep,
};

const block_wrappers = [_][]const u8{
    "p",     "div",  "details", "center", "section",    "article", "header", "footer",
    "nav",   "main", "aside",   "figure", "figcaption", "table",   "thead",  "tbody",
    "tfoot", "tr",   "ul",      "ol",     "li",         "dl",      "dt",     "dd",
    "h1",    "h2",   "h3",      "h4",     "h5",         "h6",      "hr",     "blockquote",
    "pre",
};

const inline_wrappers = [_][]const u8{
    "span",  "picture", "source", "b",    "strong", "i",     "em",    "u",
    "small", "big",     "font",   "code", "kbd",    "samp",  "abbr",  "ins",
    "del",   "s",       "tt",     "var",  "cite",   "label", "video", "audio",
};

fn classify(name: []const u8) TagKind {
    if (eqlAny(name, &block_wrappers)) return .block_wrapper;
    if (eqlAny(name, &inline_wrappers)) return .inline_wrapper;
    if (eqlAny(name, &.{ "td", "th" })) return .cell;
    if (std.ascii.eqlIgnoreCase(name, "br")) return .line_break;
    if (std.ascii.eqlIgnoreCase(name, "summary")) return .summary;
    if (std.ascii.eqlIgnoreCase(name, "img")) return .image;
    if (std.ascii.eqlIgnoreCase(name, "a")) return .anchor;
    return .keep;
}

fn eqlAny(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    return false;
}

const Tag = struct {
    /// The whole tag, `<` through `>`.
    text: []const u8,
    name: []const u8,
    closing: bool,
};

/// Parses a tag starting at `html[start] == '<'`, or null when the `<` does
/// not start a tag (it is then literal text, as in `a < b`).
fn parseTag(html: []const u8, start: usize) ?Tag {
    var i = start + 1;
    const closing = i < html.len and html[i] == '/';
    if (closing) i += 1;
    const name_start = i;
    if (i >= html.len or !std.ascii.isAlphabetic(html[i])) return null;
    while (i < html.len and (std.ascii.isAlphanumeric(html[i]) or html[i] == '-')) i += 1;
    const name = html[name_start..i];
    var quote: u8 = 0;
    while (i < html.len) : (i += 1) {
        const ch = html[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '>') {
            return .{ .text = html[start .. i + 1], .name = name, .closing = closing };
        }
    }
    return null;
}

/// The value of attribute `name` in `tag`, unquoted, or null.
pub fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < tag.len) : (i += 1) {
        const ch = tag[i];
        if (ch == '"' or ch == '\'') {
            const close = std.mem.indexOfScalarPos(u8, tag, i + 1, ch) orelse return null;
            i = close;
            continue;
        }
        if (!std.ascii.isWhitespace(ch)) continue;
        var j = i + 1;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) j += 1;
        if (j + name.len >= tag.len or !std.ascii.eqlIgnoreCase(tag[j .. j + name.len], name)) continue;
        var k = j + name.len;
        while (k < tag.len and std.ascii.isWhitespace(tag[k])) k += 1;
        if (k >= tag.len or tag[k] != '=') continue;
        k += 1;
        while (k < tag.len and std.ascii.isWhitespace(tag[k])) k += 1;
        if (k >= tag.len) return null;
        if (tag[k] == '"' or tag[k] == '\'') {
            const close = std.mem.indexOfScalarPos(u8, tag, k + 1, tag[k]) orelse return null;
            return tag[k + 1 .. close];
        }
        var end = k;
        while (end < tag.len and !std.ascii.isWhitespace(tag[end]) and tag[end] != '>' and tag[end] != '/') end += 1;
        return tag[k..end];
    }
    return null;
}

/// Converts an HTML block to inlines; `.line_break` separates output lines.
/// Never starts or ends with a break and never has two in a row.
pub fn toInlines(allocator: std.mem.Allocator, html: []const u8) ![]Inline {
    var conv: Converter = .{ .allocator = allocator };
    defer conv.deinit();

    var i: usize = 0;
    while (i < html.len) {
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len;
            i = @min(end + 3, html.len);
            continue;
        }
        if (html[i] == '<') {
            if (parseTag(html, i)) |tag| {
                try conv.tag(tag);
                i += tag.text.len;
                continue;
            }
        }
        if (html[i] == '&') {
            if (decodeEntity(html[i..])) |entity| {
                try conv.text(entity.text);
                i += entity.len;
                continue;
            }
        }
        if (std.ascii.isWhitespace(html[i])) {
            if (!conv.preformatted) {
                conv.pending_space = true;
            } else if (html[i] == '\n') {
                try conv.lineBreak();
            } else if (html[i] == ' ' or html[i] == '\t') {
                try conv.text(html[i .. i + 1]);
            }
            i += 1;
            continue;
        }
        try conv.text(html[i .. i + 1]);
        i += 1;
    }
    try conv.closeLink();
    try conv.flushText();
    while (conv.out.items.len > 0 and conv.out.items[conv.out.items.len - 1] == .line_break) _ = conv.out.pop();
    return conv.out.toOwnedSlice(allocator);
}

const Converter = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(Inline) = .empty,
    buf: std.ArrayList(u8) = .empty,
    /// Whitespace was seen; emit one space before the next visible content.
    pending_space: bool = false,
    /// The current line has visible content.
    line_started: bool = false,
    preformatted: bool = false,
    link_start: ?usize = null,
    link_url: []const u8 = "",
    /// A space was pending when the open link began; it goes before the
    /// link only if the link shows something.
    link_space: bool = false,

    fn deinit(self: *Converter) void {
        for (self.out.items) |item| item.deinit(self.allocator);
        self.out.deinit(self.allocator);
        self.buf.deinit(self.allocator);
    }

    fn beginContent(self: *Converter) !void {
        if (self.pending_space and self.line_started) try self.buf.append(self.allocator, ' ');
        self.pending_space = false;
        self.line_started = true;
    }

    fn text(self: *Converter, bytes: []const u8) !void {
        try self.beginContent();
        try self.buf.appendSlice(self.allocator, bytes);
    }

    fn flushText(self: *Converter) !void {
        if (self.buf.items.len == 0) return;
        const owned = try self.allocator.dupe(u8, self.buf.items);
        errdefer self.allocator.free(owned);
        try self.out.append(self.allocator, .{ .text = owned });
        self.buf.clearRetainingCapacity();
    }

    /// Appends `item`; on error the caller still owns it.
    fn push(self: *Converter, item: Inline) !void {
        try self.beginContent();
        try self.flushText();
        try self.out.append(self.allocator, item);
    }

    fn lineBreak(self: *Converter) !void {
        self.pending_space = false;
        if (!self.line_started) return;
        try self.flushText();
        try self.out.append(self.allocator, .line_break);
        self.line_started = false;
    }

    fn closeLink(self: *Converter) !void {
        const start = self.link_start orelse return;
        self.link_start = null;
        try self.flushText();
        if (self.out.items.len == start and self.link_url.len == 0) {
            // `<a href=""></a>`: nothing to show, and no doubled space.
            self.pending_space = self.pending_space or self.link_space;
            return;
        }
        var link_at = start;
        if (self.link_space) {
            const space = try self.allocator.dupe(u8, " ");
            errdefer self.allocator.free(space);
            try self.out.insert(self.allocator, start, .{ .text = space });
            link_at += 1;
        }
        const children = try self.allocator.dupe(Inline, self.out.items[link_at..]);
        errdefer self.allocator.free(children);
        const url = try self.allocator.dupe(u8, self.link_url);
        errdefer self.allocator.free(url);
        try self.out.ensureUnusedCapacity(self.allocator, 1);
        self.out.shrinkRetainingCapacity(link_at);
        self.out.appendAssumeCapacity(.{ .link = .{ .text = children, .url = url } });
    }

    fn tag(self: *Converter, t: Tag) !void {
        switch (classify(t.name)) {
            .block_wrapper => {
                try self.lineBreak();
                if (std.ascii.eqlIgnoreCase(t.name, "pre")) self.preformatted = !t.closing;
            },
            .inline_wrapper => {},
            .cell => if (!t.closing) {
                self.pending_space = true;
            },
            .line_break => try self.lineBreak(),
            .summary => if (t.closing) try self.lineBreak() else {
                try self.lineBreak();
                try self.text(summary_marker);
                self.pending_space = true;
            },
            .image => try self.image(t.text),
            .anchor => if (t.closing) try self.closeLink() else {
                try self.closeLink();
                const href = attrValue(t.text, "href") orelse return;
                try self.flushText();
                self.link_space = self.pending_space and self.line_started;
                self.pending_space = false;
                self.link_start = self.out.items.len;
                self.link_url = href;
            },
            .keep => {
                const raw = try self.allocator.dupe(u8, t.text);
                errdefer self.allocator.free(raw);
                try self.push(.{ .html = raw });
            },
        }
    }

    fn image(self: *Converter, tag_text: []const u8) !void {
        const src = attrValue(tag_text, "src") orelse "";
        const alt_text = attrValue(tag_text, "alt") orelse std.fs.path.basename(src);
        const url = try self.allocator.dupe(u8, src);
        errdefer self.allocator.free(url);
        const alt_owned = try self.allocator.dupe(u8, alt_text);
        errdefer self.allocator.free(alt_owned);
        const alt = try self.allocator.alloc(Inline, 1);
        errdefer self.allocator.free(alt);
        alt[0] = .{ .text = alt_owned };
        try self.push(.{ .image = .{ .alt = alt, .url = url } });
    }
};

const Entity = struct { text: []const u8, len: usize };

const named_entities = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "&amp;", .text = "&" },
    .{ .name = "&lt;", .text = "<" },
    .{ .name = "&gt;", .text = ">" },
    .{ .name = "&quot;", .text = "\"" },
    .{ .name = "&apos;", .text = "'" },
    .{ .name = "&#39;", .text = "'" },
    .{ .name = "&nbsp;", .text = "\u{00A0}" },
    .{ .name = "&copy;", .text = "\u{00A9}" },
    .{ .name = "&mdash;", .text = "\u{2014}" },
    .{ .name = "&ndash;", .text = "\u{2013}" },
    .{ .name = "&hellip;", .text = "\u{2026}" },
};

fn decodeEntity(rest: []const u8) ?Entity {
    for (named_entities) |entity| {
        if (std.mem.startsWith(u8, rest, entity.name)) return .{ .text = entity.text, .len = entity.name.len };
    }
    return null;
}

fn freeInlines(allocator: std.mem.Allocator, inlines: []Inline) void {
    for (inlines) |inline_| inline_.deinit(allocator);
    allocator.free(inlines);
}

test {
    _ = @import("html_test.zig");
}
