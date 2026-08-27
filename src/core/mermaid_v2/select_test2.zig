//! select_test2.zig — continuation of select_test.zig, split at the
//! mermaid_v2 500-line cap. Same surface, same allowed imports.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, ledger, budget,
//! parse, select, permits.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const ladder = @import("budget.zig");
const select = @import("select.zig");
const permits_mod = @import("ledger/permits.zig");
const parse = @import("parse.zig").parse;

test "a packed candidate keeps its layout co-sets when no plan realized" {
    // A candidate carrying MOTIF-PACK synthetic frames is off the planner's
    // identity path, so `realize` declines it and the plan stays empty. An
    // empty plan is not the statement "nobody may share": applying it must
    // leave layout's own sets in place, or the candidate's legal sharers
    // lose their only permission record.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a,
        \\flowchart TD
        \\  A --> B1 --> C1
        \\  A --> B2 --> C2
        \\
    );
    const permits = (try permits_mod.build(a, g, .joined)).plan;
    const packed_cands = try select.packedCandidates(a, g, &permits, 80);
    try std.testing.expect(packed_cands.len > 0);
    var cand = packed_cands[0];
    try std.testing.expect(cand.sketch.clusters.len != 0);
    const before = cand.sketch.co_sets;

    select.applyPlan(a, &permits, &cand.sketch);

    try std.testing.expectEqual(@as(usize, 0), cand.sketch.joins.selected_joins.len);
    try std.testing.expectEqual(before.len, cand.sketch.co_sets.len);
    for (cand.sketch.co_sets, before) |after, want| {
        try std.testing.expectEqual(want.origin, after.origin);
        try std.testing.expectEqualSlices(ledger.EdgeId, want.members, after.members);
    }
}

test "applying a plan keeps the sketch's port-share co-sets" {
    // A port share is GEOMETRIC: two edges the producers routed through one
    // perimeter port share their approach ink whatever the join planner
    // decides. So the plan's own population replaces only itself, and every
    // `.port_share` record survives `applyPlan` (and the CI filter's
    // re-derivation, which shares the same rule via `replanSets`).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n");
    const permits = (try permits_mod.build(a, g, .joined)).plan;
    var cand = try ladder.run(a, g, &permits, 120);
    select.applyPlan(a, &permits, &cand.sketch);

    // Non-vacuity: the plan realized (otherwise nothing was replaced at all).
    try std.testing.expect(cand.sketch.joins.selected_joins.len > 0);
    var saw_plan = false;
    for (cand.sketch.co_sets) |set| switch (set.origin) {
        .selected_join => saw_plan = true,
        // Layout's fans never survive a realized plan; port shares always do.
        .fan_rail => return error.PlanKeptLayoutFanSets,
        .port_share => try std.testing.expect(set.members.len >= 2),
    };
    try std.testing.expect(saw_plan);

    // Every port share the geometry declares is present after the plan.
    for (cand.sketch.edges) |first| for (cand.sketch.edges) |second| {
        if (first.id == second.id) continue;
        const shares = samePoint(first.polyline[0], second.polyline[0]) or
            samePoint(first.polyline[first.polyline.len - 1], second.polyline[second.polyline.len - 1]) or
            samePoint(first.polyline[0], second.polyline[second.polyline.len - 1]);
        if (!shares) continue;
        try std.testing.expect(ledger.coMembers(cand.sketch.co_sets, first.id, second.id));
    };
}

fn samePoint(a: anytype, b: anytype) bool {
    return a.x == b.x and a.y == b.y;
}

// The label-policy variant suite is aggregated here (entry.zig's test block
// sits at the 500-line cap).
test {
    _ = @import("select_test3.zig");
}
