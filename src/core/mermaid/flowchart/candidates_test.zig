const std = @import("std");
const prim = @import("prim");
const entry = @import("entry.zig");
const parse = @import("parse.zig").parse;
const candidates = @import("candidates.zig");

const sources = [_][]const u8{
    "flowchart TD\n  A --> B\n  B --> C\n",
    "flowchart LR\n  A --> B & C & D & E\n  B & C & D & E --> F\n",
    "flowchart TD\n  A[a long label that needs wrapping at narrow widths] --> B[another long label here]\n  B --> C\n  C --> A\n",
    "flowchart LR\n  A --> B --> C --> D --> E --> F --> G --> H --> I --> J --> K --> L\n",
    "flowchart TD\n  subgraph S\n    A --> C\n    B --> C\n  end\n  subgraph T\n    D --> F\n  end\n  C --> D\n  F --> A\n",
    "flowchart TD\n  A --> B1 --> C1\n  A --> B2 --> C2\n  A --> B3 --> C3\n  C1 & C2 & C3 --> Z\n",
};

const widths = [_]u32{ 20, 40, 80, 120 };
const modes = [_]prim.SubgraphEdges{ .bridge, .cross };

test "the chosen candidate paints the text the render returns" {
    for (sources) |source| for (widths) |width| for (modes) |mode| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const graph = try parse(a, source);
        const listed = try candidates.list(a, graph, width);
        try std.testing.expect(listed.len > 0);
        const chosen = try candidates.choose(a, graph, listed, mode);
        const drawn = try candidates.draw(a, listed[chosen], mode);

        const rendered = try entry.renderFlowchart(std.testing.allocator, source, .{ .max_width = width, .subgraph_edges = mode });
        defer std.testing.allocator.free(rendered.output);
        try std.testing.expect(!rendered.is_fallback);
        try std.testing.expectEqualStrings(rendered.output, drawn.text);
    };
}

test "the chosen candidate routes every edge whenever any candidate does" {
    for (sources) |source| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const graph = try parse(a, source);
        const listed = try candidates.list(a, graph, width);
        const chosen = try candidates.choose(a, graph, listed, .bridge);
        var any = false;
        for (listed) |c| any = any or candidates.routes(c);
        try std.testing.expectEqual(any, candidates.routes(listed[chosen]));
    };
}

test "listing, drawing and scoring twice give the same values" {
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const graph = try parse(a, source);
        const first = try candidates.list(a, graph, 60);
        const second = try candidates.list(a, graph, 60);
        try std.testing.expectEqual(first.len, second.len);
        for (first, second, 0..) |left, right, i| {
            try std.testing.expectEqual(left.rung, right.rung);
            try std.testing.expectEqual(left.transform, right.transform);
            const drawn_left = try candidates.draw(a, left, .bridge);
            const drawn_right = try candidates.draw(a, right, .bridge);
            try std.testing.expectEqualStrings(drawn_left.text, drawn_right.text);
            const eval_left = try candidates.evaluate(a, graph, first, i, .bridge);
            const eval_right = try candidates.evaluate(a, graph, second, i, .bridge);
            try std.testing.expectEqualDeep(eval_left, eval_right);
        }
    }
}

test "a candidate is scored at its place in the full list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const graph = try parse(a, sources[1]);
    const listed = try candidates.list(a, graph, 40);
    for (0..listed.len) |i| {
        const evaluation = try candidates.evaluate(a, graph, listed, i, .bridge);
        try std.testing.expectEqual(@as(u32, @intCast(i)), evaluation.score.t4_index);
    }
}
