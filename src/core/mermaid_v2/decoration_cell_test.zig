//! Root-level pin for the decoration cell's guarded sides against a REAL
//! render: parse -> permits -> select -> rasterize. The constitution gives
//! an arrowhead cell three guarded sides (base, tip, laterals); the raster
//! counts a tip that is not on its port (`tip_not_port`) and every arm that
//! entered from a lateral side (`arm_into_head`, refused or shipped). The
//! producer rule that keeps a route straight through its own terminal
//! cells is a later stage, so this file pins that the defect is COUNTED on
//! the seed that shows it, not that it is gone.

const std = @import("std");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");

// The sideways head (flowchart_arrow_ends_td_6 at w90): the bidirectional
// Worker <--> Ledger route turns inside its own departure cell, so the
// source head is stamped on a corner — its tip points at blank and it
// ships a lateral arm. This stage counts the defect (tip_not_port,
// arm_into_head); the producer rule that removes it is a later stage, so
// the pin is a floor, not an exact value.
test "the sideways head of flowchart_arrow_ends_td_6 is counted, not repaired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\    Service[Payment Service]
        \\    Ledger[Ledger DB]
        \\    Metrics[Metrics Sink]
        \\    Legacy[Legacy Gateway]
        \\    Queue[Event Queue]
        \\    Worker[Settlement Worker]
        \\
        \\    Service --> Ledger
        \\    Service --o Metrics
        \\    Service --x Legacy
        \\    Service --> Queue
        \\    Queue --> Worker
        \\    Worker <--> Ledger
        \\
    );
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const winner = try select.choose(a, graph, &plan, 90, false, false, .bridge);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    try std.testing.expect(report.arrow_base.tip_not_port >= 1);
    try std.testing.expect(report.armIntoHead() >= 1);
    try std.testing.expectEqual(@as(u32, 0), report.edge_heads_lost);
}
