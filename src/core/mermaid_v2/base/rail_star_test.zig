//! Unit tests for the semantic RailClaim model and its pure checker.

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

test "RailClaim ids are render-local one-based handles with zero sentinel" {
    try testing.expect(rs.RailClaimId == u32);
    try testing.expectEqual(@as(rs.RailClaimId, 0), rs.no_rail_claim);
    try testing.expect(!rs.validId(rs.no_rail_claim));
    try testing.expect(rs.validId(1));
    try testing.expect(rs.validId(std.math.maxInt(u32)));
    try testing.expect(rs.NodeId == prim.NodeId);
    try testing.expect(rs.EdgeId == prim.EdgeId);
    try testing.expect(rs.Dir4 == prim.Dir4);
    try testing.expect(rs.ArrowKind == prim.ArrowKind);
    try testing.expect(rs.EdgeKind == prim.EdgeKind);
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

test "one wrong pivot removes the common real pivot" {
    const members = [_]rs.RailClaimMember{
        outMember(1, 10, 20),
        outMember(2, 11, 21),
    };
    const result = rs.check(outClaim(&members));
    try testing.expect(result.star_law.no_common_real_pivot);
    try testing.expect(result.partition().star_law);
}

test "multiple member pivots derive no pivot at all" {
    const members = [_]rs.RailClaimMember{
        outMember(1, 10, 20),
        outMember(2, 11, 21),
        outMember(3, 12, 22),
    };
    const result = rs.check(outClaim(&members));
    try testing.expect(result.star_law.no_common_real_pivot);
    try testing.expectEqual(@as(?u32, null), result.derived_pivot);
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

test "duplicate member edge is reported independently" {
    const members = [_]rs.RailClaimMember{
        outMember(7, 10, 20),
        outMember(7, 10, 21),
    };
    const result = rs.check(outClaim(&members));
    try testing.expect(result.star_law.duplicate_member_edge);
    try testing.expect(!result.star_law.duplicate_leaf);
}

test "duplicate leaf and parallel members are both reported" {
    const members = [_]rs.RailClaimMember{
        outMember(1, 10, 20),
        outMember(2, 10, 20),
    };
    const result = rs.check(outClaim(&members));
    try testing.expect(result.star_law.duplicate_leaf);
    try testing.expect(result.star_law.parallel);
    try testing.expect(!result.star_law.antiparallel);
}

test "antiparallel members are detected without trusting pivot_end" {
    var reverse = outMember(2, 20, 10);
    reverse.pivot_end = .target;
    const members = [_]rs.RailClaimMember{ outMember(1, 10, 20), reverse };
    const result = rs.check(outClaim(&members));
    try testing.expect(result.star_law.antiparallel);
    try testing.expect(!result.star_law.no_common_real_pivot);
    try testing.expect(result.star_law.duplicate_leaf);
    try testing.expect(result.star_law.wrong_polarity_end);
}

test "self-loop and leaf equal to pivot remain separate facts" {
    const members = [_]rs.RailClaimMember{
        outMember(1, 10, 10),
        outMember(2, 10, 20),
    };
    const result = rs.check(outClaim(&members));
    try testing.expect(result.star_law.self_loop);
    try testing.expect(result.star_law.leaf_is_pivot);
}

test "differing or missing pi is derived from pivot-side member sites" {
    var differing = [_]rs.RailClaimMember{
        outMember(1, 10, 20),
        outMember(2, 10, 21),
    };
    differing[1].sites[0] = site(10, .south, 3);
    var result = rs.check(outClaim(&differing));
    try testing.expect(result.star_law.differing_or_missing_pi);
    try testing.expectEqual(@as(?rs.AttachmentSite, null), result.derived_pi);

    differing[1].sites[0] = null;
    result = rs.check(outClaim(&differing));
    try testing.expect(result.star_law.differing_or_missing_pi);
}

test "mixed pivot arrows occupy only the decoration partition" {
    var members = [_]rs.RailClaimMember{
        outMember(1, 10, 20),
        outMember(2, 10, 21),
    };
    members[1].arrows[0] = .circle;
    const result = rs.check(outClaim(&members));
    try testing.expect(result.decoration.mixed_pivot_decoration);
    try testing.expect(result.partition().decoration);
    try testing.expect(!result.partition().star_law);
    try testing.expect(!result.partition().style);
}

test "mixed stroke kinds occupy only the style partition" {
    var members = [_]rs.RailClaimMember{
        outMember(1, 10, 20),
        outMember(2, 10, 21),
    };
    members[1].kind = .dotted;
    const result = rs.check(outClaim(&members));
    try testing.expect(result.style.style_mismatch);
    try testing.expect(result.partition().style);
    try testing.expect(!result.partition().star_law);
    try testing.expect(!result.partition().decoration);
}

test "unresolved members are counted from final endpoints" {
    const members = [_]rs.RailClaimMember{
        outMember(1, 10, 20),
        outMember(2, null, 21),
    };
    const result = rs.check(outClaim(&members));
    try testing.expect(result.record.unresolved);
    try testing.expectEqual(@as(u32, 1), result.derived_unresolved_members);
    try testing.expect(result.star_law.no_common_real_pivot);
}

test "unresolved attachment sites count even when both endpoint nodes exist" {
    var members = [_]rs.RailClaimMember{
        outMember(1, 10, 20),
        outMember(2, 10, 21),
    };
    members[1].sites[1] = null;
    const result = rs.check(outClaim(&members));
    try testing.expect(result.record.unresolved);
    try testing.expectEqual(@as(u32, 1), result.derived_unresolved_members);

    members[1].sites[1] = site(99, .north, 1);
    const mismatched = rs.check(outClaim(&members));
    try testing.expect(mismatched.record.unresolved);
    try testing.expectEqual(@as(u32, 1), mismatched.derived_unresolved_members);
}

test "arity and sentinel identity invalidate otherwise coherent claims" {
    const members = [_]rs.RailClaimMember{outMember(1, 10, 20)};
    var claim = outClaim(&members);
    claim.id = rs.no_rail_claim;
    const result = rs.check(claim);
    try testing.expect(result.record.invalid_id);
    try testing.expect(result.record.arity);
    try testing.expect(!result.isValid());
    try testing.expect(result.partition().record);
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

test "a star of blocking members holds the licence" {
    const members = [_]rs.RailLicenceMember{
        licenceMember(1, 10, 20, .{ .none, .filled }),
        licenceMember(2, 10, 21, .{ .none, .filled }),
    };
    const result = rs.checkLicence(outLicence(&members));
    try testing.expect(result.isValid());
    try testing.expect(!result.star_law.non_blocking_member);
}

test "a member with directional ends on both sides blocks nothing and refuses the licence" {
    const members = [_]rs.RailLicenceMember{
        licenceMember(1, 10, 20, .{ .filled, .filled }),
        licenceMember(2, 10, 21, .{ .filled, .filled }),
    };
    const result = rs.checkLicence(outLicence(&members));
    try testing.expect(result.star_law.non_blocking_member);
    try testing.expect(!result.isValid());
}

test "a mixed blocking and arrow-free star refuses the licence" {
    const members = [_]rs.RailLicenceMember{
        licenceMember(1, 10, 20, .{ .none, .filled }),
        licenceMember(2, 10, 21, .{ .none, .none }),
    };
    const result = rs.checkLicence(outLicence(&members));
    try testing.expect(result.star_law.non_blocking_member);
    try testing.expect(!result.isValid());
}

test "an all-arrow-free star is not refused by the blocking predicate" {
    // the closure law's domain: rail_closure.zig decides it against the
    // declared leaf pairs; the star licence stays silent.
    const bare = [_]rs.RailLicenceMember{
        licenceMember(1, 10, 20, .{ .none, .none }),
        licenceMember(2, 10, 21, .{ .none, .none }),
    };
    try testing.expect(!rs.checkLicence(outLicence(&bare)).star_law.non_blocking_member);
    try testing.expect(rs.checkLicence(outLicence(&bare)).isValid());

    // Circle/cross ends are decoration, not directional: still arrow-free.
    const decorated = [_]rs.RailLicenceMember{
        licenceMember(1, 10, 20, .{ .none, .circle }),
        licenceMember(2, 10, 21, .{ .none, .circle }),
    };
    try testing.expect(!rs.checkLicence(outLicence(&decorated)).star_law.non_blocking_member);
}

test "a head at the source side alone still blocks under the licence" {
    const members = [_]rs.RailLicenceMember{
        licenceMember(1, 10, 20, .{ .filled, .none }),
        licenceMember(2, 10, 21, .{ .none, .filled }),
    };
    try testing.expect(!rs.checkLicence(outLicence(&members)).star_law.non_blocking_member);
}

test "a placement member standing for one-way crossings blocks like a headed member" {
    for ([_]prim.StandsFor{ .forward_one_way, .backward_one_way }) |class| {
        var proxy = licenceMember(3, 10, 22, .{ .none, .none });
        proxy.stands_for = class;
        const members = [_]rs.RailLicenceMember{
            licenceMember(1, 10, 20, .{ .none, .filled }),
            licenceMember(2, 10, 21, .{ .none, .filled }),
            proxy,
        };
        const result = rs.checkLicence(outLicence(&members));
        try testing.expect(!result.star_law.non_blocking_member);
    }
}

test "a placement member standing for non-forward directed ink refuses the licence" {
    var proxy = licenceMember(3, 10, 22, .{ .none, .none });
    proxy.stands_for = .directed;
    const members = [_]rs.RailLicenceMember{
        licenceMember(1, 10, 20, .{ .none, .filled }),
        licenceMember(2, 10, 21, .{ .none, .filled }),
        proxy,
    };
    const result = rs.checkLicence(outLicence(&members));
    try testing.expect(result.star_law.non_blocking_member);
    try testing.expect(!result.isValid());
}
