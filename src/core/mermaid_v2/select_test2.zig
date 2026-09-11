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

test "a packed candidate keeps its layout bundles when no plan realized" {
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
    const before = cand.sketch.bundle_sets;
    try std.testing.expect(before.len > 0);

    select.applyPlan(a, &permits, &cand.sketch);

    try std.testing.expectEqual(@as(usize, 0), cand.sketch.bundles.selected_bundles.len);
    try std.testing.expectEqual(before.len, cand.sketch.bundle_sets.len);
    for (cand.sketch.bundle_sets, before) |after, want| {
        try std.testing.expectEqual(want.origin, after.origin);
        try std.testing.expectEqualSlices(ledger.EdgeId, want.members, after.members);
    }
}

test "applying a plan keeps the sketch's port-share bundles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n");
    const permits = (try permits_mod.build(a, g, .joined)).plan;
    var cand = try ladder.run(a, g, &permits, 120);
    select.applyPlan(a, &permits, &cand.sketch);

    try std.testing.expect(cand.sketch.bundles.selected_bundles.len > 0);
    var saw_plan = false;
    for (cand.sketch.bundle_sets) |set| switch (set.origin) {
        .selected_bundle => saw_plan = true,
        .fan_rail => return error.PlanKeptLayoutFanSets,
        .port_share => try std.testing.expect(set.members.len >= 2),
    };
    try std.testing.expect(saw_plan);

    for (cand.sketch.edges) |first| for (cand.sketch.edges) |second| {
        if (first.id == second.id) continue;
        const shares = samePoint(first.polyline[0], second.polyline[0]) or
            samePoint(first.polyline[first.polyline.len - 1], second.polyline[second.polyline.len - 1]) or
            samePoint(first.polyline[0], second.polyline[second.polyline.len - 1]);
        if (!shares) continue;
        try std.testing.expect(ledger.bundleMembersAt(cand.sketch.bundle_sets, first.id, second.id, null));
    };
}

fn samePoint(a: anytype, b: anytype) bool {
    return a.x == b.x and a.y == b.y;
}

test {
    _ = @import("select_test3.zig");
}
