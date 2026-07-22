//! Tests for parse.zig. Split out of parse.zig to keep the parser under
//! the 500-line cap. Discovered by parse.zig via a `test { _ = @import }`.

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

test "empty graph" {
    var g = try parse(t.allocator, "flowchart TD\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(Direction.TD, g.direction);
    try t.expectEqual(@as(usize, 0), g.nodeCount());
    try t.expectEqual(@as(usize, 0), g.edgeCount());
}

test "TB normalises to TD" {
    var g = try parse(t.allocator, "graph TB\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(Direction.TD, g.direction);
}

test "single edge implicit nodes" {
    var g = try parse(t.allocator, "flowchart TD\nA --> B\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.nodeCount());
    try t.expectEqual(@as(usize, 1), g.edgeCount());
    try t.expectEqual(EdgeKind.solid, g.edges[0].kind);
    try t.expectEqual(ArrowEnd.open, g.edges[0].arrow_to);
    try t.expectEqual(ArrowEnd.none, g.edges[0].arrow_from);
}

test "all shapes" {
    const src = "flowchart LR\nA[rect]\nB(round)\nC((circle))\nD[[sub]]\nE[(cyl)]\nF([stad])\nG{rhom}\nH{{hex}}\nI>asym]\nJ[/par/]\nK[\\paralt\\]\nL[/trap\\]\nM[\\trapalt/]\n";
    var g = try parse(t.allocator, src);
    defer g.deinit(t.allocator);
    const want = [_]NodeShape{ .rect, .round, .circle, .subroutine, .cylinder, .stadium, .rhombus, .hexagon, .asymmetric_right, .parallelogram, .parallelogram_alt, .trapezoid, .trapezoid_alt };
    try t.expectEqual(want.len, g.nodeCount());
    for (want, 0..) |w, i| try t.expectEqual(w, g.nodes[i].shape);
    try t.expectEqualStrings("rect", g.nodes[0].label);
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

test "edge label" {
    var g = try parse(t.allocator, "flowchart TD\nA -->|yes| B\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), g.edgeCount());
    try t.expectEqualStrings("yes", g.edges[0].label.?);
}

test "edge variants" {
    var g = try parse(t.allocator, "flowchart TD\nA --> B\nB --- C\nC -.-> D\nD ==> E\nE ~~~ F\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 5), g.edgeCount());
    try t.expectEqual(EdgeKind.solid, g.edges[0].kind);
    try t.expectEqual(EdgeKind.dotted, g.edges[2].kind);
    try t.expectEqual(EdgeKind.thick, g.edges[3].kind);
    try t.expectEqual(EdgeKind.invisible, g.edges[4].kind);
}

test "double-ended circle/cross edge builds one edge, no phantom node" {
    // `o--o` / `x--x` must parse (not fall back to raw source): two nodes, one
    // edge with both end markers decoded. No spurious "o"/"x" node.
    var gc = try parse(t.allocator, "flowchart TD\nA o--o B\n");
    defer gc.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), gc.nodeCount());
    try t.expectEqual(@as(usize, 1), gc.edgeCount());
    try t.expectEqual(EdgeKind.solid, gc.edges[0].kind);
    try t.expectEqual(ArrowEnd.circle, gc.edges[0].arrow_from);
    try t.expectEqual(ArrowEnd.circle, gc.edges[0].arrow_to);

    var gx = try parse(t.allocator, "flowchart TD\nA x--x B\n");
    defer gx.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), gx.nodeCount());
    try t.expectEqual(@as(usize, 1), gx.edgeCount());
    try t.expectEqual(ArrowEnd.cross, gx.edges[0].arrow_from);
    try t.expectEqual(ArrowEnd.cross, gx.edges[0].arrow_to);
}

test "classDef and class assignment" {
    var g = try parse(t.allocator, "flowchart TD\nclassDef red fill:#f00,stroke:#000\nA --> B\nclass A,B red\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), g.classes.len);
    try t.expectEqualStrings("red", g.classes[0].name);
    try t.expectEqual(@as(usize, 1), g.nodes[0].classes.len);
}

test "inline class via :::" {
    var g = try parse(t.allocator, "flowchart TD\nA:::warn --> B\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), g.nodes[0].classes.len);
}

test "chained edges" {
    var g = try parse(t.allocator, "flowchart TD\nA --> B --> C\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), g.nodeCount());
    try t.expectEqual(@as(usize, 2), g.edgeCount());
}

test "multi-word and quoted label" {
    var g = try parse(t.allocator, "flowchart TD\nA[Hello world] --> B[\"q t\"]\n");
    defer g.deinit(t.allocator);
    try t.expectEqualStrings("Hello world", g.nodes[0].label);
    try t.expectEqualStrings("q t", g.nodes[1].label);
}

test "inline-label edge form `-- text -->`" {
    var g = try parse(t.allocator, "flowchart TD\nA -- Yes --> B\n");
    defer g.deinit(t.allocator);
    // The label is on the edge; it does NOT become its own node.
    try t.expectEqual(@as(usize, 2), g.nodeCount());
    try t.expectEqual(@as(usize, 1), g.edgeCount());
    try t.expectEqualStrings("Yes", g.edges[0].label.?);
    try t.expectEqual(EdgeKind.solid, g.edges[0].kind);
}

test "inline-label edge keeps bare links intact" {
    // `A --- B` is a bare link, not an inline-label edge: must not be eaten
    // by the inline-label scanner.
    var g = try parse(t.allocator, "flowchart TD\nA --- B\nC -.-> D\nE ==> F\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), g.edgeCount());
    try t.expectEqual(@as(?[]const u8, null), g.edges[0].label);
    try t.expectEqual(EdgeKind.solid, g.edges[0].kind);
}

test "inline-label edge: dotted and thick carry labels" {
    var g = try parse(t.allocator, "flowchart TD\nA -. retry .-> B\nB == go ==> C\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.edgeCount());
    try t.expectEqualStrings("retry", g.edges[0].label.?);
    try t.expectEqual(EdgeKind.dotted, g.edges[0].kind);
    try t.expectEqualStrings("go", g.edges[1].label.?);
    try t.expectEqual(EdgeKind.thick, g.edges[1].kind);
}

test "quoted label with brackets and operators is opaque" {
    // Brackets/operators/quotes inside a `"..."` span are literal label
    // text and must not terminate the shape early.
    var g = try parse(t.allocator,
        "flowchart TD\nT[\"Apply Scale[0..100] & Round()\"]\nC{\"if v > 0.5 && v < 9.5\"}\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.nodeCount());
    try t.expectEqualStrings("Apply Scale[0..100] & Round()", g.nodes[0].label);
    try t.expectEqual(NodeShape.rect, g.nodes[0].shape);
    try t.expectEqualStrings("if v > 0.5 && v < 9.5", g.nodes[1].label);
    try t.expectEqual(NodeShape.rhombus, g.nodes[1].shape);
}

test "quoted edge label with special chars" {
    var g = try parse(t.allocator, "flowchart TD\nA -->|\"pass: in range\"| B\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), g.edgeCount());
    try t.expectEqualStrings("pass: in range", g.edges[0].label.?);
}

test "stadium shape `([...])`" {
    var g = try parse(t.allocator, "flowchart TD\nA([Access Denied])\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), g.nodeCount());
    try t.expectEqual(NodeShape.stadium, g.nodes[0].shape);
    try t.expectEqualStrings("Access Denied", g.nodes[0].label);
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

    try t.expectEqual(@as(usize, 4), g.nodeCount());
    try t.expectEqual(@as(?NodeId, null), g.findNode("Source"));
    try t.expectEqual(@as(?NodeId, null), g.findNode("Target"));
    try t.expectEqual(@as(usize, 3), g.edgeCount());
    try t.expectEqual(g.findNode("B").?, g.edges[2].from);
    try t.expectEqual(g.findNode("C").?, g.edges[2].to);
}

test "ampersand fan-out: targets" {
    var g = try parse(t.allocator, "flowchart TD\nLB --> Web1 & Web2 & Web3\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), g.nodeCount());
    try t.expectEqual(@as(usize, 3), g.edgeCount());
    for (g.edges) |e| try t.expectEqual(g.findNode("LB").?, e.from);
    try t.expectEqual(g.findNode("Web3").?, g.edges[2].to);
}

test "ampersand fan-in: sources" {
    var g = try parse(t.allocator, "flowchart TD\nD & E & F --> G\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), g.nodeCount());
    try t.expectEqual(@as(usize, 3), g.edgeCount());
    for (g.edges) |e| try t.expectEqual(g.findNode("G").?, e.to);
    try t.expectEqual(g.findNode("D").?, g.edges[0].from);
}

test "ampersand both sides: cross-product with shapes and edge label" {
    var g = try parse(t.allocator, "flowchart TD\nA[Start] & B((Hub)) -->|go| C & D{End?}\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), g.nodeCount());
    // 2 sources x 2 targets = 4 edges, each carrying the label.
    try t.expectEqual(@as(usize, 4), g.edgeCount());
    for (g.edges) |e| try t.expectEqualStrings("go", e.label.?);
    try t.expectEqualStrings("Start", g.nodes[g.findNode("A").?].label);
    try t.expectEqual(NodeShape.circle, g.nodes[g.findNode("B").?].shape);
    try t.expectEqual(NodeShape.rhombus, g.nodes[g.findNode("D").?].shape);
}

test "ampersand chaining: targets become next hop's sources" {
    var g = try parse(t.allocator, "flowchart TD\nA --> B & C --> D\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), g.nodeCount());
    // A->B, A->C, B->D, C->D.
    try t.expectEqual(@as(usize, 4), g.edgeCount());
    try t.expectEqual(g.findNode("D").?, g.edges[2].to);
    try t.expectEqual(g.findNode("B").?, g.edges[2].from);
    try t.expectEqual(g.findNode("C").?, g.edges[3].from);
}

test "double-circle shape `(((...)))`" {
    var g = try parse(t.allocator, "flowchart TD\nS(((Start))) --> E(((Finished)))\n");
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.nodeCount());
    try t.expectEqual(NodeShape.double_circle, g.nodes[0].shape);
    try t.expectEqualStrings("Start", g.nodes[0].label);
    try t.expectEqual(NodeShape.double_circle, g.nodes[1].shape);
    try t.expectEqualStrings("Finished", g.nodes[1].label);
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
    try t.expectEqual(@as(usize, 3), g.nodeCount());
    try t.expectEqual(@as(usize, 2), g.edgeCount());
    // Recognized directives are not "skipped lines" — no warning owed.
    try t.expectEqual(@as(u32, 0), g.skipped_lines);
}

test "line recovery: bad non-edge line is dropped, rest renders" {
    var g = try parse(t.allocator, "flowchart TD\nA --> B\nC[x] D\nE --> F\n");
    defer g.deinit(t.allocator);
    // The `C[x] D` line fails at the stray `D` and is rolled back whole:
    // neither C nor its shape survives.
    try t.expectEqual(@as(usize, 4), g.nodeCount());
    try t.expectEqual(@as(usize, 2), g.edgeCount());
    try t.expectEqual(@as(?NodeId, null), g.findNode("C"));
    try t.expectEqual(@as(u32, 1), g.skipped_lines);
}

test "line recovery: bad EDGE line still fails the whole parse" {
    // `A --> --> B` is unparseable AND edge-bearing: semantic loss is
    // worse than no render, so the error must propagate.
    try t.expectError(error.InvalidNode, parse(t.allocator, "flowchart TD\nX --> Y\nA --> --> B\n"));
}

test "empty clusters are pruned (node keeps its first cluster)" {
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
        \\
    );
    defer g.deinit(t.allocator);
    // Second/Third own no nodes; they must not survive as empty clusters
    // (layout rejects an empty child graph).
    try t.expectEqual(@as(usize, 1), g.clusters.len);
    try t.expectEqualStrings("First", g.clusters[0].raw_id);
    try t.expectEqual(@as(usize, 2), g.clusters[0].members.len);
    try t.expectEqual(@as(usize, 2), g.edgeCount());
}

test "nested subgraph: parent survives via kept child with no own members" {
    // Outer has no direct statements of its own — every node lives in the
    // nested Inner subgraph. builder_types.zig's pruneEmptyClusters keeps
    // Outer anyway because it has a kept sub-cluster, and remaps Outer's
    // (still valid) id into Inner.parent unconditionally.
    var g = try parse(t.allocator,
        \\flowchart TD
        \\subgraph Outer
        \\  subgraph Inner
        \\    A --> B
        \\  end
        \\end
        \\
    );
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.clusters.len);
    const outer_id: ClusterId = for (g.clusters, 0..) |c, i| {
        if (std.mem.eql(u8, c.raw_id, "Outer")) break @intCast(i);
    } else return error.TestExpectedEqual;
    const inner_id: ClusterId = for (g.clusters, 0..) |c, i| {
        if (std.mem.eql(u8, c.raw_id, "Inner")) break @intCast(i);
    } else return error.TestExpectedEqual;
    try t.expectEqual(@as(usize, 0), g.clusters[outer_id].members.len);
    try t.expectEqual(@as(usize, 1), g.clusters[outer_id].sub_clusters.len);
    try t.expectEqual(@as(?ClusterId, outer_id), g.clusters[inner_id].parent);
}

test "dropped empty cluster leaves no dangling node->cluster reference" {
    // "Second" is empty and gets pruned entirely; First and Third survive
    // and shift id-space around the gap Second leaves behind. Every node
    // that still names a cluster must find itself in that cluster's member
    // list post-prune — dropped clusters (zero members, by construction)
    // can never be the dangling target of a node.cluster remap.
    var g = try parse(t.allocator,
        \\flowchart TD
        \\subgraph First
        \\  L --- M
        \\end
        \\subgraph Second
        \\end
        \\subgraph Third
        \\  X --- Y
        \\end
        \\
    );
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), g.clusters.len);
    const first_id = g.nodes[g.findNode("L").?].cluster.?;
    const third_id = g.nodes[g.findNode("X").?].cluster.?;
    try t.expectEqualStrings("First", g.clusters[first_id].raw_id);
    try t.expectEqualStrings("Third", g.clusters[third_id].raw_id);
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

    const sid = g.findNode("S") orelse return error.TestExpectedEqual;
    try t.expectEqual(@as(usize, 2), g.nodeCount());
    try t.expectEqualStrings("Standalone", g.nodes[sid].label);
    try t.expectEqual(@as(?ClusterId, null), g.nodes[sid].cluster);
}
