//! rail_closure.zig — THE all-arrow-free shared-rail legality predicate.
//!
//! A shared rail asserts MORE than its own members. Its members are spokes
//! from one pivot to N leaves, but the crossbar that carries them is one
//! continuous run: a reader tracing ink from leaf A along the crossbar
//! reaches leaf B without ever passing through the pivot, so the picture
//! states an A—B connection for EVERY unordered leaf pair.
//!
//! When the members carry arrowheads that reading is blocked — the ink is
//! directed and a leaf-to-leaf trace runs against an arrow. When EVERY
//! member is arrow-free there is nothing to block it, and the rail's extra
//! assertions are indistinguishable from its declared ones. Fusing such a
//! rail over an undeclared leaf pair is fabrication.
//!
//! So an all-arrow-free rail may fuse only when the source graph DECLARES
//! every leaf pair it would assert: for each unordered pair one arrow-free,
//! unlabeled edge of the members' own stroke class, each declared edge
//! backing exactly one pair, and no declared edge backing pairs in two
//! rails plan-wide (the caller passes what earlier rails already took as
//! `unavailable`). Partial salvage is preferred to outright refusal: the
//! largest member subset whose pairs are all declared keeps the rail, and
//! the excluded members fall back to private lanes.
//!
//! A kept rail then DISCHARGES its backing edges: the crossbar ink between
//! two taps IS the rendering of the pair edge, so drawing it again privately
//! would double the relation. `Verdict.discharges` names them; the caller
//! withholds them from routing.
//!
//! Pure data + pure functions; imports only std. Own input types (no IR
//! type crosses this boundary) so all three call sites — the flat pre-sizing
//! commitment, the clustered lane pass, and the tests — project into one
//! vocabulary. Universally importable (base/ no-deps tier).
//! Tests live in rail_closure_test.zig, aggregated from entry.zig.

const std = @import("std");

/// Structurally the ledger's own handles; redeclared so this file never
/// closes an import loop back through ledger.zig.
pub const NodeId = u32;
pub const EdgeId = u32;

/// One member of the proposed rail: the spoke edge and the LEAF it lands on
/// (the endpoint that is not the pivot).
pub const Member = struct {
    edge: EdgeId,
    leaf: NodeId,
    /// Stroke-class ordinal (`pb.edgeKindOrdinal`). A backer must match it.
    kind: u8,
    /// True iff NEITHER end of this member carries an arrowhead.
    arrow_free: bool,
};

/// A candidate declared edge that could back one leaf pair. `a`/`b` are its
/// two endpoints in either order — the predicate compares pairs unordered.
pub const Backer = struct {
    edge: EdgeId,
    a: NodeId,
    b: NodeId,
    kind: u8,
    arrow_free: bool,
    unlabeled: bool,
};

/// One leaf pair and the declared edge whose rendering the rail's crossbar
/// takes over. `pair` is normalized low-id first.
pub const Discharge = struct {
    pair: [2]NodeId,
    backer: EdgeId,
};

pub const Outcome = enum {
    /// Not an all-arrow-free rail (directed, mixed, or fewer than two
    /// members): this law says nothing, existing behavior stands.
    untouched,
    /// Every leaf pair of the full member set is declared — fuse as proposed.
    keep,
    /// A strict subset (>= 2 members) has all its pairs declared — fuse over
    /// the remainder; the excluded members route privately.
    salvage,
    /// No subset of two or more members is fully declared — do not fuse.
    refuse,
};

pub const Verdict = struct {
    outcome: Outcome,
    /// The members the rail keeps, in the caller's input order. Equal to the
    /// whole input on `.untouched`/`.keep`, a strict subset on `.salvage`,
    /// empty on `.refuse`.
    members: []const EdgeId = &.{},
    /// Declared pair edges the kept rail discharges. Empty unless the
    /// outcome is `.keep` or `.salvage`.
    discharges: []const Discharge = &.{},
    /// Leaf pairs of the FULL proposed member set with no usable backing —
    /// the `co_undeclared` inventory. Counted before salvage, so it measures
    /// the rail as proposed.
    undeclared_pairs: u32 = 0,
};

/// Above this member count the exhaustive salvage search is skipped and an
/// unbacked rail is refused outright. A fully declared clique needs
/// n*(n-1)/2 extra edges, so a rail this wide is not a real input; the cap
/// keeps the subset enumeration bounded (2^16 worst case).
pub const max_salvage_members: usize = 16;

/// Decide one proposed rail. `unavailable` lists edge ids that may NOT back a
/// pair here — already taken by another rail, or drawn as a member of one.
/// guarded-by: rail_closure_test.zig "an undeclared leaf pair refuses the rail"
pub fn decide(
    allocator: std.mem.Allocator,
    members: []const Member,
    backers: []const Backer,
    unavailable: []const EdgeId,
) error{OutOfMemory}!Verdict {
    if (members.len < 2 or !allArrowFree(members)) return .{ .outcome = .untouched, .members = try edgeIds(allocator, members) };

    const full = try attempt(allocator, members, backers, unavailable);
    if (full) |d| return .{
        .outcome = .keep,
        .members = try edgeIds(allocator, members),
        .discharges = d,
    };

    const undeclared = countUndeclared(members, backers, unavailable);
    if (members.len > max_salvage_members) return .{ .outcome = .refuse, .undeclared_pairs = undeclared };

    // Salvage: the largest subset of two or more members whose pairs are all
    // declared. Subsets are enumerated by decreasing size and, within a size,
    // in ascending mask order — which reads as "prefer keeping the members the
    // caller listed first", the same canonical-order preference `forwardSubset`
    // applies. The first hit wins, so the answer never depends on edge-id
    // numbering.
    var size: usize = members.len - 1;
    while (size >= 2) : (size -= 1) {
        var mask: u32 = 0;
        const limit: u32 = @as(u32, 1) << @intCast(members.len);
        while (mask < limit) : (mask += 1) {
            if (@popCount(mask) != size) continue;
            const subset = try subsetOf(allocator, members, mask);
            defer allocator.free(subset);
            const d = try attempt(allocator, subset, backers, unavailable) orelse continue;
            return .{
                .outcome = .salvage,
                .members = try edgeIds(allocator, subset),
                .discharges = d,
                .undeclared_pairs = undeclared,
            };
        }
    }
    return .{ .outcome = .refuse, .undeclared_pairs = undeclared };
}

/// Every leaf pair backed by a distinct usable declared edge, or null when
/// any pair is unbacked. Pairs are visited in member order and each takes the
/// FIRST usable backer, so the bijection is deterministic.
fn attempt(
    allocator: std.mem.Allocator,
    members: []const Member,
    backers: []const Backer,
    unavailable: []const EdgeId,
) error{OutOfMemory}!?[]const Discharge {
    var used: std.ArrayListUnmanaged(EdgeId) = .empty;
    defer used.deinit(allocator);
    var out: std.ArrayListUnmanaged(Discharge) = .empty;
    errdefer out.deinit(allocator);
    for (members, 0..) |m, i| {
        for (members[0..i]) |n| {
            // Two members landing on ONE leaf state no leaf-to-leaf pair; the
            // duplicate-member gates own that case.
            if (m.leaf == n.leaf) continue;
            const backer = findBacker(backers, m, n, unavailable, used.items) orelse {
                out.deinit(allocator);
                return null;
            };
            try used.append(allocator, backer);
            try out.append(allocator, .{ .pair = normalize(n.leaf, m.leaf), .backer = backer });
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Leaf pairs of the full member set that no usable backer covers, counted
/// under the same first-fit bijection `attempt` applies.
fn countUndeclared(members: []const Member, backers: []const Backer, unavailable: []const EdgeId) u32 {
    var used_buf: [max_salvage_members * max_salvage_members]EdgeId = undefined;
    var used_n: usize = 0;
    var missing: u32 = 0;
    for (members, 0..) |m, i| {
        for (members[0..i]) |n| {
            if (m.leaf == n.leaf) continue;
            const backer = findBacker(backers, m, n, unavailable, used_buf[0..used_n]) orelse {
                missing += 1;
                continue;
            };
            if (used_n < used_buf.len) {
                used_buf[used_n] = backer;
                used_n += 1;
            }
        }
    }
    return missing;
}

/// The first declared edge that matches this leaf pair on every clause:
/// same unordered endpoints, the members' own stroke class, arrow-free,
/// unlabeled, not withheld by the caller, not already spent on another pair.
fn findBacker(
    backers: []const Backer,
    first: Member,
    second: Member,
    unavailable: []const EdgeId,
    used: []const EdgeId,
) ?EdgeId {
    // Members of one rail always share a stroke class (the style gate runs
    // first), so either member's kind names the class the backer must match.
    if (first.kind != second.kind) return null;
    for (backers) |b| {
        if (!samePair(b, first.leaf, second.leaf)) continue;
        if (b.kind != first.kind or !b.arrow_free or !b.unlabeled) continue;
        if (contains(unavailable, b.edge) or contains(used, b.edge)) continue;
        return b.edge;
    }
    return null;
}

fn samePair(b: Backer, x: NodeId, y: NodeId) bool {
    return (b.a == x and b.b == y) or (b.a == y and b.b == x);
}

fn allArrowFree(members: []const Member) bool {
    for (members) |m| {
        if (!m.arrow_free) return false;
    }
    return true;
}

fn normalize(x: NodeId, y: NodeId) [2]NodeId {
    return if (x <= y) .{ x, y } else .{ y, x };
}

fn subsetOf(allocator: std.mem.Allocator, members: []const Member, mask: u32) error{OutOfMemory}![]Member {
    const out = try allocator.alloc(Member, @popCount(mask));
    var i: usize = 0;
    for (members, 0..) |m, bit| {
        if (mask & (@as(u32, 1) << @intCast(bit)) == 0) continue;
        out[i] = m;
        i += 1;
    }
    return out;
}

fn edgeIds(allocator: std.mem.Allocator, members: []const Member) error{OutOfMemory}![]const EdgeId {
    const out = try allocator.alloc(EdgeId, members.len);
    for (members, out) |m, *slot| slot.* = m.edge;
    return out;
}

pub fn contains(edges: []const EdgeId, edge: EdgeId) bool {
    for (edges) |e| {
        if (e == edge) return true;
    }
    return false;
}

/// How many discharged edges ALSO own private geometry — the
/// `co_double_discharge` inventory. A co-realized edge is rendered by the
/// rail's crossbar; a second, private rendering would state its relation
/// twice, so this must stay zero.
/// guarded-by: rail_closure_test.zig "a discharged edge that still routes privately is a double discharge"
pub fn doubleDischarged(co_realized: []const EdgeId, routed: []const EdgeId) u32 {
    var n: u32 = 0;
    for (co_realized) |edge| {
        if (contains(routed, edge)) n += 1;
    }
    return n;
}
