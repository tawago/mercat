const std = @import("std");
const parser = @import("../parse.zig");
const sg = @import("../sem_graph.zig");

const parse = parser.parse;
const Direction = sg.Direction;
const NodeShape = sg.NodeShape;
const EdgeKind = sg.EdgeKind;
const ArrowEnd = sg.ArrowEnd;
const NodeId = sg.NodeId;
const ClusterId = sg.ClusterId;

const t = std.testing;

fn findNode(g: sg.SemGraph, raw_id: []const u8) ?NodeId {
    for (g.nodes) |n| {
        if (std.mem.eql(u8, n.raw_id, raw_id)) return n.id;
    }
    return null;
}

test "empty graph" {
    var g = try parse(t.allocator, "flowchart TD\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(Direction.TD, g.direction);
    try t.expectEqual(@as(usize, 0), g.nodes.len);
    try t.expectEqual(@as(usize, 0), g.edges.len);
}

test "single edge implicit nodes" {
    var g = try parse(t.allocator, "flowchart TD\nA --> B\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.nodes.len);
    try t.expectEqual(@as(usize, 1), g.edges.len);
    try t.expectEqual(EdgeKind.solid, g.edges[0].kind);
    try t.expectEqual(ArrowEnd.filled, g.edges[0].arrow_to);
    try t.expectEqual(ArrowEnd.none, g.edges[0].arrow_from);
}

test "all shapes" {
    const src = "flowchart LR\nA[rect]\nB(round)\nC((circle))\nD[[sub]]\nE[(cyl)]\nF([stad])\nG{rhom}\nH{{hex}}\nI>asym]\nJ[/par/]\nK[\\paralt\\]\nL[/trap\\]\nM[\\trapalt/]\nS(((Start)))\nN[]\n";
    var g = try parse(t.allocator, src);
    defer g.deinit(t.allocator);
    const want = [_]NodeShape{ .rect, .round, .circle, .subroutine, .cylinder, .stadium, .rhombus, .hexagon, .asymmetric_right, .parallelogram, .parallelogram_alt, .trapezoid, .trapezoid_alt, .double_circle, .rect };
    try t.expectEqual(want.len, g.nodes.len);
    for (want, 0..) |w, i| try t.expectEqual(w, g.nodes[i].shape);
    try t.expectEqualStrings("rect", g.nodes[0].label);
    try t.expectEqualStrings("stad", g.nodes[5].label);
    try t.expectEqualStrings("Start", g.nodes[13].label);
    // An empty label keeps the id as the label.
    try t.expectEqualStrings("N", g.nodes[14].label);
}

test "subgraph with members" {
    var g = try parse(t.allocator, "flowchart TD\nsubgraph S [Title]\n  A --> B\nend\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), g.clusters.len);
    try t.expectEqualStrings("S", g.clusters[0].raw_id);
    try t.expectEqualStrings("Title", g.clusters[0].label);
    try t.expectEqual(@as(usize, 2), g.clusters[0].members.len);
    try t.expectEqual(@as(?ClusterId, 0), g.nodes[0].cluster);
}

test "edge labels: pipe, inline, dotted and thick inline, quoted, empty pipe; bare links carry none" {
    const Case = struct { line: []const u8, kind: EdgeKind, label: ?[]const u8 };
    for ([_]Case{
        .{ .line = "A -->|yes| B", .kind = .solid, .label = "yes" },
        .{ .line = "A -- Yes --> B", .kind = .solid, .label = "Yes" },
        .{ .line = "A -. retry .-> B", .kind = .dotted, .label = "retry" },
        .{ .line = "A == go ==> B", .kind = .thick, .label = "go" },
        .{ .line = "A -->|\"pass: in range\"| B", .kind = .solid, .label = "pass: in range" },
        .{ .line = "A -->|| B", .kind = .solid, .label = "" },
        .{ .line = "A --- B", .kind = .solid, .label = null },
        .{ .line = "A -.-> B", .kind = .dotted, .label = null },
        .{ .line = "A ==> B", .kind = .thick, .label = null },
    }) |c| {
        const src = try std.mem.concat(t.allocator, u8, &.{ "flowchart TD\n", c.line, "\n" });
        defer t.allocator.free(src);
        var g = try parse(t.allocator, src);
        defer g.deinit(t.allocator);
        try t.expectEqual(@as(usize, 2), g.nodes.len);
        try t.expectEqual(@as(usize, 1), g.edges.len);
        try t.expectEqual(c.kind, g.edges[0].kind);
        if (c.label) |l| try t.expectEqualStrings(l, g.edges[0].label.?) else try t.expectEqual(@as(?[]const u8, null), g.edges[0].label);
    }
}

test "edge variants" {
    var g = try parse(t.allocator, "flowchart TD\nA --> B\nB --- C\nC -.-> D\nD ==> E\nE ~~~ F\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 5), g.edges.len);
    try t.expectEqual(EdgeKind.solid, g.edges[0].kind);
    try t.expectEqual(EdgeKind.dotted, g.edges[2].kind);
    try t.expectEqual(EdgeKind.thick, g.edges[3].kind);
    try t.expectEqual(EdgeKind.invisible, g.edges[4].kind);
}

test "double-ended circle/cross edge builds one edge, no phantom node" {
    var gc = try parse(t.allocator, "flowchart TD\nA o--o B\n");
    defer gc.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), gc.nodes.len);
    try t.expectEqual(@as(usize, 1), gc.edges.len);
    try t.expectEqual(EdgeKind.solid, gc.edges[0].kind);
    try t.expectEqual(ArrowEnd.circle, gc.edges[0].arrow_from);
    try t.expectEqual(ArrowEnd.circle, gc.edges[0].arrow_to);

    var gx = try parse(t.allocator, "flowchart TD\nA x--x B\n");
    defer gx.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), gx.nodes.len);
    try t.expectEqual(@as(usize, 1), gx.edges.len);
    try t.expectEqual(ArrowEnd.cross, gx.edges[0].arrow_from);
    try t.expectEqual(ArrowEnd.cross, gx.edges[0].arrow_to);
}

test "a style definition names no node and a class line declares the nodes it lists" {
    var g = try parse(t.allocator, "flowchart TD\nclassDef red fill:#f00,stroke:#000\nA --> B\nclass A,C red\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), g.nodes.len);
    try t.expectEqual(@as(?NodeId, null), findNode(g, "red"));
    try t.expect(findNode(g, "C") != null);
    try t.expectEqual(@as(usize, 1), g.edges.len);
    try t.expectEqual(@as(u32, 0), g.skipped_lines);
}

test "a class line without a class name declares nothing" {
    var g = try parse(t.allocator, "flowchart TD\nclass A,B\nclass C\nA --> D\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.nodes.len);
    try t.expectEqual(@as(?NodeId, null), findNode(g, "C"));
    try t.expectEqual(@as(u32, 0), g.skipped_lines);
}

test "a style definition reads to the semicolon and no further" {
    var g = try parse(t.allocator, "flowchart TD\nclassDef red fill:#f00; A --> B\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.nodes.len);
    try t.expectEqual(@as(usize, 1), g.edges.len);
}

test "a class suffix after a node is read past" {
    var g = try parse(t.allocator, "flowchart TD\nA:::warn --> B[Bee]:::ok\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.nodes.len);
    try t.expectEqual(@as(usize, 1), g.edges.len);
    try t.expectEqualStrings("Bee", g.nodes[1].label);
    try t.expectEqual(@as(u32, 0), g.skipped_lines);
}

test "multi-word and quoted label" {
    var g = try parse(t.allocator, "flowchart TD\nA[Hello world] --> B[\"q t\"]\n");
    defer g.deinit(t.allocator);
    try t.expectEqualStrings("Hello world", g.nodes[0].label);
    try t.expectEqualStrings("q t", g.nodes[1].label);
}

test "quoted label with brackets and operators is opaque" {
    var g = try parse(t.allocator, "flowchart TD\nT[\"Apply Scale[0..100] & Round()\"]\nC{\"if v > 0.5 && v < 9.5\"}\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.nodes.len);
    try t.expectEqualStrings("Apply Scale[0..100] & Round()", g.nodes[0].label);
    try t.expectEqual(NodeShape.rect, g.nodes[0].shape);
    try t.expectEqualStrings("if v > 0.5 && v < 9.5", g.nodes[1].label);
    try t.expectEqual(NodeShape.rhombus, g.nodes[1].shape);
}

test "cluster endpoints desugar to representative members" {
    var g = try parse(t.allocator,
        \\flowchart TD
        \\subgraph Source
        \\  A --> B
        \\end
        \\subgraph Target
        \\  C --> D
        \\end
        \\Source --> Target
        \\
    );
    defer g.deinit(t.allocator);

    try t.expectEqual(@as(usize, 4), g.nodes.len);
    try t.expectEqual(@as(?NodeId, null), findNode(g, "Source"));
    try t.expectEqual(@as(?NodeId, null), findNode(g, "Target"));
    try t.expectEqual(@as(usize, 3), g.edges.len);
    try t.expectEqual(findNode(g, "B").?, g.edges[2].from);
    try t.expectEqual(findNode(g, "C").?, g.edges[2].to);
}

test "ampersand both sides: cross-product with shapes and edge label" {
    var g = try parse(t.allocator, "flowchart TD\nA[Start] & B((Hub)) -->|go| C & D{End?}\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), g.nodes.len);
    try t.expectEqual(@as(usize, 4), g.edges.len);
    for (g.edges) |e| try t.expectEqualStrings("go", e.label.?);
    try t.expectEqualStrings("Start", g.nodes[findNode(g, "A").?].label);
    try t.expectEqual(NodeShape.circle, g.nodes[findNode(g, "B").?].shape);
    try t.expectEqual(NodeShape.rhombus, g.nodes[findNode(g, "D").?].shape);
}

test "ampersand chaining: targets become next hop's sources" {
    var g = try parse(t.allocator, "flowchart TD\nA --> B & C --> D\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), g.nodes.len);
    try t.expectEqual(@as(usize, 4), g.edges.len);
    try t.expectEqual(findNode(g, "D").?, g.edges[2].to);
    try t.expectEqual(findNode(g, "B").?, g.edges[2].from);
    try t.expectEqual(findNode(g, "C").?, g.edges[3].from);
}

test "skippable directives are consumed without effect" {
    var g = try parse(t.allocator,
        \\flowchart TD
        \\A --> B
        \\click A "https://example.com/x" "Open docs"
        \\style A fill:#eef
        \\linkStyle 0 stroke:#888,stroke-width:2px
        \\call callbackFn()
        \\B --> C
        \\
    );
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), g.nodes.len);
    try t.expectEqual(@as(usize, 2), g.edges.len);
    try t.expectEqual(@as(u32, 0), g.skipped_lines);
}

test "line recovery: bad non-edge line is dropped, rest renders" {
    var g = try parse(t.allocator, "flowchart TD\nA --> B\nC[x] D\nE --> F\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), g.nodes.len);
    try t.expectEqual(@as(usize, 2), g.edges.len);
    try t.expectEqual(@as(?NodeId, null), findNode(g, "C"));
    try t.expectEqual(@as(u32, 1), g.skipped_lines);
}

test "empty clusters are pruned: a node keeps its first cluster, a parent survives through a kept child, no reference dangles" {
    var g = try parse(t.allocator,
        \\flowchart TD
        \\subgraph First
        \\  L --- M
        \\end
        \\subgraph Second
        \\  L --- M
        \\end
        \\subgraph Third
        \\end
        \\subgraph Outer
        \\  subgraph Hollow
        \\  end
        \\  subgraph Inner
        \\    A --> B
        \\  end
        \\end
        \\
    );
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), g.clusters.len);
    try t.expectEqual(@as(usize, 3), g.edges.len);
    const first_id = g.nodes[findNode(g, "L").?].cluster.?;
    try t.expectEqualStrings("First", g.clusters[first_id].raw_id);
    try t.expectEqual(@as(usize, 2), g.clusters[first_id].members.len);

    const outer_id: ClusterId = for (g.clusters, 0..) |c, i| {
        if (std.mem.eql(u8, c.raw_id, "Outer")) break @intCast(i);
    } else return error.TestExpectedEqual;
    const inner_id = g.nodes[findNode(g, "A").?].cluster.?;
    try t.expectEqualStrings("Inner", g.clusters[inner_id].raw_id);
    try t.expectEqual(@as(usize, 0), g.clusters[outer_id].members.len);
    try t.expectEqualSlices(ClusterId, &.{inner_id}, g.clusters[outer_id].sub_clusters);
    try t.expectEqual(@as(?ClusterId, outer_id), g.clusters[inner_id].parent);

    for (g.nodes, 0..) |node, nid| {
        const c = node.cluster orelse continue;
        var found = false;
        for (g.clusters[c].members) |m| {
            if (m == @as(NodeId, @intCast(nid))) {
                found = true;
                break;
            }
        }
        try t.expect(found);
    }
}

test "cluster id node declarations still create ordinary nodes" {
    var g = try parse(t.allocator,
        \\flowchart TD
        \\subgraph S
        \\  A
        \\end
        \\S[Standalone]
        \\
    );
    defer g.deinit(t.allocator);

    const sid = findNode(g, "S") orelse return error.TestExpectedEqual;
    try t.expectEqual(@as(usize, 2), g.nodes.len);
    try t.expectEqualStrings("Standalone", g.nodes[sid].label);
    try t.expectEqual(@as(?ClusterId, null), g.nodes[sid].cluster);
}

test "a subgraph endpoint is read against the edges of its own line" {
    var g = try parse(t.allocator,
        \\graph TD
        \\subgraph S
        \\a
        \\b
        \\end
        \\b --> a --> S
        \\
    );
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.edges.len);
    try t.expectEqual(findNode(g, "a").?, g.edges[1].from);
    try t.expectEqual(findNode(g, "b").?, g.edges[1].to);
}

test "a skipped line leaves no link behind for a later subgraph endpoint" {
    var g = try parse(t.allocator,
        \\graph TD
        \\subgraph S
        \\a
        \\b
        \\b[x;style] --> a c
        \\end
        \\z --> S
        \\
    );
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(u32, 1), g.skipped_lines);
    try t.expectEqual(@as(usize, 1), g.edges.len);
    try t.expectEqual(findNode(g, "a").?, g.edges[0].to);
}

test "a subgraph endpoint stands for a member of a subgraph nested in it" {
    var g = try parse(t.allocator,
        \\graph TD
        \\subgraph Outer
        \\subgraph Inner
        \\x
        \\end
        \\end
        \\Outer --> y
        \\
    );
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), g.edges.len);
    try t.expectEqual(findNode(g, "x").?, g.edges[0].from);
}

test "a subgraph with no node yet is not an endpoint" {
    try t.expectError(error.InvalidNode, parse(t.allocator, "graph TD\nsubgraph S\nend\nS --> a\n"));
    var g = try parse(t.allocator, "graph TD\nsubgraph S\nend\nS & a\nb --> c\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(u32, 1), g.skipped_lines);
    try t.expectEqual(@as(usize, 1), g.edges.len);
}

test "parse errors: a bad edge line, a failing line with a link operator, an unterminated subgraph, a bad direction" {
    const Case = struct { src: []const u8, err: anyerror };
    for ([_]Case{
        .{ .src = "flowchart TD\nX --> Y\nA --> --> B\n", .err = error.InvalidNode },
        .{ .src = "graph TD\nA --> B C\n", .err = error.UnexpectedToken },
        .{ .src = "graph TD\nsubgraph S\nA --> B\n", .err = error.UnterminatedSubgraph },
        .{ .src = "graph XY\nA --> B\n", .err = error.InvalidDirection },
    }) |c| try t.expectError(c.err, parse(t.allocator, c.src));
}

test "a stray end outside any subgraph is ignored" {
    var g = try parse(t.allocator, "graph TD\nend\nA --> B\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), g.edges.len);
}

test "a direction line sets the direction of the open subgraph only" {
    var g = try parse(t.allocator, "graph TD\ndirection LR\nsubgraph S\ndirection BT\nA --> B\nend\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(Direction.TD, g.direction);
    try t.expectEqual(@as(?Direction, .BT), g.clusters[0].direction);
}

test "line breaks in labels become label line breaks" {
    var g = try parse(t.allocator, "graph TD\nA[one<br>two] -->|x<br/>y| B\nsubgraph S [top\\nbottom]\nC\nend\n");
    defer g.deinit(t.allocator);
    try t.expectEqualStrings("one\ntwo", g.nodes[0].label);
    try t.expectEqualStrings("x\ny", g.edges[0].label.?);
    try t.expectEqualStrings("top\nbottom", g.clusters[0].label);
}

test "nesting depth is bounded only by memory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const depth = 100_000;
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "graph TD\n");
    for (0..depth) |_| try src.appendSlice(a, "subgraph s\n");
    try src.appendSlice(a, "a --> b\n");
    for (0..depth) |_| try src.appendSlice(a, "end\n");
    var g = try parse(t.allocator, src.items);
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, depth), g.clusters.len);
    try t.expectEqual(@as(?ClusterId, depth - 1), g.nodes[1].cluster);
}

test "a repeated subgraph id is the endpoint of the latest subgraph" {
    var g = try parse(t.allocator, "graph TD\nsubgraph S\na\nend\nsubgraph S\nb\nend\nS --> x\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), g.edges.len);
    try t.expectEqual(findNode(g, "b").?, g.edges[0].from);
}
