//! Root-level pin for the decoration cell's guarded sides against a REAL
//! render: parse -> permits -> select -> rasterize. The constitution gives
//! an arrowhead cell three guarded sides (base, tip, laterals); the raster
//! counts a tip that is not on its port (`tip_not_port`) and every arm that
//! entered from a lateral side (`arm_into_head`, refused or shipped). The
//! producers keep a route straight through its own decorated terminal
//! cells and reserve arrival cells and decoration laterals before any route
//! is laid, so the seed that used to show the defect now pins its absence.

const std = @import("std");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");

// flowchart_arrow_ends_td_6 at w90: the bidirectional Worker <--> Ledger
// route used to turn inside its own departure cell, so the source head was
// stamped on a corner — tip into blank, one lateral arm. The straight-through
// rule now bends the route one cell further out: the source head points
// north into Worker's port, nothing transits a head, and both counters are
// zero on the whole render.
test "flowchart_arrow_ends_td_6 at w90 draws every head into its port with no lateral arm" {
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
    try std.testing.expectEqual(graph.direction, winner.sketch.direction);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    try std.testing.expectEqual(@as(u32, 0), report.arrow_base.tip_not_port);
    try std.testing.expectEqual(@as(u32, 0), report.armIntoHead());
    try std.testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    try std.testing.expectEqual(@as(u32, 0), report.edge_heads_lost);

    // The bidirectional edge's source head points north, its tip on Worker's border.
    var worker_edge: ?u32 = null;
    for (graph.edges) |e| if (e.arrow_from != .none and e.arrow_to != .none) {
        worker_edge = e.id;
    };
    var north_heads: u32 = 0;
    const lat = report.lattice;
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.atConst(x, y);
            switch (cell.occupant) {
                .arrowhead => |head| {
                    if (head.edge != worker_edge.? or head.dir != .north) continue;
                    north_heads += 1;
                    try std.testing.expect(y >= 1);
                    try std.testing.expect(lat.atConst(x, y - 1).occupant == .node_border);
                },
                else => {},
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 1), north_heads);
}
