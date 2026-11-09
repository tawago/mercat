const std = @import("std");
const markdown = @import("../parser.zig");
const Builder = @import("builder.zig").Builder;
const decor_mod = @import("decor.zig");
const code = @import("code.zig");

const Block = markdown.Block;
const testing = std.testing;

fn renderPanelText(allocator: std.mem.Allocator, source: []const u8, content_width: usize) ![]u8 {
    return renderBlockText(allocator, "", source, content_width, false);
}

fn renderBlockText(allocator: std.mem.Allocator, language: []const u8, source: []const u8, content_width: usize, debug_mermaid: bool) ![]u8 {
    const block = Block.CodeBlock{ .language = language, .code = source };
    const decor = decor_mod.Decor{};
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try code.render(allocator, &builder, block, content_width, debug_mermaid, .bridge, &decor);
    const lines = try builder.finish();
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (lines) |line| {
        for (line.spans) |span| try out.appendSlice(allocator, span.text);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

test "code panel pads short lines out to the widest line" {
    const allocator = testing.allocator;
    const out = try renderPanelText(allocator, "ab\nlonger line", 80);
    defer allocator.free(out);
    var rows = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    try testing.expectEqualStrings("```", rows.next().?);
    try testing.expectEqualStrings(" ab          ", rows.next().?);
    try testing.expectEqualStrings(" longer line ", rows.next().?);
    try testing.expectEqualStrings("```", rows.next().?);
}

test "code panel padding is capped at the content width" {
    const allocator = testing.allocator;
    const long = try allocator.alloc(u8, 50_000);
    defer allocator.free(long);
    @memset(long, 'x');
    const source = try std.fmt.allocPrint(allocator, "a\n{s}\n\nb", .{long});
    defer allocator.free(source);
    const out = try renderPanelText(allocator, source, 80);
    defer allocator.free(out);
    var rows = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    _ = rows.next();
    try testing.expectEqual(@as(usize, 80), rows.next().?.len);
    try testing.expect(rows.next().?.len >= 50_000);
    try testing.expectEqual(@as(usize, 80), rows.next().?.len);
    try testing.expectEqual(@as(usize, 80), rows.next().?.len);
}

test "--debug-mermaid prints its block above a drawn diagram" {
    const allocator = testing.allocator;
    const out = try renderBlockText(allocator, "mermaid", "graph TD\nA-->B", 40, true);
    defer allocator.free(out);
    const marker = "---debug-mermaid---\n";
    try testing.expect(std.mem.startsWith(u8, out, marker));
    const close = std.mem.indexOfPos(u8, out, marker.len, marker).?;
    // The diagram is drawn (a box), below the block.
    try testing.expect(std.mem.indexOfPos(u8, out, close + marker.len, "\u{250C}") != null);
}

test "a flowchart the parser refuses shows its banner above the source" {
    const allocator = testing.allocator;
    std.testing.log_level = .err;
    const out = try renderBlockText(allocator, "mermaid", "graph TD\nA -->", 40, true);
    defer allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "<PARSE ERROR"));
    const banner_end = std.mem.indexOfScalar(u8, out, '\n').?;
    try testing.expect(std.mem.startsWith(u8, out[banner_end + 1 ..], "```mermaid\n graph TD "));
}

test "a diagram too wide for the width shows its source with no banner" {
    const allocator = testing.allocator;
    const out = try renderBlockText(allocator, "mermaid", "sequenceDiagram\nAlice->>Bob: averyverylongmessagetextwithnospace", 20, true);
    defer allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "```mermaid\n sequenceDiagram "));
}

test "a coloured flowchart fence gives spans with a foreground, and the text stays the diagram's" {
    const allocator = testing.allocator;
    const plain_src = "flowchart TD\nA --> B\n";
    const coloured_src = "flowchart TD\nA:::k --> B\nclassDef k stroke:#f00\nlinkStyle 0 stroke:#00f\n";
    const plain = try renderBlockText(allocator, "mermaid", plain_src, 80, false);
    defer allocator.free(plain);
    const coloured = try renderBlockText(allocator, "mermaid", coloured_src, 80, false);
    defer allocator.free(coloured);
    try testing.expectEqualStrings(plain, coloured);

    const block = Block.CodeBlock{ .language = "mermaid", .code = coloured_src };
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try code.render(allocator, &builder, block, 80, false, .bridge, &decor_mod.Decor{});
    const lines = try builder.finish();
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }
    var red = false;
    var blue = false;
    for (lines) |line| for (line.spans) |span| {
        const fg = span.fg orelse continue;
        if (fg.r == 0xff and fg.g == 0 and fg.b == 0) red = true;
        if (fg.r == 0 and fg.g == 0 and fg.b == 0xff) blue = true;
    };
    try testing.expect(red and blue);
}

test "adjacent spans of one style but different foregrounds stay apart" {
    const allocator = testing.allocator;
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.appendSpanFg(.code, "a", .{ .r = 1, .g = 2, .b = 3 });
    try builder.appendSpanFg(.code, "b", .{ .r = 1, .g = 2, .b = 3 });
    try builder.appendSpanFg(.code, "c", .{ .r = 9, .g = 9, .b = 9 });
    try builder.appendSpan(.code, "d");
    const lines = try builder.finish();
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }
    try testing.expectEqual(@as(usize, 3), lines[0].spans.len);
    try testing.expectEqualStrings("ab", lines[0].spans[0].text);
    try testing.expectEqual(@as(?u8, null), if (lines[0].spans[2].fg) |c| c.r else null);
}

test "a standalone diagram draws in body ink, a fence in code ink" {
    const allocator = testing.allocator;
    for ([_]bool{ false, true }) |standalone| {
        const block = Block.CodeBlock{ .language = "mermaid", .code = "flowchart TD\nA --> B\n", .standalone = standalone };
        var builder = Builder.init(allocator);
        defer builder.deinit();
        try code.render(allocator, &builder, block, 80, false, .bridge, &decor_mod.Decor{});
        const lines = try builder.finish();
        defer {
            for (lines) |line| line.deinit(allocator);
            allocator.free(lines);
        }
        const want: @TypeOf(lines[0].spans[0].style) = if (standalone) .body else .code;
        for (lines) |line| for (line.spans) |span| try testing.expectEqual(want, span.style);
    }
}
