const std = @import("std");
const parser = @import("parser.zig");

const Inline = parser.Inline;
const testing = std.testing;

/// Compact shape of an inline run: `S(...)` strong, `E(...)` emphasis,
/// `C(...)` code, `L(...)` link, `I(...)` image, literal text as-is.
fn shape(allocator: std.mem.Allocator, out: *std.ArrayList(u8), inlines: []const Inline) anyerror!void {
    for (inlines) |inline_| switch (inline_) {
        .text => |t| try out.appendSlice(allocator, t),
        .code => |c| try out.print(allocator, "C({s})", .{c}),
        .html => |h| try out.appendSlice(allocator, h),
        .strong => |children| try wrapShape(allocator, out, "S", children),
        .emphasis => |children| try wrapShape(allocator, out, "E", children),
        .strikethrough => |children| try wrapShape(allocator, out, "X", children),
        .link => |link| try wrapShape(allocator, out, "L", link.text),
        .image => |image| try wrapShape(allocator, out, "I", image.alt),
        .soft_break, .line_break => try out.append(allocator, '/'),
    };
}

fn wrapShape(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tag: []const u8, children: []const Inline) !void {
    try out.appendSlice(allocator, tag);
    try out.append(allocator, '(');
    try shape(allocator, out, children);
    try out.append(allocator, ')');
}

fn expectParagraphShape(source: []const u8, expected: []const u8) !void {
    const allocator = testing.allocator;
    var doc = try parser.parse(allocator, source);
    defer doc.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try shape(allocator, &out, doc.blocks[0].paragraph.content);
    try testing.expectEqualStrings(expected, out.items);
}

test "emphasis before a link" {
    try expectParagraphShape("**bold** [link](http://x)", "S(bold) L(link)");
    try expectParagraphShape("*it* [l](u)", "E(it) L(l)");
    try expectParagraphShape("__b__ [l](u)", "S(b) L(l)");
    try expectParagraphShape("_e_ [l](u)", "E(e) L(l)");
    try expectParagraphShape("`code` [l](u)", "C(code) L(l)");
    try expectParagraphShape("**b** and **c** [l](u)", "S(b) and S(c) L(l)");
    try expectParagraphShape("**b**[l](u)", "S(b)L(l)");
    try expectParagraphShape("**b** ![alt](i.png)", "S(b) I(alt)");
}

test "emphasis around and inside links" {
    try expectParagraphShape("[l](u) **b**", "L(l) S(b)");
    try expectParagraphShape("[**b** in](u)", "L(S(b) in)");
    try expectParagraphShape("**[l](u)**", "S(L(l))");
    try expectParagraphShape("*a* [**b**](u) *c*", "E(a) L(S(b)) E(c)");
    try expectParagraphShape("**open [l](u) close**", "S(open L(l) close)");
}
