//! Tests for `edge_roles.zig`'s `stampFanTrunks` strip pass. Discovered
//! via edge_roles.zig's top-level `test { _ = @import("edge_roles_test.zig"); }`
//! block, per the mermaid_v2/ test-file convention.
//!
//! All fixtures are hand-built lattices (shape-generic — no seed names).
//! Bit layout: N=0, E=1, S=2, W=3 (see `lattice.Neighbours`). The full
//! `┼` is N+E+W+S = 0b1111; `┴` is N+E+W = 0b1011; `┬` is E+S+W = 0b1110.

const std = @import("std");
const lattice = @import("../lattice.zig");
const edge_roles = @import("edge_roles.zig");

const testing = std.testing;

fn railCell(nb: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid, .role = .fan_out_rail } },
        .neighbours = nb,
    };
}

fn nodeBorder(nb: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .node_border = .{ .node = 5, .role = .edge_n } },
        .neighbours = nb,
    };
}

fn arrowSouth() lattice.Cell {
    return .{
        .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 0 } },
        .neighbours = .{},
    };
}

const all4: lattice.Neighbours = .{ .n = true, .e = true, .s = true, .w = true };

// ---------------------------------------------------------------------
// GRID-wrapped fan-OUT (rows > 1): the trunk threads THROUGH a second
// rail row. The vertical arm joining rail-row K to rail-row K+1 is a real
// trunk continuation and must survive as `┼` — the single-rail strip
// heuristic would otherwise sever it (upper cell → `┴`, orphaning the
// lower fan from the source). This is the direct regression pin for 2(2c).
// ---------------------------------------------------------------------
test "grid trunk keeps the rail-to-rail vertical (┼ over ┼)" {
    var buf: [15]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 5, .cells = &buf };

    // Column x=1: pivot border, two adjacent rail junctions (the connector
    // between them is their reciprocal S/N pair), child terminal below.
    lat.at(1, 0).* = nodeBorder(.{ .s = true }); // pivot stem
    lat.at(1, 1).* = railCell(all4); // upper rail junction ┼
    lat.at(1, 2).* = railCell(all4); // lower rail junction ┼
    lat.at(1, 3).* = arrowSouth(); // child terminal ▼

    edge_roles.stampFanTrunks(&lat);

    // Both junctions keep their full vertical: the connector survives.
    const up = lat.atConst(1, 1).neighbours;
    const lo = lat.atConst(1, 2).neighbours;
    try testing.expect(up.n and up.s); // upper still ┼ (S not stripped)
    try testing.expect(lo.n and lo.s); // lower still ┼ (N not stripped)
}

// ---------------------------------------------------------------------
// Offset-column grid connector: the second rail row arrives via a corner
// (`┌`/`┐` tier corner) rather than a straight junction. The rail cell
// below it must keep its N bit (not strip to `┬`) so it reciprocates the
// corner's descent. Pins the c24/c46 witness of 2(2c).
// ---------------------------------------------------------------------
test "offset-column grid connector keeps N (corner over rail)" {
    var buf: [18]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 6, .cells = &buf };

    // x=1: a `┌` tier corner (E+S) atop a full rail junction, whose S
    // descends as a pure vertical for >= 3 steps (below-reachable) so the
    // single-rail heuristic would strip the junction's N to `┬`.
    lat.at(1, 1).* = railCell(.{ .e = true, .s = true }); // ┌ corner
    lat.at(1, 2).* = railCell(all4); // rail junction ┼
    lat.at(1, 3).* = railCell(.{ .n = true, .s = true }); // descent
    lat.at(1, 4).* = railCell(.{ .n = true, .s = true });
    lat.at(1, 5).* = railCell(.{ .n = true, .s = true });

    edge_roles.stampFanTrunks(&lat);

    try testing.expect(lat.atConst(1, 2).neighbours.n); // N kept (not ┬)
}

// ---------------------------------------------------------------------
// Single-rail interior junction (no second rail): the center child's
// straight descent contributes a spurious S bit that must still be
// stripped to `┴`. Pins that the grid guard does NOT over-trigger and the
// legacy single-row behaviour is preserved.
// ---------------------------------------------------------------------
test "single-rail interior junction still strips to ┴" {
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };

    // x=1: pivot border above, a lone rail junction, an offset target's ▼
    // directly below (belongs to another column, not this stub's dropper).
    lat.at(1, 0).* = nodeBorder(.{ .s = true });
    lat.at(1, 1).* = railCell(all4);
    lat.at(1, 2).* = arrowSouth();

    edge_roles.stampFanTrunks(&lat);

    const got = lat.atConst(1, 1).neighbours;
    try testing.expect(!got.s); // spurious S stripped
    try testing.expectEqual(@as(u4, 0b1011), got.toMask()); // ┴ = N+E+W
}

// ---------------------------------------------------------------------
// Rail END with its own dropper: a single-horizontal-arm terminus whose
// ▼ directly below is genuinely its dropper (└ → ├). The existing rail-end
// reprieve must keep S. Guards that the grid guard leaves it untouched.
// ---------------------------------------------------------------------
test "rail END with its own dropper keeps S" {
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };

    // x=1: pivot above; junction with a single E arm (rail end) plus its
    // own ▼ dropper below.
    lat.at(1, 0).* = nodeBorder(.{ .s = true });
    lat.at(1, 1).* = railCell(.{ .n = true, .e = true, .s = true }); // ├-ish
    lat.at(1, 2).* = arrowSouth();

    edge_roles.stampFanTrunks(&lat);

    try testing.expect(lat.atConst(1, 1).neighbours.s); // dropper S kept
}
