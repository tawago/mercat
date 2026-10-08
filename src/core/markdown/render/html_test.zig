const std = @import("std");
const html = @import("html.zig");
const markdown = @import("../parser.zig");

const Inline = markdown.Inline;
const testing = std.testing;

/// Flattens converted inlines: text as-is, `|` for a line break,
/// `{img alt -> url}`, `{link text -> url}`, `{html tag}`.
fn describe(allocator: std.mem.Allocator, out: *std.ArrayList(u8), inlines: []const Inline) anyerror!void {
    for (inlines) |inline_| switch (inline_) {
        .text => |t| try out.appendSlice(allocator, t),
        .line_break => try out.append(allocator, '|'),
        .image => |image| {
            try out.appendSlice(allocator, "{img ");
            try describe(allocator, out, image.alt);
            try out.print(allocator, " -> {s}}}", .{image.url});
        },
        .link => |link| {
            try out.appendSlice(allocator, "{link ");
            try describe(allocator, out, link.text);
            try out.print(allocator, " -> {s}}}", .{link.url});
        },
        .html => |h| try out.print(allocator, "{{html {s}}}", .{h}),
        else => try out.appendSlice(allocator, "?"),
    };
}

fn expectConverted(source: []const u8, expected: []const u8) !void {
    const allocator = testing.allocator;
    const inlines = try html.toInlines(allocator, source);
    defer {
        for (inlines) |inline_| inline_.deinit(allocator);
        allocator.free(inlines);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try describe(allocator, &out, inlines);
    try testing.expectEqualStrings(expected, out.items);
}

test "details and summary become a marker line; wrappers vanish" {
    try expectConverted("<details>\n<summary>More</summary>", "\u{25B8} More");
    try expectConverted("<details>\n<summary> More info </summary>\n\nBody\n</details>", "\u{25B8} More info|Body");
    try expectConverted("</details>", "");
}

test "centered paragraph with an image renders the image like markdown" {
    try expectConverted("<p align=\"center\">\n  <img src=\"x.png\" alt=\"logo\">\n</p>", "{img logo -> x.png}");
    try expectConverted("<img src='docs/shot.png'>", "{img shot.png -> docs/shot.png}");
    try expectConverted("<img alt=\"A\" src=\"s\" width=200/>", "{img A -> s}");
}

test "comments are hidden, including multi-line and unterminated ones" {
    try expectConverted("<!-- hidden -->", "");
    try expectConverted("<!--\nline\n-->\n<div>shown</div>", "shown");
    try expectConverted("before <!-- never closed", "before");
}

test "br breaks lines and whitespace collapses as in HTML" {
    try expectConverted("<p>one<br>two<br/>three<br />four</p>", "one|two|three|four");
    try expectConverted("<div>\n  a\n  b   c\n</div>\n<div>d</div>", "a b c|d");
    try expectConverted("<br><br>x<br><br>", "x");
}

test "anchors become links; inline formatting tags keep their text" {
    try expectConverted("<a href=\"https://x\"><img alt=\"CI\" src=\"b.svg\"></a> <a href=\"u\">doc</a>", "{link {img CI -> b.svg} -> https://x} {link doc -> u}");
    try expectConverted("<p>Hello <b>bold</b> and <em>it</em></p>", "Hello bold and it");
    try expectConverted("<a name=\"top\"></a>", "");
}

test "anchors with an empty href or no content add no stray link or space" {
    try expectConverted("<a href=\"\">x</a>", "{link x -> }");
    try expectConverted("<p>a <a href=\"\"></a> b</p>", "a b");
    try expectConverted("<p>a <a href=\"\"> </a> b</p>", "a b");
    try expectConverted("<p><a href=\"\"></a>b</p>", "b");
    try expectConverted("<p>a <a href=\"u\"></a> b</p>", "a {link  -> u} b");
    try expectConverted("<p>a <a href=\"u\">t</a></p>", "a {link t -> u}");
}

test "unknown and styling tags are kept; entities decode; stray < stays text" {
    try expectConverted("<aside>raw html</aside>", "raw html");
    try expectConverted("<sup>2</sup>", "{html <sup>}2{html </sup>}");
    try expectConverted("<custom-tag x=1>y</custom-tag>", "{html <custom-tag x=1>}y{html </custom-tag>}");
    try expectConverted("<p>a &lt; b &amp;&amp; c</p>", "a < b && c");
    try expectConverted("<p>1 < 2</p>", "1 < 2");
}

test "pre keeps its line structure and inner spacing" {
    try expectConverted("<pre>\na  b\n  c\n</pre>", "a  b|  c");
    try expectConverted("<pre>x</pre>\n<p>y   z</p>", "x|y z");
}

test "table cells are separated by spaces, rows by lines" {
    try expectConverted("<table>\n<tr><td>a</td><td>b</td></tr>\n<tr><td>c</td></tr>\n</table>", "a b|c");
}

test "attrValue handles quoting and attribute boundaries" {
    try testing.expectEqualStrings("x.png", html.attrValue("<img data-src=\"no\" src=\"x.png\">", "src").?);
    try testing.expectEqualStrings("a b", html.attrValue("<img alt='a b'>", "alt").?);
    try testing.expectEqualStrings("v", html.attrValue("<img alt = v>", "alt").?);
    try testing.expect(html.attrValue("<img title=\"src=no\">", "src") == null);
    try testing.expect(html.attrValue("<img alt-text=\"q\">", "alt") == null);
}
