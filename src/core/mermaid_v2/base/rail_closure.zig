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
//! unlabeled edge of the members' own stroke class, and each declared edge
//! backing exactly one pair. That last clause is structural — a declaration
//! has two fixed endpoints, so it MATCHES exactly one unordered pair — and
//! the bijection here only stops two pairs of one rail sharing a declaration.
//! Partial salvage is preferred to outright refusal: the largest member
//! subset whose pairs are all declared keeps the rail, and the excluded
//! members fall back to private lanes.
//!
//! A kept rail then DISCHARGES its backing edges: the crossbar ink between
//! two taps IS the rendering of the pair edge, so drawing it again privately
//! would double the relation. `Verdict.discharges` names them; the caller
//! withholds them from routing.
//!
//! This predicate judges ONE proposed rail against the declarations around
//! it. Which of those declarations are still spendable, and which rail gets
//! to spend a pair when two of them assert it, is the caller's plan-wide
//! record — see `bundle_commit.reserve`.
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
    /// CLOSURE-LICENCE ELIGIBILITY: true iff no end of this member's ink is directional
    /// (sem_graph.arrowFree) — the blocking predicate is unsatisfiable, so
    /// the licence judges this rail. Circle/cross ends are non-directional and
    /// do not count here.
    arrow_free: bool,
    /// DISCHARGE qualification: true iff the member's ink carries no end
    /// decoration at all (sem_graph.undecorated). A decorated member is
    /// still inside the licence's domain via `arrow_free`, but no crossbar span
    /// can render its pair truthfully, so it can never be kept — it unfuses
    /// to a private stroke.
    undecorated: bool,
};

/// A candidate declared edge that could back one leaf pair. `a`/`b` are its
/// two endpoints in either order — the predicate compares pairs unordered.
pub const Backer = struct {
    edge: EdgeId,
    a: NodeId,
    b: NodeId,
    kind: u8,
    /// True iff the declaration carries NO end decoration at all
    /// (sem_graph.undecorated at the producers): the crossbar span that
    /// discharges it is undecorated, so a decorated declaration would have
    /// its decoration silently erased.
    undecorated: bool,
    unlabeled: bool,
};

/// One leaf pair and the declared edge whose rendering the rail's crossbar
/// takes over. `pair` is normalized low-id first.
pub const Discharge = struct {
    pair: [2]NodeId,
    backer: EdgeId,
};

pub const Outcome = enum {
    /// Not an all-arrow-free rail (some directional end, or fewer than two
    /// members): the blocking predicate is satisfiable, this licence says
    /// nothing, existing behavior stands. Decoration alone does NOT leave
    /// the domain — a circle/cross-decorated star is eligible and then
    /// refused for discharge.
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

/// Decide one proposed rail against the declarations the caller offers it.
/// @guarded-by: rail_closure_test.zig "an undeclared leaf pair refuses the rail"
pub fn decide(
    allocator: std.mem.Allocator,
    members: []const Member,
    backers: []const Backer,
) error{OutOfMemory}!Verdict {
    if (members.len < 2 or !allArrowFree(members)) return .{ .outcome = .untouched, .members = try edgeIds(allocator, members) };

    const full = try attempt(allocator, members, backers);
    if (full) |d| return .{
        .outcome = .keep,
        .members = try edgeIds(allocator, members),
        .discharges = d,
    };

    const undeclared = countUndeclared(members, backers);
    if (members.len > max_salvage_members) return .{ .outcome = .refuse, .undeclared_pairs = undeclared };

    // Salvage: the largest subset of two or more members whose pairs are all
    // declared. Subsets are enumerated by decreasing size and, within a size,
    // in ascending mask order — which reads as "prefer keeping the members the
    // caller listed first", the same canonical-order preference `forwardSubset`
    // applies. The first hit wins, so the answer never depends on edge-id
    // numbering.
    //
    // `compatible` is the cheap necessary condition: a subset can only close
    // if EVERY one of its pairs has some matching declaration at all. Testing
    // that with two bit operations rejects almost every mask without an
    // allocation, which is what keeps a wide undeclared rail (the worst case,
    // where nothing closes) from paying 2^n first-fit searches.
    // @guarded-by: rail_closure_test.zig "a wide rail with nothing declared refuses without searching every subset"
    const compatible = pairMatrix(members, backers);
    var widest: usize = 0;
    for (0..members.len) |i| widest = @max(widest, @popCount(compatible[i]));
    if (widest < 1) return .{ .outcome = .refuse, .undeclared_pairs = undeclared };
    var size: usize = @min(members.len - 1, widest + 1);
    while (size >= 2) : (size -= 1) {
        var mask: u32 = 0;
        const limit: u32 = @as(u32, 1) << @intCast(members.len);
        while (mask < limit) : (mask += 1) {
            if (@popCount(mask) != size or !maskCompatible(compatible, mask)) continue;
            const subset = try subsetOf(allocator, members, mask);
            defer allocator.free(subset);
            const d = try attempt(allocator, subset, backers) orelse continue;
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

/// Every unordered pair of `nodes` backed by a distinct usable declaration of
/// stroke class `kind`, or null when any pair is unbacked — THE kernel a rail
/// asks about the leaves its one continuous run welds together. Pairs are
/// visited in `nodes` order and each takes the FIRST usable backer, so the
/// bijection is deterministic. Repeated node ids are ignored (a node states no
/// pair with itself).
/// @guarded-by: rail_closure_test.zig "a run whose welded pairs are undeclared is not closed"
pub fn nodesClosed(
    allocator: std.mem.Allocator,
    nodes: []const NodeId,
    kind: u8,
    backers: []const Backer,
) error{OutOfMemory}!?[]const Discharge {
    var used: std.ArrayListUnmanaged(EdgeId) = .empty;
    defer used.deinit(allocator);
    var out: std.ArrayListUnmanaged(Discharge) = .empty;
    errdefer out.deinit(allocator);
    for (nodes, 0..) |x, i| {
        for (nodes[0..i]) |y| {
            if (x == y) continue;
            const b = findBacker(backers, kind, x, y, used.items) orelse {
                out.deinit(allocator);
                return null;
            };
            try used.append(allocator, b.edge);
            try out.append(allocator, .{ .pair = normalize(y, x), .backer = b.edge });
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Every leaf pair backed by a distinct usable declared edge, or null when
/// any pair is unbacked.
fn attempt(
    allocator: std.mem.Allocator,
    members: []const Member,
    backers: []const Backer,
) error{OutOfMemory}!?[]const Discharge {
    for (members) |m| {
        if (!m.undecorated) return null;
    }
    for (members[1..]) |m| {
        if (m.kind != members[0].kind) return null;
    }
    const leaves = try allocator.alloc(NodeId, members.len);
    defer allocator.free(leaves);
    for (members, leaves) |m, *slot| slot.* = m.leaf;
    return nodesClosed(allocator, leaves, members[0].kind, backers);
}

/// Bit `j` of row `i`: members `i` and `j` state a pair SOME declaration could
/// back (or state no pair at all). Reuse across subsets is not modeled — this
/// is a necessary condition only, so a mask it admits still runs the first-fit
/// bijection.
fn pairMatrix(members: []const Member, backers: []const Backer) [max_salvage_members]u32 {
    var rows: [max_salvage_members]u32 = @splat(0);
    for (members, 0..) |m, i| {
        for (members[0..i], 0..) |n, j| {
            const ok = m.leaf == n.leaf or findBacker(backers, m.kind, m.leaf, n.leaf, &.{}) != null;
            if (!m.undecorated or !n.undecorated or m.kind != n.kind or !ok) continue;
            rows[i] |= @as(u32, 1) << @intCast(j);
            rows[j] |= @as(u32, 1) << @intCast(i);
        }
    }
    return rows;
}

fn maskCompatible(rows: [max_salvage_members]u32, mask: u32) bool {
    var rest = mask;
    while (rest != 0) {
        const bit = @ctz(rest);
        rest &= rest - 1;
        const others = mask & ~(@as(u32, 1) << @intCast(bit));
        if (others & ~rows[bit] != 0) return false;
    }
    return true;
}

/// Leaf pairs of the full member set that no usable backer covers, counted
/// under the same first-fit bijection `attempt` applies.
fn countUndeclared(members: []const Member, backers: []const Backer) u32 {
    var used_buf: [max_salvage_members * max_salvage_members]EdgeId = undefined;
    var used_n: usize = 0;
    var missing: u32 = 0;
    for (members, 0..) |m, i| {
        for (members[0..i]) |n| {
            if (m.leaf == n.leaf) continue;
            if (m.kind != n.kind or !m.undecorated or !n.undecorated) {
                missing += 1;
                continue;
            }
            const backer = findBacker(backers, m.kind, m.leaf, n.leaf, used_buf[0..used_n]) orelse {
                missing += 1;
                continue;
            };
            if (used_n < used_buf.len) {
                used_buf[used_n] = backer.edge;
                used_n += 1;
            }
        }
    }
    return missing;
}

/// The first declared edge that matches this pair on every clause: same
/// unordered endpoints, the asking run's own stroke class, undecorated,
/// unlabeled, and not already spent on another pair of this same run.
fn findBacker(
    backers: []const Backer,
    kind: u8,
    x: NodeId,
    y: NodeId,
    used: []const EdgeId,
) ?Backer {
    for (backers) |b| {
        if (!samePair(b, x, y)) continue;
        if (b.kind != kind or !b.undecorated or !b.unlabeled) continue;
        if (contains(used, b.edge)) continue;
        return b;
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
/// `co_double_discharge` inventory. A discharged edge is rendered by the
/// rail's crossbar; a second, private rendering would state its relation
/// twice, so this must stay zero.
/// @guarded-by: rail_closure_test.zig "a discharged edge that still routes privately is a double discharge"
pub fn doubleDischarged(discharged: []const EdgeId, routed: []const EdgeId) u32 {
    var n: u32 = 0;
    for (discharged) |edge| {
        if (contains(routed, edge)) n += 1;
    }
    return n;
}
