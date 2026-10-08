const std = @import("std");
const prim = @import("prim");
const rs = @import("rail_star.zig");

const testing = std.testing;

fn site(node: u32, side: rs.Dir4, offset: u32) rs.AttachmentSite {
    return .{ .node = node, .side = side, .offset = offset };
}

fn outMember(edge: u32, pivot: ?u32, leaf: ?u32) rs.RailClaimMember {
    return .{
        .edge = edge,
        .endpoints = .{ pivot, leaf },
        .sites = .{
            if (pivot) |node| site(node, .south, 2) else null,
            if (leaf) |node| site(node, .north, 1) else null,
        },
        .arrows = .{ .none, .filled },
        .kind = .solid,
        .pivot_end = .source,
    };
}

fn inMember(edge: u32, leaf: u32, pivot: u32) rs.RailClaimMember {
    return .{
        .edge = edge,
        .endpoints = .{ leaf, pivot },
        .sites = .{ site(leaf, .south, 1), site(pivot, .north, 2) },
        .arrows = .{ .none, .filled },
        .kind = .solid,
        .pivot_end = .target,
    };
}

fn outClaim(members: []const rs.RailClaimMember) rs.RailClaim {
    return .{ .id = 1, .polarity = .out, .members = members };
}

test "valid fan-out derives its pivot and pi and passes every partition" {
    const members = [_]rs.RailClaimMember{
        outMember(1, 10, 20),
        outMember(2, 10, 21),
        outMember(3, 10, 22),
    };
    const result = rs.check(outClaim(&members));
    try testing.expect(result.isValid());
    try testing.expectEqual(@as(?u32, 10), result.derived_pivot);
    try testing.expectEqual(@as(u32, 10), result.derived_pi.?.node);
    try testing.expect(!result.partition().any());
}

test "valid fan-in derives its target pivot and shared attachment" {
    const members = [_]rs.RailClaimMember{
        inMember(1, 20, 10),
        inMember(2, 21, 10),
    };
    const claim: rs.RailClaim = .{ .id = 1, .polarity = .in, .members = &members };
    const result = rs.check(claim);
    try testing.expect(result.isValid());
    try testing.expectEqual(@as(?u32, 10), result.derived_pivot);
    try testing.expectEqual(@as(u32, 10), result.derived_pi.?.node);
}

test "wrong recorded pivot end is a polarity failure" {
    var members = [_]rs.RailClaimMember{
        outMember(1, 10, 20),
        outMember(2, 10, 21),
    };
    members[1].pivot_end = .target;
    const result = rs.check(outClaim(&members));
    try testing.expect(result.star_law.wrong_polarity_end);
    try testing.expect(result.star_law.no_common_real_pivot);
}

fn withPivotEnd(m: rs.RailClaimMember, end: @TypeOf(m.pivot_end)) rs.RailClaimMember {
    var out = m;
    out.pivot_end = end;
    return out;
}

fn withSite(m: rs.RailClaimMember, end: usize, s: ?rs.AttachmentSite) rs.RailClaimMember {
    var out = m;
    out.sites[end] = s;
    return out;
}

test "each star-law, decoration, style or record defect invalidates a claim" {
    var circle = outMember(2, 10, 21);
    circle.arrows[0] = .circle;
    var dotted = outMember(2, 10, 21);
    dotted.kind = .dotted;
    const Row = struct {
        members: []const rs.RailClaimMember,
        id: rs.RailClaimId = 1,
        no_pivot: bool = false,
        no_pi: bool = false,
        wrong_polarity_end: bool = false,
    };
    const rows = [_]Row{
        // One wrong pivot, then three disagreeing pivots.
        .{ .members = &.{ outMember(1, 10, 20), outMember(2, 11, 21) } },
        .{ .members = &.{ outMember(1, 10, 20), outMember(2, 11, 21), outMember(3, 12, 22) }, .no_pivot = true },
        // Duplicate edge, duplicate leaf, self-loop.
        .{ .members = &.{ outMember(7, 10, 20), outMember(7, 10, 21) } },
        .{ .members = &.{ outMember(1, 10, 20), outMember(2, 10, 20) } },
        .{ .members = &.{ outMember(1, 10, 10), outMember(2, 10, 20) } },
        // Antiparallel is found without trusting pivot_end, which raster/fan_roles reads.
        .{ .members = &.{ outMember(1, 10, 20), withPivotEnd(outMember(2, 20, 10), .target) }, .wrong_polarity_end = true },
        // Differing and missing pivot-side sites leave no pi.
        .{ .members = &.{ outMember(1, 10, 20), withSite(outMember(2, 10, 21), 0, site(10, .south, 3)) }, .no_pi = true },
        .{ .members = &.{ outMember(1, 10, 20), withSite(outMember(2, 10, 21), 0, null) }, .no_pi = true },
        .{ .members = &.{ outMember(1, 10, 20), circle } },
        .{ .members = &.{ outMember(1, 10, 20), dotted } },
        // Unresolved endpoint, missing leaf site, and a leaf site on the wrong node.
        .{ .members = &.{ outMember(1, 10, 20), outMember(2, null, 21) } },
        .{ .members = &.{ outMember(1, 10, 20), withSite(outMember(2, 10, 21), 1, null) } },
        .{ .members = &.{ outMember(1, 10, 20), withSite(outMember(2, 10, 21), 1, site(99, .north, 1)) } },
        // Arity and the zero sentinel id.
        .{ .members = &.{outMember(1, 10, 20)}, .id = rs.no_rail_claim },
    };
    for (rows) |row| {
        const result = rs.check(.{ .id = row.id, .polarity = .out, .members = row.members });
        try testing.expect(!result.isValid());
        if (row.no_pivot) try testing.expectEqual(@as(?u32, null), result.derived_pivot);
        if (row.no_pi) try testing.expectEqual(@as(?rs.AttachmentSite, null), result.derived_pi);
        if (row.wrong_polarity_end) try testing.expect(result.star_law.wrong_polarity_end);
    }
}

fn licenceMember(edge: u32, pivot: u32, leaf: u32, arrows: [2]rs.ArrowKind) rs.RailLicenceMember {
    return .{
        .edge = edge,
        .endpoints = .{ pivot, leaf },
        .arrows = arrows,
        .kind = .solid,
        .pivot_end = .source,
    };
}

fn outLicence(members: []const rs.RailLicenceMember) rs.RailLicence {
    return .{ .id = 1, .polarity = .out, .pivot = 10, .members = members };
}

test "the licence holds only for a star whose members all block" {
    var one_way: [2]rs.RailLicenceMember = undefined;
    for (&one_way, [_]prim.StandsFor{ .forward_one_way, .backward_one_way }) |*m, class| {
        m.* = licenceMember(3, 10, 22, .{ .none, .none });
        m.stands_for = class;
    }
    var directed = licenceMember(3, 10, 22, .{ .none, .none });
    directed.stands_for = .directed;
    const head = licenceMember(1, 10, 20, .{ .none, .filled });
    const head2 = licenceMember(2, 10, 21, .{ .none, .filled });
    const Row = struct { members: []const rs.RailLicenceMember, valid: ?bool, non_blocking: bool };
    const rows = [_]Row{
        .{ .members = &.{ head, head2 }, .valid = true, .non_blocking = false },
        // Directional ends on both sides block nothing.
        .{ .members = &.{ licenceMember(1, 10, 20, .{ .filled, .filled }), licenceMember(2, 10, 21, .{ .filled, .filled }) }, .valid = false, .non_blocking = true },
        .{ .members = &.{ head, licenceMember(2, 10, 21, .{ .none, .none }) }, .valid = false, .non_blocking = true },
        // An all-arrow-free star, bare or decorated, is not the blocking predicate's to refuse.
        .{ .members = &.{ licenceMember(1, 10, 20, .{ .none, .none }), licenceMember(2, 10, 21, .{ .none, .none }) }, .valid = true, .non_blocking = false },
        .{ .members = &.{ licenceMember(1, 10, 20, .{ .none, .circle }), licenceMember(2, 10, 21, .{ .none, .circle }) }, .valid = null, .non_blocking = false },
        // A head at the source side alone still blocks.
        .{ .members = &.{ licenceMember(1, 10, 20, .{ .filled, .none }), head2 }, .valid = null, .non_blocking = false },
        // Placement proxies: one-way crossings block like a head, directed ink refuses.
        .{ .members = &.{ head, head2, one_way[0] }, .valid = null, .non_blocking = false },
        .{ .members = &.{ head, head2, one_way[1] }, .valid = null, .non_blocking = false },
        .{ .members = &.{ head, head2, directed }, .valid = false, .non_blocking = true },
    };
    for (rows) |row| {
        const result = rs.checkLicence(outLicence(row.members));
        try testing.expectEqual(row.non_blocking, result.star_law.non_blocking_member);
        if (row.valid) |valid| try testing.expectEqual(valid, result.isValid());
    }
}
