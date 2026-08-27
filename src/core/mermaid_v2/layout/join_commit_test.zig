const std = @import("std");
const parse = @import("../parse.zig").parse;
const permits = @import("../ledger/permits.zig");
const realized = @import("../ledger/realized.zig");
const select = @import("../select.zig");
const join_commit = @import("join_commit.zig");
const pb = @import("../base/ledger.zig");

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
    const winner = try select.choose(a, graph, &plan, 94, false, false);
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
    const set = try select.enumerateAll(a, graph, &plan, 94);
    var saw_fanin = false;
    for (set.merged) |candidate| {
        const checked = try realized.realize(a, plan, candidate.sketch);
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
    const set = try select.enumerateAll(a, graph, &plan, 94);
    for (set.merged) |candidate| {
        const checked = try realized.realize(a, plan, candidate.sketch);
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
        "flowchart TD\n  S --> A\n  S --> B\n  S -.-> C\n",
    };
    for (sources, 0..) |source, source_i| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try parse(a, source);
        const plan = (try permits.build(a, graph, .joined)).plan;
        const set = try select.enumerateAll(a, graph, &plan, if (source_i == 2) 24 else 94);
        var saw_switch = false;
        for (set.merged) |candidate| {
            if (candidate.rung == .switch_direction) saw_switch = true;
            const checked = try realized.realize(a, plan, candidate.sketch);
            try expectSelectedEqual(candidate.sketch.joins.selected_joins, checked.plan.selected_joins);
        }
        if (source_i == 2) try std.testing.expect(saw_switch);
    }
}

// ===================================================================
// The all-arrow-free shared-rail closure law (base/rail_closure.zig)
// ===================================================================

fn edgeIdOf(graph: anytype, from: []const u8, to: []const u8) u32 {
    const f = nodeId(graph, from);
    const t = nodeId(graph, to);
    for (graph.edges) |e| if (e.from == f and e.to == t) return e.id;
    unreachable;
}

fn targetOf(joins: anytype, edge: u32) ?@TypeOf(joins.memberships[0].target) {
    for (joins.memberships) |m| if (m.edge == edge) return m.target;
    return null;
}

test "an all-arrow-free fan with undeclared leaf pairs commits no trunk" {
    // A---Z, B---Z, C---Z: the crossbar would assert A—B, A—C and B—C, none
    // declared. Refusal is expressed as independent dispositions — the same
    // record a decoration-mixed rail gets — so the members unfuse.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    var report: join_commit.Report = .{};
    const joins = try join_commit.buildReported(a, graph, &plan, &.{}, false, &report);

    try std.testing.expectEqual(@as(usize, 0), joins.selected_joins.len);
    try std.testing.expectEqual(@as(usize, 0), joins.co_realized.len);
    try std.testing.expectEqual(@as(u32, 1), report.rail_closure_undeclared);
    try std.testing.expectEqual(@as(u32, 3), report.co_undeclared);
    for ([_][]const u8{ "A", "B", "C" }) |leaf| {
        const t = targetOf(joins, edgeIdOf(graph, leaf, "Z")).?;
        try std.testing.expect(t.? == .independent);
    }
}

test "a directed fan is untouched by the closure law" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --> Z\n  B --> Z\n  C --> Z\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    var report: join_commit.Report = .{};
    const joins = try join_commit.buildReported(a, graph, &plan, &.{}, false, &report);

    try std.testing.expectEqual(@as(usize, 1), joins.selected_joins.len);
    try std.testing.expectEqual(@as(u32, 0), report.rail_closure_undeclared);
    try std.testing.expectEqual(@as(u32, 0), report.co_undeclared);
}

test "a fully declared leaf clique keeps the trunk and co-realizes its pair edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  A --- B\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    var report: join_commit.Report = .{};
    const joins = try join_commit.buildReported(a, graph, &plan, &.{}, false, &report);

    // The fan-IN at Z fuses, and A---B is discharged by its crossbar.
    try std.testing.expectEqual(@as(u32, 0), report.rail_closure_undeclared);
    try std.testing.expectEqual(@as(usize, 1), joins.co_realized.len);
    try std.testing.expectEqual(edgeIdOf(graph, "A", "B"), joins.co_realized[0]);
    var fused = false;
    for (joins.selected_joins) |sj| {
        for (plan.groups) |g| if (g.id == sj.permission_group and g.direction == .in and g.pivot == nodeId(graph, "Z")) {
            fused = true;
        };
    }
    try std.testing.expect(fused);
}

test "a labeled or decorated declaration cannot back a leaf pair" {
    const sources = [_][]const u8{
        "flowchart TD\n  A --- Z\n  B --- Z\n  A -- why --- B\n", // labeled
        "flowchart TD\n  A --- Z\n  B --- Z\n  A --> B\n", // arrowed
        "flowchart TD\n  A --- Z\n  B --- Z\n  A -.- B\n", // wrong stroke class
    };
    for (sources) |source| {
        var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena2.deinit();
        const a = arena2.allocator();
        const graph = try parse(a, source);
        const plan = (try permits.build(a, graph, .joined)).plan;
        var report: join_commit.Report = .{};
        const joins = try join_commit.buildReported(a, graph, &plan, &.{}, false, &report);
        try std.testing.expectEqual(@as(usize, 0), joins.co_realized.len);
        try std.testing.expectEqual(@as(u32, 1), report.rail_closure_undeclared);
    }
}

test "a reversed member does not hide a closure refusal behind a null disposition" {
    // in@Z = {A---Z, B---Z, Q---Z} with Q---Z layout-reversed: the forward
    // subset {A---Z, B---Z} is provisionally eligible, and the closure law
    // then refuses it (A—B undeclared). The refusal MUST reach the members as
    // `independent` — the null-disposition escape is for a group the reversal
    // rule left ungrouped, and would silently keep the rail fused.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  Z --- W\n  W --- Q\n  Q --- Z\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const reversed = [_]u32{edgeIdOf(graph, "Q", "Z")};
    var report: join_commit.Report = .{};
    const joins = try join_commit.buildReported(a, graph, &plan, &reversed, false, &report);

    try std.testing.expectEqual(@as(usize, 0), joins.selected_joins.len);
    try std.testing.expectEqual(@as(u32, 1), report.rail_closure_undeclared);
    for ([_][]const u8{ "A", "B" }) |leaf| {
        const t = targetOf(joins, edgeIdOf(graph, leaf, "Z")).?;
        try std.testing.expect(t != null);
        try std.testing.expect(t.? == .independent);
    }
}

test "every closure-law counter names a registered report-only tag" {
    // The counters ARE the diagnostics: a report field that stopped naming a
    // registered tag would be firing something the registry never sanctioned
    // (D-DISPOSITION item 4's unregistered backstop), and a class other than
    // report-only would let a refusal invalidate a candidate instead of
    // unfusing it.
    const fields = [_][]const u8{ "rail_closure_undeclared", "co_undeclared", "co_double_discharge" };
    inline for (fields) |name| {
        const tag = pb.tagByName(name) orelse return error.UnregisteredTag;
        try std.testing.expectEqual(pb.DispositionClass.report_only, pb.classOf(tag));
    }
    // Spelled the same on the structs that carry them.
    try std.testing.expect(@hasField(join_commit.Report, fields[0]));
    try std.testing.expect(@hasField(join_commit.Report, fields[1]));
    try std.testing.expect(@hasField(realized.Report, fields[2]));
}

test "a clique whose pair edges are other rails' members keeps a rail" {
    // Z---A, Z---B, Z---C plus the full leaf clique A---B, A---C, B---C. Every
    // leaf pair of the widest star is declared, so it must stay fused — and
    // each of those declarations is itself a member of some OTHER star, so a
    // rule that withheld another rail's ink as a backer would refuse the whole
    // clique and rebuild the picture around a fabrication that is not there.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  Z --- A\n  Z --- B\n  Z --- C\n  A --- B\n  A --- C\n  B --- C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    var report: join_commit.Report = .{};
    const joins = try join_commit.buildReported(a, graph, &plan, &.{}, false, &report);

    try std.testing.expectEqual(@as(u32, 0), report.rail_closure_undeclared);
    try std.testing.expectEqual(@as(u32, 0), report.co_undeclared);
    try std.testing.expect(joins.selected_joins.len > 0);
    // A declaration is discharged by at most ONE rail plan-wide: the record
    // carries no duplicates, and no discharged edge is another rail's member.
    for (joins.co_realized, 0..) |co, i| {
        for (joins.co_realized[0..i]) |prev| try std.testing.expect(prev != co);
        for (joins.selected_joins) |sj| for (sj.members) |m| try std.testing.expect(m != co);
    }
}

test "a single fan with its own fully declared clique keeps the whole trunk" {
    // A---Z, B---Z, C---Z plus the leaf clique A---B, A---C, B---C. The star at
    // Z asserts exactly those three pairs and the graph declares all three, so
    // the rail keeps every member and its crossbar takes over their rendering.
    // The clique edges pair up into stars of their own (in@C is {A---C, B---C}),
    // but those are the star's OWN discharges: co-realized ink draws nothing
    // privately, so it can carry no competing trunk and claims no pair.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n  A --- B\n  A --- C\n  B --- C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    var report: join_commit.Report = .{};
    const joins = try join_commit.buildReported(a, graph, &plan, &.{}, false, &report);

    try std.testing.expectEqual(@as(u32, 0), report.rail_closure_undeclared);
    try std.testing.expectEqual(@as(u32, 0), report.co_undeclared);
    try std.testing.expectEqual(@as(usize, 1), joins.selected_joins.len);
    const trunk = joins.selected_joins[0];
    for (plan.groups) |g| if (g.id == trunk.permission_group) {
        try std.testing.expectEqual(pb.JoinDirection.in, g.direction);
        try std.testing.expectEqual(nodeId(graph, "Z"), g.pivot);
    };
    try std.testing.expectEqual(@as(usize, 3), trunk.members.len);
    // Exactly the three clique declarations are co-realized by that crossbar.
    try std.testing.expectEqual(@as(usize, 3), joins.co_realized.len);
    for ([_][2][]const u8{ .{ "A", "B" }, .{ "A", "C" }, .{ "B", "C" } }) |pair| {
        const id = edgeIdOf(graph, pair[0], pair[1]);
        var found = false;
        for (joins.co_realized) |co| {
            if (co == id) found = true;
        }
        try std.testing.expect(found);
    }
}

test "two rails asserting one declared pair both refuse" {
    // A---Z, B---Z and A---W, B---W with A---B declared. Each star asserts only
    // A—B, which the graph does declare — but the two crossbars run over the
    // SAME leaf columns, so a reader traces Z up A's column, along one
    // crossbar and down to W: a relation nothing declares. The pair is
    // spendable exactly once, so neither rail may keep it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  A --- W\n  B --- W\n  A --- B\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    var report: join_commit.Report = .{};
    const joins = try join_commit.buildReported(a, graph, &plan, &.{}, false, &report);

    try std.testing.expectEqual(@as(usize, 0), joins.selected_joins.len);
    // Nothing is co-realized: a refused rail draws no crossbar to render A---B.
    try std.testing.expectEqual(@as(usize, 0), joins.co_realized.len);
    try std.testing.expectEqual(@as(u32, 2), report.rail_closure_undeclared);
    // The refusal reaches every member as `independent` — that is what unfuses.
    for ([_][2][]const u8{ .{ "A", "Z" }, .{ "B", "Z" }, .{ "A", "W" }, .{ "B", "W" } }) |pair| {
        const t = targetOf(joins, edgeIdOf(graph, pair[0], pair[1])).?;
        try std.testing.expect(t.? == .independent);
    }
}

test "one rail's pair survives when no second rail asserts it" {
    // The same picture minus the second star: A---Z, B---Z, A---W with A---B
    // declared. Only one rail asserts A—B now, so the reservation has nothing
    // to refuse and the star at Z keeps its crossbar — the boundary the
    // both-refuse rule must not overshoot.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  A --- W\n  A --- B\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    var report: join_commit.Report = .{};
    const joins = try join_commit.buildReported(a, graph, &plan, &.{}, false, &report);

    try std.testing.expectEqual(@as(u32, 0), report.rail_closure_undeclared);
    try std.testing.expectEqual(@as(usize, 1), joins.selected_joins.len);
    try std.testing.expectEqual(@as(usize, 1), joins.co_realized.len);
    try std.testing.expectEqual(edgeIdOf(graph, "A", "B"), joins.co_realized[0]);
}
test "a salvaged rail that then loses its pair is one refusal, not two" {
    // A---Z, B---Z, C---Z and A---W, B---W with A---B declared. Z's rail can
    // only SALVAGE (A—C and B—C are undeclared) — counted once — and the
    // salvaged subset then asserts A—B, which W's rail asserts too, so both
    // lose the pair. Two groups refuse, so the report says two: the salvage
    // must not be counted a second time when the reservation takes it apart.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n  A --- W\n  B --- W\n  A --- B\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    var report: join_commit.Report = .{};
    const joins = try join_commit.buildReported(a, graph, &plan, &.{}, false, &report);

    try std.testing.expectEqual(@as(usize, 0), joins.selected_joins.len);
    try std.testing.expectEqual(@as(usize, 0), joins.co_realized.len);
    try std.testing.expectEqual(@as(u32, 2), report.rail_closure_undeclared);
}
