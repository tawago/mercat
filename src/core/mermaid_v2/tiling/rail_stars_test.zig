//! Tests for the lattice-only semantic rail-star tier.

const std = @import("std");
const prim = @import("prim");
const ledger = @import("../base/ledger.zig");
const lattice = @import("../lattice.zig");
const counts = @import("counts.zig");
const rail_stars = @import("rail_stars.zig");

const testing = std.testing;

fn site(node: u32, side: prim.Dir4, offset: u32) ledger.AttachmentSite {
    return .{ .node = node, .side = side, .offset = offset };
}

fn outMember(edge: u32, pivot: ?u32, leaf: ?u32) ledger.RailClaimMember {
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

fn inMember(edge: u32, leaf: u32, pivot: u32) ledger.RailClaimMember {
    return .{
        .edge = edge,
        .endpoints = .{ leaf, pivot },
        .sites = .{ site(leaf, .south, 1), site(pivot, .north, 2) },
        .arrows = .{ .none, .filled },
        .kind = .solid,
        .pivot_end = .target,
    };
}

fn outClaim(id: u32, members: []const ledger.RailClaimMember) ledger.RailClaim {
    return .{ .id = id, .polarity = .out, .members = members };
}

fn inClaim(id: u32, members: []const ledger.RailClaimMember) ledger.RailClaim {
    return .{ .id = id, .polarity = .in, .members = members };
}

fn audit(claims: []const ledger.RailClaim) counts.Counts {
    const lat: lattice.Lattice = .{ .width = 0, .height = 0, .cells = &.{}, .rail_claims = claims };
    var c: counts.Counts = .{};
    rail_stars.check(&lat, &c);
    return c;
}

fn expectEquations(claims: []const ledger.RailClaim, c: counts.Counts) !void {
    var members: u32 = 0;
    var valid: u32 = 0;
    var bnd: u32 = 0;
    var decoration: u32 = 0;
    var style: u32 = 0;
    var unresolved: u32 = 0;
    var record_invalid: u32 = 0;
    for (claims) |claim| {
        members += @intCast(claim.members.len);
        const result = ledger.checkRailClaim(claim);
        const failed = result.partition();
        if (!failed.any()) valid += 1;
        if (failed.bnd_s) bnd += 1;
        if (failed.decoration) decoration += 1;
        if (failed.style) style += 1;
        if (failed.record) {
            if (result.record.unresolved) unresolved += 1 else record_invalid += 1;
        }
    }
    try testing.expectEqual(@as(u32, @intCast(claims.len)), c.n_rail_claims);
    try testing.expectEqual(members, c.n_rail_claim_members);
    try testing.expectEqual(valid, c.c_rail_star_valid);
    try testing.expectEqual(bnd, c.d_rail_star_violation);
    try testing.expectEqual(decoration, c.d_rail_deco_mixed);
    try testing.expectEqual(style, c.d_rail_member_style_mixed);
    try testing.expectEqual(unresolved, c.u_rail_claim_unresolved);
    try testing.expectEqual(record_invalid, c.u_rail_claim_record_invalid);
}

test "rail stars: valid fan-out and fan-in claims publish exact populations" {
    const out_members = [_]ledger.RailClaimMember{ outMember(1, 10, 20), outMember(2, 10, 21) };
    const in_members = [_]ledger.RailClaimMember{ inMember(3, 30, 10), inMember(4, 31, 10) };
    const claims = [_]ledger.RailClaim{ outClaim(1, &out_members), inClaim(2, &in_members) };
    const c = audit(&claims);
    try testing.expectEqual(@as(u32, 2), c.n_rail_claims);
    try testing.expectEqual(@as(u32, 4), c.n_rail_claim_members);
    try testing.expectEqual(@as(u32, 2), c.c_rail_star_valid);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try expectEquations(&claims, c);
}

test "rail stars: BND-S shapes count once per claim, not once per failed clause" {
    const duplicate = [_]ledger.RailClaimMember{ outMember(1, 10, 20), outMember(2, 10, 20) };
    var reverse = outMember(4, 20, 10);
    reverse.pivot_end = .target;
    const antiparallel = [_]ledger.RailClaimMember{ outMember(3, 10, 20), reverse };
    const self_loop = [_]ledger.RailClaimMember{ outMember(5, 10, 10), outMember(6, 10, 21) };
    const many_pivots = [_]ledger.RailClaimMember{ outMember(7, 10, 22), outMember(8, 11, 23) };
    const claims = [_]ledger.RailClaim{
        outClaim(1, &duplicate),
        outClaim(2, &antiparallel),
        outClaim(3, &self_loop),
        outClaim(4, &many_pivots),
    };
    const c = audit(&claims);
    try testing.expectEqual(@as(u32, 4), c.d_rail_star_violation);
    try testing.expectEqual(@as(u32, 0), c.c_rail_star_valid);
    try expectEquations(&claims, c);
}

test "rail stars: wrong polarity and differing pi are BND-S, not record limitations" {
    var wrong_members = [_]ledger.RailClaimMember{ outMember(1, 10, 20), outMember(2, 10, 21) };
    wrong_members[1].pivot_end = .target;
    wrong_members[0].sites[0] = site(10, .south, 3);
    const sound_members = [_]ledger.RailClaimMember{ outMember(3, 10, 30), outMember(4, 10, 31) };
    const claims = [_]ledger.RailClaim{ outClaim(1, &wrong_members), outClaim(2, &sound_members) };
    const c = audit(&claims);
    try testing.expectEqual(@as(u32, 1), c.d_rail_star_violation);
    try testing.expectEqual(@as(u32, 0), c.u_rail_claim_record_invalid);
    try testing.expectEqual(@as(u32, 1), c.c_rail_star_valid);
    try expectEquations(&claims, c);
}

test "rail stars: decoration and style remain separate from BND-S" {
    var decorated = [_]ledger.RailClaimMember{ outMember(1, 10, 20), outMember(2, 10, 21) };
    decorated[1].arrows[0] = .circle;
    var styled = [_]ledger.RailClaimMember{ outMember(3, 10, 30), outMember(4, 10, 31) };
    styled[1].kind = .dotted;
    var both = [_]ledger.RailClaimMember{ outMember(5, 10, 40), outMember(6, 10, 41) };
    both[1].arrows[0] = .open;
    both[1].kind = .thick;
    const claims = [_]ledger.RailClaim{ outClaim(1, &decorated), outClaim(2, &styled), outClaim(3, &both) };
    const c = audit(&claims);
    try testing.expectEqual(@as(u32, 0), c.d_rail_star_violation);
    try testing.expectEqual(@as(u32, 2), c.d_rail_deco_mixed);
    try testing.expectEqual(@as(u32, 2), c.d_rail_member_style_mixed);
    try testing.expectEqual(@as(u32, 0), c.c_rail_star_valid);
    try expectEquations(&claims, c);
}

test "rail stars: unresolved claims are limitations and never false-valid" {
    const members = [_]ledger.RailClaimMember{ outMember(1, 10, 20), outMember(2, null, 21) };
    const claim = outClaim(1, &members);
    const c = audit(&.{claim});
    try testing.expectEqual(@as(u32, 1), c.u_rail_claim_unresolved);
    try testing.expectEqual(@as(u32, 0), c.u_rail_claim_record_invalid);
    try testing.expectEqual(@as(u32, 0), c.c_rail_star_valid);
    try testing.expectEqual(@as(u32, 1), c.d_rail_star_violation);
    try expectEquations(&.{claim}, c);
}

test "rail stars: invalid identity and arity use the record limitation" {
    const members = [_]ledger.RailClaimMember{outMember(1, 10, 20)};
    const claim = outClaim(ledger.no_rail_claim, &members);
    const c = audit(&.{claim});
    try testing.expectEqual(@as(u32, 1), c.u_rail_claim_record_invalid);
    try testing.expectEqual(@as(u32, 0), c.c_rail_star_valid);
    try expectEquations(&.{claim}, c);
}

test "rail stars: absent population is named even on a zero-size lattice" {
    const c = audit(&.{});
    try testing.expectEqual(@as(u32, 0), c.n_rail_claims);
    try testing.expectEqual(@as(u32, 1), c.u_rail_claim_population_absent);
}

test "rail stars: metadata changes neither cell bytes nor the cells slice" {
    const members = [_]ledger.RailClaimMember{ outMember(1, 10, 20), outMember(2, 10, 21) };
    const claims = [_]ledger.RailClaim{outClaim(1, &members)};
    var cells = [_]lattice.Cell{.{
        .occupant = .{ .edge_segment = .{ .edge = 1, .kind = .solid } },
        .neighbours = .{ .e = true, .w = true },
    }};
    const before = cells;
    var lat: lattice.Lattice = .{ .width = 1, .height = 1, .cells = &cells, .rail_claims = &claims };
    const ptr = lat.cells.ptr;
    var c: counts.Counts = .{};
    rail_stars.check(&lat, &c);
    lat.rail_claims = &.{};
    try testing.expectEqual(ptr, lat.cells.ptr);
    try testing.expectEqualSlices(lattice.Cell, &before, lat.cells);
}

test "rail stars: AUX state cannot change claim counts" {
    const members = [_]ledger.RailClaimMember{ outMember(1, 10, 20), outMember(2, 10, 21) };
    const claims = [_]ledger.RailClaim{outClaim(1, &members)};
    var cells = [_]lattice.Cell{lattice.Cell.empty};
    var lat: lattice.Lattice = .{ .width = 1, .height = 1, .cells = &cells, .rail_claims = &claims };
    var baseline: ?counts.Counts = null;
    for ([_]lattice.AuxCollectionState{ .not_collected, .complete, .out_of_memory }) |state| {
        lat.aux_collection = .{ .state = state, .attempted_records = 7 };
        var c: counts.Counts = .{};
        rail_stars.check(&lat, &c);
        if (baseline) |want| {
            try testing.expectEqual(want.n_rail_claims, c.n_rail_claims);
            try testing.expectEqual(want.n_rail_claim_members, c.n_rail_claim_members);
            try testing.expectEqual(want.c_rail_star_valid, c.c_rail_star_valid);
        } else baseline = c;
    }
}
