//! Root-level pin that a route visits each cell once, against a REAL
//! render: parse -> permits -> select -> rasterize. The raster counts every
//! stroke cell whose painted arms no owner set explains (`raster/arms.zig`
//! `arms_unexplained`): a junction glyph with one owner, or a run that stops
//! in open space. A fan member's polyline used to double back along its
//! rail row when the target-side corridor lay between the target column
//! and the source (`layout/fan_polyline.zig`), and the seed below shipped
//! exactly that: an eight-cell dead-end run beside a foreign head, with a
//! tee no second edge joined. The producer now ends the rail run at the
//! corridor column, and the seed pins the counter at zero on every width.

const std = @import("std");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");

// flowchart_multilayer_dag_td_12: at w60 the VerifyAddress -> UpdateShipping
// member's rail ran west past its target column and came back to the
// corridor, leaving `╶───────┬` on the row above ApplyDiscount's head.
const multilayer =
    \\flowchart TD
    \\    OR[OrderReceived]
    \\    VP[ValidatePayment]
    \\    CI[CheckInventory]
    \\    VA[VerifyAddress]
    \\    FC[FraudCheck]
    \\    RS[ReserveStock]
    \\    US[UpdateShipping]
    \\    AD[ApplyDiscount]
    \\    CC[ChargeCard]
    \\    PI[PackItems]
    \\    GL[GenerateLabel]
    \\    DO[DispatchOrder]
    \\
    \\    OR --> VP
    \\    OR --> CI
    \\    OR --> VA
    \\    VP --> FC
    \\    VP --> AD
    \\    CI --> RS
    \\    CI --> AD
    \\    VA --> US
    \\    VA --> RS
    \\    FC --> CC
    \\    AD --> CC
    \\    AD --> PI
    \\    RS --> PI
    \\    US --> GL
    \\    CC --> DO
    \\    PI --> DO
    \\    GL --> DO
    \\
;

/// Stroke cells painting a single arm: the stub a doubled-back route
/// leaves where it turned around. Read off the grid, independently of
/// the counter, so the pin does not trust the counter alone.
fn stubCells(lat: anytype) u32 {
    var n: u32 = 0;
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.atConst(x, y);
            if (cell.occupant == .edge_segment and @popCount(cell.neighbours.toMask()) == 1) n += 1;
        }
    }
    return n;
}

test "flowchart_multilayer_dag_td_12 ships no one-owner junction and no run that stops in open space at any width" {
    for ([3]u32{ 60, 90, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try parse(a, multilayer);
        const built = try permits.build(a, graph, .joined);
        const plan = built.plan;
        const winner = try select.choose(a, graph, &plan, width, false, false, .bridge);
        const report = try raster.rasterize(a, winner.sketch, .bridge);
        try std.testing.expectEqual(@as(u32, 0), report.arms_unexplained);
        try std.testing.expectEqual(@as(u32, 0), stubCells(&report.lattice));
        try std.testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
        try std.testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    }
}
