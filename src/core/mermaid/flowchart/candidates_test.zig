const std = @import("std");
const prim = @import("prim");
const entry = @import("entry.zig");
const parse = @import("parse.zig").parse;
const candidates = @import("candidates.zig");

/// A clustered graph (where .bridge and .cross differ), a fan, and a 12-node LR
/// chain that must escalate rungs at width 20.
const sources = [_][]const u8{
    "flowchart TD\n  subgraph S\n    A --> C\n    B --> C\n  end\n  subgraph T\n    D --> F\n  end\n  C --> D\n  F --> A\n",
    "flowchart LR\n  A --> B & C & D & E\n  B & C & D & E --> F\n",
    "flowchart LR\n  A --> B --> C --> D --> E --> F --> G --> H --> I --> J --> K --> L\n",
};

const widths = [_]u32{ 20, 80 };
const modes = [_]prim.SubgraphEdges{ .bridge, .cross };

test "the chosen candidate paints the text the render returns and routes every edge whenever any candidate does" {
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

        if (mode == .bridge) {
            var any = false;
            for (listed) |c| any = any or candidates.routes(c);
            try std.testing.expectEqual(any, candidates.routes(listed[chosen]));
        }
    };
}
