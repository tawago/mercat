const std = @import("std");
const parse = @import("../parse.zig").parse;
const permits = @import("../ledger/permits.zig");
const realized = @import("../ledger/realized.zig");
const select = @import("../select.zig");

fn expectSelectedEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want.permission_group, got.permission_group);
        try std.testing.expectEqualSlices(u32, want.members, got.members);
    }
}

fn nodeId(graph: anytype, raw: []const u8) u32 {
    for (graph.nodes) |n| if (std.mem.eql(u8, n.raw_id, raw)) return n.id;
    unreachable;
}

fn rawOf(graph: anytype, id: u32) []const u8 {
    for (graph.nodes) |n| if (n.id == id) return n.raw_id;
    unreachable;
}

/// The identity keys ("from->to" node raw_ids, in committed member order) of
/// the fan-IN trunk at node `D`, or empty when there is no such trunk.
fn trunkKeysAtD(a: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    const graph = try parse(a, source);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, true, 94, false, false);
    for (winner.sketch.joins.selected_joins) |sj| {
        for (plan.groups) |g| if (g.id == sj.permission_group and g.direction == .in and g.pivot == nodeId(graph, "D")) {
            const out = try a.alloc([]const u8, sj.members.len);
            for (sj.members, out) |m, *slot| {
                for (graph.edges) |e| if (e.id == m) {
                    slot.* = try std.fmt.allocPrint(a, "{s}->{s}", .{ rawOf(graph, e.from), rawOf(graph, e.to) });
                };
            }
            return out;
        };
    }
    return &.{};
}

// Owner ruling 2026-07-18: a fan-IN group blocked ONLY by a layout-reversed
// member composes its forward subset as one merged trunk (>=2 forward
// members); the reversed member takes an independent side entry. These pin
// that join_commit and realized.realize agree on the subset (N6 exact).
const reversed_fanin_source =
    "flowchart TD\n  A --> B\n  A --> C\n  B --> D\n  C --> D\n  D --> E\n  E --> F\n  F --> D\n";

test "N6 reversed: forward-subset fan-in trunk agrees across join_commit and realized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, reversed_fanin_source);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const set = try select.enumerateAll(a, graph, &plan, true, 94);
    var saw_fanin = false;
    for (set.merged) |candidate| {
        const checked = try realized.realize(a, plan, candidate.sketch, candidate.sketch.joins.mesh_unions);
        try expectSelectedEqual(candidate.sketch.joins.selected_joins, checked.plan.selected_joins);
        for (candidate.sketch.joins.selected_joins) |sj| {
            for (plan.groups) |g| if (g.id == sj.permission_group and g.direction == .in and g.pivot == nodeId(graph, "D")) {
                saw_fanin = true;
                try std.testing.expectEqual(@as(usize, 2), sj.members.len); // forward subset only
            };
        }
    }
    try std.testing.expect(saw_fanin);
}

test "N6 floor: a single-forward-member reversed fan-in commits no trunk" {
    // H has one forward arrival G->H and a back-edge J->H (cycle H->I->J->H):
    // forward subset {G->H} is one member, below the >=2 floor → no trunk.
    const source = "flowchart TD\n  A --> G\n  G --> H\n  H --> I\n  I --> J\n  J --> H\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, source);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const set = try select.enumerateAll(a, graph, &plan, true, 94);
    for (set.merged) |candidate| {
        const checked = try realized.realize(a, plan, candidate.sketch, candidate.sketch.joins.mesh_unions);
        try expectSelectedEqual(candidate.sketch.joins.selected_joins, checked.plan.selected_joins);
        for (candidate.sketch.joins.selected_joins) |sj| {
            for (plan.groups) |g| if (g.id == sj.permission_group)
                try std.testing.expect(!(g.direction == .in and g.pivot == nodeId(graph, "H")));
        }
    }
}

test "forward-subset selection is deterministic under arrival declaration permutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The two forward arrivals (and their sources) declared in swapped order.
    const swapped = "flowchart TD\n  A --> C\n  A --> B\n  C --> D\n  B --> D\n  D --> E\n  E --> F\n  F --> D\n";
    const k1 = try trunkKeysAtD(a, reversed_fanin_source);
    const k2 = try trunkKeysAtD(a, swapped);
    try std.testing.expectEqual(@as(usize, 2), k1.len);
    try std.testing.expectEqual(k1.len, k2.len);
    for (k1, k2) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "N6: every enumerated candidate agrees on pre-sizing trunk commitments and realized selected joins" {
    const sources = [_][]const u8{
        "flowchart TD\n  S --> A\n  S --> B\n  S --> C\n",
        "flowchart TD\n  A --> T\n  B --> T\n  C --> T\n",
        "flowchart LR\n  SourceWithLongLabel --> A\n  SourceWithLongLabel --> B\n  SourceWithLongLabel --> C\n",
        "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n",
        "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T1\n  S2 --> T2\n",
    };
    for (sources, 0..) |source, source_i| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try parse(a, source);
        const plan = (try permits.build(a, graph, .joined)).plan;
        const set = try select.enumerateAll(a, graph, &plan, true, if (source_i == 2) 24 else 94);
        var saw_switch = false;
        for (set.merged) |candidate| {
            if (candidate.rung == .switch_direction) saw_switch = true;
            const checked = try realized.realize(a, plan, candidate.sketch, candidate.sketch.joins.mesh_unions);
            try expectSelectedEqual(candidate.sketch.joins.selected_joins, checked.plan.selected_joins);
        }
        if (source_i == 2) try std.testing.expect(saw_switch);
    }
}
