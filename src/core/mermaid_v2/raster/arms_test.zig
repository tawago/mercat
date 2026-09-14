//! Tests for raster/arms.zig, discovered through its own
//! `test { _ = @import("arms_test.zig"); }` block. Every lattice is
//! hand-built: the counter reads painted cells and side-table records, so
//! each case states exactly which arms and which records it holds.

const std = @import("std");
const lattice = @import("../lattice.zig");
const arms = @import("arms.zig");

const testing = std.testing;

const W: u32 = 3;
const H: u32 = 3;

fn edgeCell(edge: lattice.EdgeId, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = edge, .kind = .solid } }, .neighbours = nb };
}

/// A 3×3 lattice whose centre cell is `centre`, with `records` as its
/// (already sorted) side table, collection complete.
fn latticeWith(buf: *[W * H]lattice.Cell, centre: lattice.Cell, records: []const lattice.Aux) lattice.Lattice {
    for (buf) |*c| c.* = lattice.Cell.empty;
    buf[4] = centre;
    return .{ .width = W, .height = H, .cells = buf, .aux = records, .aux_collection = .{ .state = .complete } };
}

const tee: lattice.Neighbours = .{ .e = true, .w = true, .s = true };
const cross: lattice.Neighbours = .{ .n = true, .e = true, .s = true, .w = true };

test "a tee one edge owns is unexplained; a merged carrier, a rail member or a tap explains it" {
    var buf: [W * H]lattice.Cell = undefined;
    const alone = latticeWith(&buf, edgeCell(7, tee), &.{});
    try testing.expectEqual(@as(u32, 1), arms.unexplained(&alone));

    const licensed = [_]lattice.Aux{.{ .cell = 4, .value = 9, .kind = .carrier, .detail = @intFromEnum(lattice.CarrierKind.merged_licensed) }};
    const joined = latticeWith(&buf, edgeCell(7, tee), &licensed);
    try testing.expectEqual(@as(u32, 0), arms.unexplained(&joined));

    // A foreign merge is a fabrication the crossing tally already counts;
    // its bits are in the mask, so the tee has two owners here.
    const foreign = [_]lattice.Aux{.{ .cell = 4, .value = 9, .kind = .carrier, .detail = @intFromEnum(lattice.CarrierKind.merged_foreign) }};
    const merged = latticeWith(&buf, edgeCell(7, tee), &foreign);
    try testing.expectEqual(@as(u32, 0), arms.unexplained(&merged));

    const rider = [_]lattice.Aux{.{ .cell = 4, .value = 9, .kind = .rail_member }};
    const ridden = latticeWith(&buf, edgeCell(7, cross), &rider);
    try testing.expectEqual(@as(u32, 0), arms.unexplained(&ridden));

    const branch = [_]lattice.Aux{.{ .cell = 4, .value = 9, .kind = .tap }};
    const tapped = latticeWith(&buf, edgeCell(7, tee), &branch);
    try testing.expectEqual(@as(u32, 0), arms.unexplained(&tapped));

    // A record naming the owner itself adds nobody; a record on another
    // cell says nothing about this one.
    const self_named = [_]lattice.Aux{ .{ .cell = 3, .value = 9, .kind = .tap }, .{ .cell = 4, .value = 7, .kind = .rail_member }, .{ .cell = 5, .value = 9, .kind = .tap } };
    const still_alone = latticeWith(&buf, edgeCell(7, tee), &self_named);
    try testing.expectEqual(@as(u32, 1), arms.unexplained(&still_alone));
}

test "a one-armed stroke is a run that stops in open space; a straight run and a corner are not" {
    var buf: [W * H]lattice.Cell = undefined;
    const stub = latticeWith(&buf, edgeCell(7, .{ .e = true }), &.{});
    try testing.expectEqual(@as(u32, 1), arms.unexplained(&stub));

    const bare = latticeWith(&buf, edgeCell(7, .{}), &.{});
    try testing.expectEqual(@as(u32, 1), arms.unexplained(&bare));

    const run = latticeWith(&buf, edgeCell(7, .{ .e = true, .w = true }), &.{});
    try testing.expectEqual(@as(u32, 0), arms.unexplained(&run));

    const corner = latticeWith(&buf, edgeCell(7, .{ .n = true, .e = true }), &.{});
    try testing.expectEqual(@as(u32, 0), arms.unexplained(&corner));
}

test "a suppressed carrier contributes no bits, so it explains no arm" {
    var buf: [W * H]lattice.Cell = undefined;
    const refused = [_]lattice.Aux{.{ .cell = 4, .value = 9, .kind = .carrier, .detail = @intFromEnum(lattice.CarrierKind.suppressed) }};
    const lat = latticeWith(&buf, edgeCell(7, tee), &refused);
    try testing.expectEqual(@as(u32, 1), arms.unexplained(&lat));

    const untested = [_]lattice.Aux{.{ .cell = 4, .value = 9, .kind = .carrier, .detail = @intFromEnum(lattice.CarrierKind.merged_untested) }};
    const merged = latticeWith(&buf, edgeCell(7, tee), &untested);
    try testing.expectEqual(@as(u32, 0), arms.unexplained(&merged));
}

test "without a collected side table a tee is not judged; a stub still is" {
    var buf: [W * H]lattice.Cell = undefined;
    var lat = latticeWith(&buf, edgeCell(7, tee), &.{});
    lat.aux_collection = .{ .state = .not_collected };
    try testing.expectEqual(@as(u32, 0), arms.unexplained(&lat));

    var stub = latticeWith(&buf, edgeCell(7, .{ .w = true }), &.{});
    stub.aux_collection = .{ .state = .out_of_memory };
    try testing.expectEqual(@as(u32, 1), arms.unexplained(&stub));
}

test "a border tee, a frame cross and a head's lateral arm are other tallies' business" {
    var buf: [W * H]lattice.Cell = undefined;
    const border = latticeWith(&buf, .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = tee }, &.{});
    try testing.expectEqual(@as(u32, 0), arms.unexplained(&border));

    const frame = latticeWith(&buf, .{ .occupant = .{ .cluster_border = .{ .cluster = 1, .role = .edge_s } }, .neighbours = cross }, &.{});
    try testing.expectEqual(@as(u32, 0), arms.unexplained(&frame));

    const head = latticeWith(&buf, .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 7 } }, .neighbours = tee }, &.{});
    try testing.expectEqual(@as(u32, 0), arms.unexplained(&head));
}
