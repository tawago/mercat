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
    var rows = std.mem.splitScalar(u8, std.mem.trimRight(u8, out, "\n"), '\n');
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
    var rows = std.mem.splitScalar(u8, std.mem.trimRight(u8, out, "\n"), '\n');
    _ = rows.next();
    try testing.expectEqual(@as(usize, 80), rows.next().?.len);
    try testing.expect(rows.next().?.len >= 50_000);
    try testing.expectEqual(@as(usize, 80), rows.next().?.len);
    try testing.expectEqual(@as(usize, 80), rows.next().?.len);
}

test "--debug-mermaid prints its fixed block above a drawn diagram" {
    const allocator = testing.allocator;
    const out = try renderBlockText(allocator, "mermaid", "graph TD\nA-->B", 40, true);
    defer allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out,
        \\---debug-mermaid---
        \\Algorithm: Unknown
        \\Nodes: 0
        \\Edges: 0
        \\Tree detected: no
        \\Cyclic: no
        \\Width constraint triggered: no
        \\---debug-mermaid---
        \\┌───┐
        \\
    ));
}

test "a flowchart the parser refuses shows its banner above the source" {
    const allocator = testing.allocator;
    std.testing.log_level = .err;
    const out = try renderBlockText(allocator, "mermaid", "graph TD\nA -->", 40, true);
    defer allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "<PARSE ERROR: v2 pipeline error: parse>\n```mermaid\n graph TD "));
}

test "a diagram too wide for the width shows its source with no banner" {
    const allocator = testing.allocator;
    const out = try renderBlockText(allocator, "mermaid", "sequenceDiagram\nAlice->>Bob: a very long message text here", 20, true);
    defer allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "```mermaid\n sequenceDiagram "));
}
