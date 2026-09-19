const std = @import("std");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");

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
        try std.testing.expectEqual(@as(u32, 0), stubCells(&report.lattice));
        try std.testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
        try std.testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    }
}
