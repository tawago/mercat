const std = @import("std");
const unicode = @import("unicode");
const entry = @import("entry.zig");

const testing = std.testing;

const budget: u32 = 90;

const verticals = [_][]const u8{ "│", "├", "┤" };
const top_fill = [_][]const u8{ "─", "┴", "┬" };

const Box = struct {
    top: usize,
    bottom: usize,
    left: usize,
    right: usize,

    fn width(self: Box) usize {
        return self.right - self.left + 1;
    }
};

const Rendered = struct {
    output: []const u8,
    lines: []const []const u8,
    boxes: []const Box,

    fn deinit(self: Rendered) void {
        testing.allocator.free(self.boxes);
        testing.allocator.free(self.lines);
        testing.allocator.free(self.output);
    }

    fn boxLabelled(self: Rendered, label: []const u8) !Box {
        for (self.boxes) |box| {
            var y = box.top + 1;
            while (y < box.bottom) : (y += 1) {
                const inside = columnRange(self.lines[y], box.left + 1, box.right) catch continue;
                if (std.mem.indexOf(u8, inside, label) != null) return box;
            }
        }
        std.debug.print("\nno box carries the label \"{s}\" in:\n{s}\n", .{ label, self.output });
        return error.LabelNotInAnyBox;
    }
};

fn columnRange(line: []const u8, start: usize, end: usize) unicode.MeasureError![]const u8 {
    var iter = unicode.Iterator.init(line);
    var byte_start: ?usize = null;
    var byte_end: usize = 0;
    while (try iter.next()) |grapheme| {
        if (grapheme.column_end <= start) continue;
        if (grapheme.column_start < start) continue;
        if (grapheme.column_end > end) break;
        if (byte_start == null) byte_start = grapheme.byte_start;
        byte_end = grapheme.byte_end;
    }
    const first = byte_start orelse return line[0..0];
    return line[first..byte_end];
}

fn renderPlain(source: []const u8) ![]const u8 {
    const result = try entry.renderFlowchart(testing.allocator, source, .{ .max_width = budget });
    if (result.is_fallback) return error.RenderFellBack;
    return result.output;
}

fn splitLines(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try out.append(a, line);
    return out.toOwnedSlice(a);
}

fn isOneOf(bytes: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, bytes, s)) return true;
    return false;
}

fn glyphAt(line: []const u8, col: usize) ?[]const u8 {
    var it = unicode.Iterator.init(line);
    while (it.next() catch return null) |g| {
        if (g.column_start == col) return g.bytes;
        if (g.column_start > col) return null;
    }
    return null;
}

fn firstColumnOf(line: []const u8, after: usize, wanted: []const []const u8) ?usize {
    var it = unicode.Iterator.init(line);
    while (it.next() catch return null) |g| {
        if (g.column_start <= after) continue;
        if (isOneOf(g.bytes, wanted)) return g.column_start;
    }
    return null;
}

const corners_and_heads = [_][]const u8{ "┌", "┐", "└", "┘", "▼", "▲", "◀", "▶" };

fn isLabelRow(line: []const u8, left: usize, right: usize) bool {
    var it = unicode.Iterator.init(line);
    while (it.next() catch return false) |g| {
        if (g.column_start <= left) continue;
        if (g.column_start >= right) break;
        if (isOneOf(g.bytes, &corners_and_heads)) return false;
    }
    return true;
}

fn bottomOf(lines: []const []const u8, top: usize, left: usize, right: usize) ?usize {
    var y = top + 1;
    while (y < lines.len) : (y += 1) {
        const g = glyphAt(lines[y], left) orelse "";
        if (std.mem.eql(u8, g, "└")) return if (y > top + 1) y else null;
        if (!isLabelRow(lines[y], left, right)) return null;
    }
    return null;
}

fn findBoxes(a: std.mem.Allocator, lines: []const []const u8) ![]const Box {
    var boxes: std.ArrayListUnmanaged(Box) = .empty;
    errdefer boxes.deinit(a);
    for (lines, 0..) |line, y| {
        var it = unicode.Iterator.init(line);
        var open: ?usize = null;
        while (try it.next()) |g| {
            if (std.mem.eql(u8, g.bytes, "┌")) {
                open = g.column_start;
                continue;
            }
            const left = open orelse continue;
            if (isOneOf(g.bytes, &top_fill)) continue;
            if (std.mem.eql(u8, g.bytes, "┐")) {
                if (bottomOf(lines, y, left, g.column_start)) |bottom| {
                    try boxes.append(a, .{ .top = y, .bottom = bottom, .left = left, .right = g.column_start });
                }
            }
            open = null;
        }
    }
    return boxes.toOwnedSlice(a);
}

fn printBox(r: Rendered, box: Box) void {
    var y = box.top;
    while (y <= box.bottom) : (y += 1) std.debug.print("  {s}\n", .{r.lines[y]});
}

fn expectEdgeAt(r: Rendered, box: Box, y: usize, col: usize, wanted: []const []const u8) !void {
    const got = glyphAt(r.lines[y], col) orelse "";
    if (isOneOf(got, wanted)) return;
    std.debug.print(
        "\nbox at rows {d}..{d} spans columns {d}..{d} by its top border, but row {d} holds \"{s}\" at column {d} (nearest edge glyph after the left edge sits at column {?d}):\n",
        .{ box.top, box.bottom, box.left, box.right, y, got, col, firstColumnOf(r.lines[y], box.left, wanted) },
    );
    printBox(r, box);
    return error.BoxEdgeDrifted;
}

fn expectBoxClosesAtOneColumn(r: Rendered, box: Box) !void {
    var y = box.top + 1;
    while (y < box.bottom) : (y += 1) {
        try expectEdgeAt(r, box, y, box.left, &verticals);
        try expectEdgeAt(r, box, y, box.right, &verticals);
    }
    try expectEdgeAt(r, box, box.bottom, box.right, &.{"┘"});
}

fn expectFitsBudget(r: Rendered) !void {
    for (r.lines, 0..) |line, y| {
        const w = unicode.displayWidth(line);
        if (w > budget) {
            std.debug.print("\nrow {d} is {d} columns wide, over the budget of {d}:\n  {s}\n", .{ y, w, budget, line });
            try testing.expect(w <= budget);
        }
    }
}

fn renderFramed(source: []const u8, node_count: usize) !Rendered {
    const output = try renderPlain(source);
    errdefer testing.allocator.free(output);
    const lines = try splitLines(testing.allocator, output);
    errdefer testing.allocator.free(lines);
    const boxes = try findBoxes(testing.allocator, lines);
    errdefer testing.allocator.free(boxes);
    const r = Rendered{ .output = output, .lines = lines, .boxes = boxes };

    for (boxes) |box| try expectBoxClosesAtOneColumn(r, box);
    if (boxes.len != node_count) {
        std.debug.print("\nexpected {d} node boxes, framed {d} in:\n{s}\n", .{ node_count, boxes.len, output });
        try testing.expectEqual(node_count, boxes.len);
    }
    try expectFitsBudget(r);
    return r;
}

test "an emoji node box closes at the same column on every row" {
    const r = try renderFramed(
        "flowchart TD\n    A[🚀 Launch] --> B[✅ Done]\n    A --> C[🔥 Hot]\n    C --> B\n",
        3,
    );
    defer r.deinit();
    _ = try r.boxLabelled("🚀 Launch");
    _ = try r.boxLabelled("✅ Done");
    _ = try r.boxLabelled("🔥 Hot");
}

test "an emoji-labelled return rail runs straight down under its corner" {
    const r = try renderFramed(
        "flowchart TD\n    A[Start] -->|🚀 go| B[Next]\n    B -->|✅ ok| C[Done]\n    C -->|🔥| A\n",
        3,
    );
    defer r.deinit();

    try testing.expect(std.mem.indexOf(u8, r.output, "🔥") != null);
    var corner_row: ?usize = null;
    for (r.lines, 0..) |line, y| {
        if (std.mem.indexOf(u8, line, "◀") != null) corner_row = y;
    }
    const top = corner_row orelse {
        std.debug.print("\nno `◀` landing row in:\n{s}\n", .{r.output});
        return error.NoReturnRailCorner;
    };
    const col = firstColumnOf(r.lines[top], 0, &.{"┐"}) orelse {
        std.debug.print("\nthe `◀` landing row has no `┐` corner:\n{s}\n", .{r.output});
        return error.NoReturnRailCorner;
    };

    var y = top + 1;
    while (y < r.lines.len) : (y += 1) {
        const g = glyphAt(r.lines[y], col) orelse "";
        if (std.mem.eql(u8, g, "┘")) return;
        if (!std.mem.eql(u8, g, "│")) {
            std.debug.print(
                "\nthe rail corner `┐` sits at column {d} on row {d}, but row {d} holds \"{s}\" there:\n{s}\n",
                .{ col, top, y, g, r.output },
            );
            try testing.expectEqualStrings("│", g);
        }
    }
    std.debug.print("\nthe rail under column {d} never reaches its `┘`:\n{s}\n", .{ col, r.output });
    return error.RailNeverCloses;
}

test "a decomposed accent yields a box exactly as wide as the precomposed one" {
    const r = try renderFramed(
        "flowchart TD\n    A[café] --> B[cafe\u{0301}]\n    A --> C[naïve]\n    C --> D[nai\u{0308}ve]\n",
        4,
    );
    defer r.deinit();
    const cafe = try r.boxLabelled("café");
    const cafe_decomposed = try r.boxLabelled("cafe\u{0301}");
    const naive = try r.boxLabelled("naïve");
    const naive_decomposed = try r.boxLabelled("nai\u{0308}ve");
    try testing.expectEqual(cafe.width(), cafe_decomposed.width());
    try testing.expectEqual(naive.width(), naive_decomposed.width());
}

test "ZWJ, flag, variation-selector and skin-tone labels box consistently and survive verbatim" {
    const labels = [_][]const u8{ "👨‍👩‍👧 Team", "🇯🇵 JP", "❤️ Love", "👍🏽 OK" };
    for (labels) |label| {
        const source = try std.fmt.allocPrint(testing.allocator, "flowchart TD\n    A[{s}] --> B[End]\n", .{label});
        defer testing.allocator.free(source);
        const r = try renderFramed(source, 2);
        defer r.deinit();
        _ = try r.boxLabelled(label);
    }
}

test "an all-ASCII diagram paints byte-for-byte as before" {
    const r = try renderFramed("flowchart TD\n    A[Start] --> B[End]\n", 2);
    defer r.deinit();
    try testing.expectEqualStrings(
        "┌───────┐    ┌─────┐\n" ++
            "│ Start ├───▶│ End │\n" ++
            "└───────┘    └─────┘\n",
        r.output,
    );
}
