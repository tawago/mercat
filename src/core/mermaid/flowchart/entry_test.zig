const std = @import("std");
const ledger = @import("base/ledger.zig");
const ladder = @import("budget.zig");
const entry = @import("entry.zig");
const select = @import("select.zig");
const parse = @import("parse.zig").parse;
const sem_graph = @import("sem_graph.zig");

test "V-D-IR-07: a clustered graph's bundles ride piece plans; the root plan stays skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\subgraph S
        \\  A --> B
        \\end
        \\B --> C
        \\
    );

    const result = try select.resolvePermits(a, graph);
    try std.testing.expectEqual(ledger.BundlePolicy.joined, result.plan.policy);
    try std.testing.expect(result.report.bundle_permits_skipped_clustered);
    const laid_out = try ladder.runForced(a, graph, &result.plan, 120, .natural);
    try std.testing.expectEqual(@as(usize, 0), laid_out.sketch.sharing.realized.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 2), laid_out.sketch.sharing.realized.memberships.len);
    const bridge_row = laid_out.sketch.sharing.realized.memberships[1];
    try std.testing.expect(bridge_row.source == null and bridge_row.target == null);

    // A flat graph's root plan is not skipped and holds its one fan group.
    const flat = try select.resolvePermits(a, try parse(a, "flowchart TD\nA --> B\nA --> C\n"));
    try std.testing.expectEqual(ledger.BundlePolicy.joined, flat.plan.policy);
    try std.testing.expect(!flat.report.bundle_permits_skipped_clustered);
    try std.testing.expectEqual(@as(usize, 1), flat.plan.groups.len);
}

test "cluster unification: a subgraph-internal fan-in realizes a rail and ships it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\subgraph S
        \\  A --> C
        \\  B --> C
        \\end
        \\
    );

    const result = try select.resolvePermits(a, graph);
    const laid_out = try ladder.runForced(a, graph, &result.plan, 80, .natural);
    try std.testing.expectEqual(@as(usize, 1), laid_out.sketch.sharing.realized.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 2), laid_out.sketch.sharing.realized.selected_bundles[0].members.len);

    // The shipped frame draws both members into one rail tee (└──┬──┘ alone on its row) and one head into C.
    const rendered = try entry.renderFlowchart(std.testing.allocator, "flowchart TD\nsubgraph S\n  A --> C\n  B --> C\nend\n", .{ .max_width = 80 });
    defer std.testing.allocator.free(rendered.output);
    try std.testing.expect(!rendered.is_fallback);
    for ([_][]const u8{ "─ S ─", "│ A │", "│ B │", "│ C │" }) |want| try std.testing.expect(std.mem.indexOf(u8, rendered.output, want) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered.output, "▼"));
    var tee_rows: usize = 0;
    var lines = std.mem.splitScalar(u8, rendered.output, '\n');
    while (lines.next()) |line| {
        if (std.mem.count(u8, line, "┬") != 1 or std.mem.count(u8, line, "└") != 1) continue;
        const l = std.mem.indexOf(u8, line, "└") orelse continue;
        const t = std.mem.indexOfPos(u8, line, l, "┬") orelse continue;
        const r = std.mem.indexOfPos(u8, line, t, "┘") orelse continue;
        for ([_][]const u8{ line[l + "└".len .. t], line[t + "┬".len .. r] }) |run| {
            try std.testing.expect(run.len > 0 and std.mem.count(u8, run, "─") * "─".len == run.len);
        }
        tee_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), tee_rows);
}

test "cluster unification: two subgraph rails keep their own members through nonzero stitch bases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\subgraph S
        \\  A --> C
        \\  B --> C
        \\end
        \\subgraph T
        \\  D --> F
        \\  E --> F
        \\end
        \\
    );

    const result = try select.resolvePermits(a, graph);
    const laid_out = try ladder.runForced(a, graph, &result.plan, 80, .natural);
    const bundles = laid_out.sketch.sharing.realized.selected_bundles;
    try std.testing.expectEqual(@as(usize, 2), bundles.len);
    try std.testing.expectEqual(@as(usize, 2), laid_out.sketch.rails.len);
    for (bundles) |j| {
        try std.testing.expectEqual(@as(usize, 2), j.members.len);
        var matched = false;
        for (laid_out.sketch.rails) |rail| {
            if (rail.taps.len != 2) continue;
            const fwd = (rail.taps[0].edge == j.members[0] and rail.taps[1].edge == j.members[1]);
            const rev = (rail.taps[0].edge == j.members[1] and rail.taps[1].edge == j.members[0]);
            if (fwd or rev) matched = true;
        }
        try std.testing.expect(matched);
    }
    try std.testing.expect(bundles[0].members[0] != bundles[1].members[0]);
    try std.testing.expect(bundles[0].members[1] != bundles[1].members[1]);
}

fn rawId(graph: entry.sem_graph.SemGraph, id: entry.NodeId) []const u8 {
    for (graph.nodes) |n| if (n.id == id) return n.raw_id;
    return "?";
}

test "declared identity: a clustered self-loop is named by its declared ends, not its stitched node ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\A --> X
        \\subgraph S
        \\  P --> Q
        \\  Q --> Q
        \\end
        \\X --> P
        \\A --> C
        \\A --> D
        \\
    );
    const result = try select.resolvePermits(a, graph);
    const chosen = try select.choose(a, graph, &result.plan, 120, .bridge);

    var loops: usize = 0;
    for (chosen.cand.sketch.edges) |e| {
        const declared = graph.edgeById(e.origin) orelse return error.UndeclaredOrigin;
        if (e.from != e.to) continue;
        loops += 1;
        try std.testing.expectEqualStrings("Q", rawId(graph, declared.from));
        try std.testing.expectEqualStrings("Q", rawId(graph, declared.to));
        try std.testing.expect(!std.mem.eql(u8, "Q", rawId(graph, e.from)));
    }
    try std.testing.expectEqual(@as(usize, 1), loops);
    for (chosen.cand.sketch.rails) |rail| for (rail.taps) |tap| {
        _ = graph.edgeById(tap.origin) orelse return error.UndeclaredOrigin;
    };
}

test "omission report: an omitted label is warned once, by its declared edge and ends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\  A -->|left-source-label| T
        \\  B -->|middle-source-label| T
        \\  C -->|right-source-label| T
        \\
    );
    const result = try select.resolvePermits(a, graph);
    const chosen = try select.choose(a, graph, &result.plan, 120, .bridge);

    var out: std.Io.Writer.Allocating = .init(a);
    try entry.writeOmissions(&out.writer, graph, chosen.cand.sketch, chosen.report.label_plan);
    try std.testing.expectEqualStrings(
        "mermaid: label \"middle-source-label\" on edge 1 (B -> T) has no room and is not drawn\n",
        out.written(),
    );
}

fn chooseAt(a: std.mem.Allocator, source: []const u8, width: u32) !select.Chosen {
    const graph = try parse(a, source);
    const permits = try select.resolvePermits(a, graph);
    const plan = try a.create(ledger.BundlePermits);
    plan.* = permits.plan;
    return select.choose(a, graph, plan, width, .bridge);
}

test "label room: a TD labelled edge between adjacent layers stays TD and holds its label on its own run, above the head" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "flowchart TD\n  A -->|carry| B\n";
    const chosen = try chooseAt(a, source, 60);
    try std.testing.expectEqual(sem_graph.Direction.TD, chosen.cand.sketch.direction);
    try std.testing.expectEqual(@as(u32, 0), chosen.report.label_plan.dropped());
    const out = (try entry.render(a, source, .{ .max_width = 60 })).output;
    var rows: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |row| try rows.append(a, row);
    var at: usize = 0;
    while (std.mem.indexOf(u8, rows.items[at], "carry") == null) at += 1;
    try std.testing.expectEqual(@as(usize, 0), std.mem.indexOf(u8, rows.items[at], "carry").?);
    const col = std.mem.indexOf(u8, rows.items[at - 1], "│").?;
    try std.testing.expectEqual(col, std.mem.indexOf(u8, rows.items[at + 1], "│").?);
    try std.testing.expectEqual(col, std.mem.indexOf(u8, rows.items[at + 2], "▼").?);
    try std.testing.expect(std.mem.indexOf(u8, rows.items[at - 2], "┬") != null);
}

test "label room: an LR labelled edge between adjacent layers holds its label inline on its run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const chosen = try chooseAt(a, "flowchart LR\n  A -->|carry| B\n", 60);
    try std.testing.expectEqual(sem_graph.Direction.LR, chosen.cand.sketch.direction);
    try std.testing.expectEqual(@as(u32, 0), chosen.report.label_plan.dropped());
    const out = (try entry.render(a, "flowchart LR\n  A -->|carry| B\n", .{ .max_width = 60 })).output;
    try std.testing.expect(std.mem.indexOf(u8, out, "├─carry─▶") != null);
}

test "label room: a labelled chain keeps every label in its declared direction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lr = "graph LR\n  A -->|solid| B -.->|dotted| C ==>|thick| D\n";
    const chosen = try chooseAt(a, lr, 90);
    try std.testing.expectEqual(sem_graph.Direction.LR, chosen.cand.sketch.direction);
    try std.testing.expectEqual(@as(u32, 0), chosen.report.label_plan.dropped());
    const out = (try entry.render(a, lr, .{ .max_width = 90 })).output;
    for ([_][]const u8{ "─solid─▶", "╌dotted╌▶", "═thick═▶" }) |run| try std.testing.expect(std.mem.indexOf(u8, out, run) != null);
    const td = "graph TD\n  A[Start] -->|solid| B[Mid]\n  B -.->|dotted| C[Next]\n  C ==>|thick| D[End]\n";
    for ([_]u32{ 60, 120 }) |w| {
        const c = try chooseAt(a, td, w);
        try std.testing.expectEqual(sem_graph.Direction.TD, c.cand.sketch.direction);
        try std.testing.expectEqual(@as(u32, 0), c.report.label_plan.dropped());
    }
}

test "label room: a merged arrival claims no room on the shared trunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "flowchart LR\n  A -->|ab| B\n  C -->|cd| B\n";
    const chosen = try chooseAt(a, source, 120);
    try std.testing.expectEqual(@as(u32, 0), chosen.report.label_plan.dropped());
    const out = (try entry.render(a, source, .{ .max_width = 120 })).output;
    try std.testing.expect(std.mem.indexOf(u8, out, "┴─▶") != null);
}
