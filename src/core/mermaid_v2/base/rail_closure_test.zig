//! Tests for base/rail_closure.zig — the all-arrow-free shared-rail closure
//! law. Aggregated from entry.zig's test block (base/ files keep their empty
//! import allowlist).

const std = @import("std");
const testing = std.testing;
const rc = @import("rail_closure.zig");

const solid: u8 = 0;
const dotted: u8 = 1;

fn member(edge: u32, leaf: u32) rc.Member {
    return .{ .edge = edge, .leaf = leaf, .kind = solid, .arrow_free = true };
}

fn directedMember(edge: u32, leaf: u32) rc.Member {
    return .{ .edge = edge, .leaf = leaf, .kind = solid, .arrow_free = false };
}

fn backer(edge: u32, a: u32, b: u32) rc.Backer {
    return .{ .edge = edge, .a = a, .b = b, .kind = solid, .arrow_free = true, .unlabeled = true };
}

fn decide(members: []const rc.Member, backers: []const rc.Backer, unavailable: []const u32) !rc.Verdict {
    return rc.decide(testing.allocator, members, backers, unavailable);
}

fn free(v: rc.Verdict) void {
    if (v.members.len != 0) testing.allocator.free(v.members);
    if (v.discharges.len != 0) testing.allocator.free(v.discharges);
}

test "an undeclared leaf pair refuses the rail" {
    // A---Z, B---Z, C---Z with nothing declared between the leaves: the
    // crossbar would assert A—B, A—C and B—C, none of them declared.
    const members = [_]rc.Member{ member(0, 1), member(1, 2), member(2, 3) };
    const v = try decide(&members, &.{}, &.{});
    defer free(v);
    try testing.expectEqual(rc.Outcome.refuse, v.outcome);
    try testing.expectEqual(@as(usize, 0), v.members.len);
    try testing.expectEqual(@as(u32, 3), v.undeclared_pairs);
}

test "a fully declared clique keeps the rail and discharges every pair edge" {
    const members = [_]rc.Member{ member(0, 1), member(1, 2), member(2, 3) };
    const backers = [_]rc.Backer{ backer(10, 1, 2), backer(11, 1, 3), backer(12, 2, 3) };
    const v = try decide(&members, &backers, &.{});
    defer free(v);
    try testing.expectEqual(rc.Outcome.keep, v.outcome);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, v.members);
    try testing.expectEqual(@as(usize, 3), v.discharges.len);
    try testing.expectEqual(@as(u32, 0), v.undeclared_pairs);
    // Every declared pair edge is discharged exactly once — the bijection.
    var seen = [_]bool{ false, false, false };
    for (v.discharges) |d| seen[d.backer - 10] = true;
    for (seen) |s| try testing.expect(s);
}

test "a backing edge is matched on unordered endpoints" {
    // The declaration reads B---A while the rail's leaves are visited A then
    // B: a pair is a PAIR, not an ordered arc.
    const members = [_]rc.Member{ member(0, 1), member(1, 2) };
    const backers = [_]rc.Backer{backer(10, 2, 1)};
    const v = try decide(&members, &backers, &.{});
    defer free(v);
    try testing.expectEqual(rc.Outcome.keep, v.outcome);
    try testing.expectEqual(@as(u32, 10), v.discharges[0].backer);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, &v.discharges[0].pair);
}

test "a decorated, labeled or wrong-stroke declaration backs nothing" {
    const members = [_]rc.Member{ member(0, 1), member(1, 2) };
    var arrowed = backer(10, 1, 2);
    arrowed.arrow_free = false;
    var labeled = backer(11, 1, 2);
    labeled.unlabeled = false;
    var mismatched = backer(12, 1, 2);
    mismatched.kind = dotted;
    inline for ([3]rc.Backer{ arrowed, labeled, mismatched }) |b| {
        const v = try decide(&members, &[_]rc.Backer{b}, &.{});
        defer free(v);
        try testing.expectEqual(rc.Outcome.refuse, v.outcome);
        try testing.expectEqual(@as(u32, 1), v.undeclared_pairs);
    }
}

test "one declaration cannot back two pairs of the same rail" {
    // Three leaves, one declaration: the first pair spends it and the other
    // two pairs find nothing, so no size-3 rail and no size-2 salvage that
    // needs a second backer.
    const members = [_]rc.Member{ member(0, 1), member(1, 2), member(2, 3) };
    const backers = [_]rc.Backer{backer(10, 1, 2)};
    const v = try decide(&members, &backers, &.{});
    defer free(v);
    try testing.expectEqual(rc.Outcome.salvage, v.outcome);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, v.members);
    try testing.expectEqual(@as(usize, 1), v.discharges.len);
    try testing.expectEqual(@as(u32, 2), v.undeclared_pairs);
}

test "a declaration another rail already took is unavailable here" {
    const members = [_]rc.Member{ member(0, 1), member(1, 2) };
    const backers = [_]rc.Backer{backer(10, 1, 2)};
    const taken = try decide(&members, &backers, &[_]u32{10});
    defer free(taken);
    try testing.expectEqual(rc.Outcome.refuse, taken.outcome);
    const fresh = try decide(&members, &backers, &.{});
    defer free(fresh);
    try testing.expectEqual(rc.Outcome.keep, fresh.outcome);
}

test "salvage keeps the largest fully declared subset, earliest members first" {
    // Four leaves; only the (1,2) and (1,3) and (2,3) triangle is declared, so
    // the leaf-4 member must go and the remaining three fuse.
    const members = [_]rc.Member{ member(0, 1), member(1, 2), member(2, 3), member(3, 4) };
    const backers = [_]rc.Backer{ backer(10, 1, 2), backer(11, 1, 3), backer(12, 2, 3) };
    const v = try decide(&members, &backers, &.{});
    defer free(v);
    try testing.expectEqual(rc.Outcome.salvage, v.outcome);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, v.members);
    try testing.expectEqual(@as(usize, 3), v.discharges.len);
}

test "a directed or mixed rail is untouched by this law" {
    const directed = [_]rc.Member{ directedMember(0, 1), directedMember(1, 2) };
    const v = try decide(&directed, &.{}, &.{});
    defer free(v);
    try testing.expectEqual(rc.Outcome.untouched, v.outcome);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, v.members);

    const mixed = [_]rc.Member{ member(0, 1), directedMember(1, 2) };
    const w = try decide(&mixed, &.{}, &.{});
    defer free(w);
    try testing.expectEqual(rc.Outcome.untouched, w.outcome);
}

test "a rail with fewer than two members has no pairs to declare" {
    const one = [_]rc.Member{member(0, 1)};
    const v = try decide(&one, &.{}, &.{});
    defer free(v);
    try testing.expectEqual(rc.Outcome.untouched, v.outcome);
}

test "two members landing on one leaf state no leaf-to-leaf pair" {
    // A duplicate arrival (both members reach leaf 1) asserts nothing between
    // distinct leaves, so the law neither demands a declaration nor refuses.
    const members = [_]rc.Member{ member(0, 1), member(1, 1) };
    const v = try decide(&members, &.{}, &.{});
    defer free(v);
    try testing.expectEqual(rc.Outcome.keep, v.outcome);
    try testing.expectEqual(@as(usize, 0), v.discharges.len);
}

test "the verdict does not depend on the order declarations were listed" {
    const members = [_]rc.Member{ member(0, 1), member(1, 2), member(2, 3) };
    const forward = [_]rc.Backer{ backer(10, 1, 2), backer(11, 1, 3), backer(12, 2, 3) };
    const reverse = [_]rc.Backer{ backer(12, 2, 3), backer(11, 1, 3), backer(10, 1, 2) };
    const x = try decide(&members, &forward, &.{});
    defer free(x);
    const y = try decide(&members, &reverse, &.{});
    defer free(y);
    try testing.expectEqual(x.outcome, y.outcome);
    try testing.expectEqualSlices(u32, x.members, y.members);
    try testing.expectEqual(x.discharges.len, y.discharges.len);
}

test "a discharged edge that still routes privately is a double discharge" {
    try testing.expectEqual(@as(u32, 0), rc.doubleDischarged(&.{ 10, 11 }, &.{ 0, 1, 2 }));
    try testing.expectEqual(@as(u32, 1), rc.doubleDischarged(&.{ 10, 11 }, &.{ 0, 10 }));
    try testing.expectEqual(@as(u32, 2), rc.doubleDischarged(&.{ 10, 11 }, &.{ 11, 10 }));
}
