//! RailClaim stitch transport tests, imported by stitch_rails.zig.

const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const split_mod = @import("split.zig");
const stitch_rails = @import("stitch_rails.zig");

const testing = std.testing;

fn member(edge: sketch.EdgeId, from: sketch.NodeId, to: sketch.NodeId, pivot_end: ledger.Endpoint) ledger.RailClaimMember {
    return .{
        .edge = edge,
        .endpoints = .{ from, to },
        .sites = .{
            .{ .node = from, .side = .south, .offset = 1 },
            .{ .node = to, .side = .north, .offset = 2 },
        },
        .arrows = .{ .none, .filled },
        .kind = .solid,
        .pivot_end = pivot_end,
    };
}

fn claim(id: ledger.RailClaimId, polarity: ledger.RailPolarity, members: []const ledger.RailClaimMember) ledger.RailClaim {
    return .{ .id = id, .polarity = polarity, .members = members };
}

fn path(id: sketch.EdgeId, from: sketch.NodeId, to: sketch.NodeId) sketch.EdgePath {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .polyline = &.{},
        .port_from = .{ .node = from, .side = .south, .offset = 1 },
        .port_to = .{ .node = to, .side = .north, .offset = 2 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
    };
}

fn emptySketch() sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn emptySplit(supers: []const split_mod.SuperNode) split_mod.SplitResult {
    return .{ .pieces = &.{}, .supers = supers, .crossings = &.{}, .arrivals = &.{}, .orig_node_count = 0 };
}

test "stitch rails: child claims deep-remap first-class and peer-drawn carriers in deterministic order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first_members = [_]ledger.RailClaimMember{
        member(0, 0, 1, .source),
        member(1, 0, 2, .source),
    };
    const first_claims = [_]ledger.RailClaim{claim(1, .out, &first_members)};
    const taps = [_]sketch.Tap{
        .{ .edge = 0, .node = 1, .at = .{ .x = 0, .y = 0 }, .landing = .{ .x = 0, .y = 1 } },
        .{ .edge = 1, .node = 2, .at = .{ .x = 1, .y = 0 }, .landing = .{ .x = 1, .y = 1 } },
    };
    var first = emptySketch();
    first.rails = &.{.{
        .pivot = 0,
        .stem = &.{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } },
        .crossbar = .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } },
        .taps = &taps,
        .kind = .solid,
    }};
    first.rail_claims = &first_claims;

    const peer_members = [_]ledger.RailClaimMember{
        member(4, 2, 0, .target),
        member(5, 1, 0, .target),
    };
    const peer_claims = [_]ledger.RailClaim{claim(1, .in, &peer_members)};
    const peer_paths = [_]sketch.EdgePath{ path(4, 2, 0), path(5, 1, 0) };
    var peer = emptySketch();
    peer.edges = &peer_paths;
    peer.rail_claims = &peer_claims;

    const sources = [_]stitch_rails.ChildSource{
        .{ .sketch = first, .node_map = &.{ 10, 14, 12 }, .edge_base = 20 },
        .{ .sketch = peer, .node_map = &.{ 30, 38, 35 }, .edge_base = 40 },
    };
    var outer = emptySketch();
    const outer_members = [_]ledger.RailClaimMember{
        member(8, 0, 1, .source),
        member(9, 0, 2, .source),
    };
    const outer_claims = [_]ledger.RailClaim{claim(77, .out, &outer_members)};
    outer.rail_claims = &outer_claims;

    const got = try stitch_rails.transport(a, emptySplit(&.{}), &sources, outer, &.{ 50, 51, 52 }, 60);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(@as(ledger.RailClaimId, 1), got[0].id);
    try testing.expectEqual(@as(ledger.RailClaimId, 2), got[1].id);
    try testing.expectEqual(@as(ledger.RailClaimId, 3), got[2].id);
    try testing.expect(got[0].members.ptr != first_members[0..].ptr);

    try testing.expectEqual(@as(sketch.EdgeId, 20), got[0].members[0].edge);
    try testing.expectEqual(@as(?sketch.NodeId, 10), ledger.checkRailClaim(got[0]).derived_pivot);
    try testing.expectEqual(@as(?sketch.NodeId, 14), got[0].members[0].endpoints[1]);
    try testing.expectEqual(@as(sketch.NodeId, 14), got[0].members[0].sites[1].?.node);
    try testing.expectEqual(sketch.Dir4.north, got[0].members[0].sites[1].?.side);
    try testing.expectEqual(@as(u32, 2), got[0].members[0].sites[1].?.offset);

    try testing.expectEqual(@as(sketch.EdgeId, 44), got[1].members[0].edge);
    try testing.expectEqual(@as(?sketch.NodeId, 30), ledger.checkRailClaim(got[1]).derived_pivot);
    try testing.expectEqual(@as(?sketch.NodeId, 35), got[1].members[0].endpoints[0]);
    try testing.expectEqual(@as(sketch.EdgeId, 68), got[2].members[0].edge);
    try testing.expectEqual(@as(?sketch.NodeId, 50), ledger.checkRailClaim(got[2]).derived_pivot);
    for (got) |transported| try testing.expect(ledger.checkRailClaim(transported).isValid());
}

test "stitch rails: surviving outer claim stays valid and a dropped placement member stays unresolved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const supers = [_]split_mod.SuperNode{.{ .outer_node = 2, .cluster_id = 100, .child_piece = 1 }};
    const edges = [_]sketch.EdgePath{
        path(0, 0, 1),
        path(1, 0, 3),
        path(2, 0, 2),
    };
    const live_members = [_]ledger.RailClaimMember{
        member(0, 0, 1, .source),
        member(1, 0, 3, .source),
    };
    const pending_members = [_]ledger.RailClaimMember{
        member(0, 0, 1, .source),
        member(2, 0, 2, .source),
    };
    const claims = [_]ledger.RailClaim{
        claim(5, .out, &live_members),
        claim(6, .out, &pending_members),
    };
    var outer = emptySketch();
    outer.edges = &edges;
    outer.rail_claims = &claims;

    const got = try stitch_rails.transport(a, emptySplit(&supers), &.{}, outer, &.{ 30, 31, sg.SENTINEL, 33 }, 100);
    try testing.expectEqual(@as(usize, 2), got.len);
    const first = ledger.checkRailClaim(got[0]);
    try testing.expect(first.isValid());
    try testing.expectEqual(@as(?sketch.NodeId, 30), first.derived_pivot);
    try testing.expectEqual(@as(sketch.NodeId, 30), first.derived_pi.?.node);

    const pending = got[1];
    try testing.expectEqual(@as(sketch.EdgeId, 102), pending.members[1].edge);
    try testing.expectEqual(@as(?sketch.NodeId, null), pending.members[1].endpoints[1]);
    try testing.expectEqual(@as(?ledger.AttachmentSite, null), pending.members[1].sites[1]);
    const checked = ledger.checkRailClaim(pending);
    try testing.expectEqual(@as(?sketch.NodeId, 30), checked.derived_pivot);
    try testing.expectEqual(@as(sketch.NodeId, 30), checked.derived_pi.?.node);
    try testing.expect(!checked.isValid());
    try testing.expect(checked.record.unresolved);
    try testing.expectEqual(@as(u32, 1), checked.derived_unresolved_members);
}

test "stitch rails: a dropped super-node pivot derives to null after transport" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const supers = [_]split_mod.SuperNode{.{ .outer_node = 2, .cluster_id = 100, .child_piece = 1 }};
    const edges = [_]sketch.EdgePath{ path(0, 0, 2), path(1, 1, 2) };
    const members = [_]ledger.RailClaimMember{
        member(0, 0, 2, .target),
        member(1, 1, 2, .target),
    };
    const claims = [_]ledger.RailClaim{claim(1, .in, &members)};
    var outer = emptySketch();
    outer.edges = &edges;
    outer.rail_claims = &claims;

    const got = try stitch_rails.transport(a, emptySplit(&supers), &.{}, outer, &.{ 40, 41, sg.SENTINEL }, 10);
    try testing.expectEqual(@as(usize, 1), got.len);
    const checked = ledger.checkRailClaim(got[0]);
    try testing.expectEqual(@as(?sketch.NodeId, null), checked.derived_pivot);
    try testing.expectEqual(@as(?ledger.AttachmentSite, null), checked.derived_pi);
    try testing.expectEqual(@as(u32, 2), checked.derived_unresolved_members);
    try testing.expect(checked.record.unresolved);
}
