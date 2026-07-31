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

test "a packed candidate keeps its fan co-sets when no plan realized" {
    // A candidate carrying cluster frames — a motif-packed one's synthetic
    // frames, stood in for here by a real subgraph — is off the planner's
    // identity path, so `realize` declines it and the plan stays empty. An
    // empty plan is not the statement "nobody may share": applying it must
    // leave layout's fan-derived sets in place, or the fan's legal sharers
    // lose their only permission record.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a,
        \\flowchart TD
        \\  subgraph S
        \\    A --> B
        \\    A --> C
        \\    A --> D
        \\  end
        \\
    );
    const permits = (try permits_mod.build(a, g, .joined)).plan;
    var cand = try ladder.run(a, g, &permits, false, 120);
    try std.testing.expect(cand.sketch.clusters.len != 0);
    const before = cand.sketch.co_sets;
    try std.testing.expect(before.len > 0);

    select.applyPlan(a, &permits, &cand.sketch);

    try std.testing.expectEqual(@as(usize, 0), cand.sketch.joins.selected_joins.len);
    try std.testing.expectEqual(before.len, cand.sketch.co_sets.len);
    for (cand.sketch.co_sets, before) |after, want| {
        try std.testing.expectEqual(ledger.CoOrigin.fan_rail, after.origin);
        try std.testing.expectEqualSlices(ledger.EdgeId, want.members, after.members);
    }
}
