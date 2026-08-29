//! Bundle membership vocabulary (D-IR item 4's companion record): the
//! sets of edges that legally share ink because ONE structural decision put
//! them on the same bundle, plus the cell coordinate a narrowed set scopes
//! itself to.
//!
//! Split out of base/ledger.zig, which sat exactly at the mermaid_v2
//! 500-line cap. ledger.zig re-exports every symbol here, so existing
//! `pb.Bundle` / `pb.bundleMembers` / `pb.bundlesFromPlan` call sites are
//! source-compatible and type-identical.
//!
//! Pure data + pure functions; imports only base siblings. Universally
//! importable (base/ no-deps tier). Tests live in ledger_test.zig.

const std = @import("std");

/// Structurally the ledger's own handle (`pb.EdgeId`); redeclared rather than
/// imported so this file never closes an import loop back through ledger.zig.
/// guarded-by: ledger_test.zig "identity handles match prim's"
const EdgeId = u32;

/// Where a bundle set came from. Provenance only: every reader treats
/// the origins alike, and the tag exists so a set can be attributed in a
/// report and so a later law can scope itself to one origin.
pub const BundleOrigin = enum {
    /// One realized selected bundle (`RealizedBundles.selected_bundles`).
    selected_bundle,
    /// One fan's peers sharing a rail lane (layout/fan.zig). The population
    /// a sketch has where no plan realized: motif-packed candidates and
    /// plan-failure renders. A clustered render's pieces realize their own
    /// plans and their `selected_bundle` sets ride the stitch (V-D-IR-07).
    fan_rail,
    /// Edges a producer deliberately routed through ONE perimeter port, so
    /// their approach ink is one run (`sketch_ports.portShareBundles`). Derived
    /// from the sketch's own declared polylines — the producers' agreement on
    /// a coordinate IS the declaration — and always APPENDED to the sets the
    /// other origins contributed, never substituted for them.
    port_share,
};

/// Identity of ONE bundle, in the id space of the Sketch that holds it.
///
/// A bundle is what a bundle IS: the one structural decision that put a
/// group of edges on one run. Until this handle existed the decision had no
/// NAME, so every reader that wanted "do these two share a bundle here"
/// re-derived the relation by scanning both membership lists at the point of
/// decision. The id is the name, `bundleOf` is the lookup, and the relation
/// is read off two lookups instead of recomputed — the direction of
/// derivation inverts.
pub const BundleId = u32;

/// "NOT FILED" — never "no bundle". Zero on purpose, the same rule the side
/// table's `detail` bytes follow: an unstamped set, a hand-built fixture and a
/// stale copy all land here, on the value that names nothing, so silence can
/// never be read back as identity.
pub const no_bundle: BundleId = 0;

/// Base of the PRIVATE band: the bundle an edge that shares with nobody
/// rides. Every edge is on a bundle — a bundle names a SHARED one, and an
/// edge no set names still has its own, which is exactly one edge wide. Held
/// apart from the roster band (1..N, one per set) by the high bit, so a
/// private id can never collide with a set's however long the roster grows.
/// Edge ids are `u32` handles well under 2^31 in every producer.
pub const private_band: BundleId = 0x8000_0000;

/// The one-edge-wide bundle `edge` rides when no set names it here.
pub fn privateBundle(edge: EdgeId) BundleId {
    return private_band | edge;
}

/// A CO-CHANNEL set: edges that legally share ink because ONE structural
/// decision put them on the same bundle.
///
/// Membership is an EXPLICIT edge-id list; `bundle` is that membership's
/// NAME, not a substitute for it — the list stays the authority on WHO, the
/// id answers WHICH. Ids
/// are read in the id space of the Sketch that holds the set: a set built
/// inside a recursion child is rewritten by `cluster/stitch.zig` into the
/// merged Sketch's single, globally unique edge-id space, because carrying it
/// verbatim would fuse two children the moment both numbered a bundle alike.
pub const Bundle = struct {
    origin: BundleOrigin,
    /// This bundle's recorded identity, or `no_bundle` for "not filed".
    ///
    /// Producers never mint it: they state membership, and the finaliser of a
    /// bundle list stamps the roster (`numberBundles`). That is what lets an
    /// id survive a stitch — two children that each numbered their own fans
    /// from one are re-numbered into a single roster — and a re-plan, where
    /// the list is rebuilt and the old names go with it.
    /// guarded-by: ledger_test.zig "a numbered roster names every set exactly once"
    bundle: BundleId = no_bundle,
    members: []const EdgeId,
    /// The cells this set licenses, or `null` for "licenses everywhere".
    ///
    /// A structural decision (a realized bundle, a fan rail) makes
    /// its members ONE bundle wherever they meet, so it leaves this null. A
    /// `.port_share` set is narrower: two edges routed through one perimeter
    /// port share the ink of their COMMON APPROACH and nothing else. Anywhere
    /// else the two are strangers and a meeting is still a transversal.
    /// guarded-by: sketch_ports_test.zig "a port share licenses only its shared approach"
    cells: ?[]const BundleCell = null,
    /// PER-PAIR cell scoping, for a set whose members were grouped
    /// transitively (one physical port, N > 2 edges) rather than by one
    /// shared structural decision. `null` for every set built from a single
    /// decision (`selected_bundle`, `fan_rail`, and any two-member
    /// `.port_share`), where the flat `.cells` field already answers for
    /// every pair alike. Non-null only when a specific PAIR's own common
    /// approach can differ from another pair's inside the same group: two
    /// members licensed at a cell neither of THEM ever walked together,
    /// merely because a THIRD member walked it with each of them
    /// separately, is exactly the fabrication `sketch_ports.zig`'s header
    /// forbids. When set, `bundleMembersAt`/`bundleOf` consult this instead of
    /// the flat union.
    /// guarded-by: ledger_test.zig "a pairwise-scoped set licenses only a pair's own common approach, never a third member's"
    pairwise: ?[]const PairCells = null,
};

/// One pair's own common-approach scoping inside a `.pairwise`-scoped
/// `Bundle`. `a`/`b` are unordered — lookup tries both orientations.
pub const PairCells = struct {
    a: EdgeId,
    b: EdgeId,
    cells: []const BundleCell,
};

/// A lattice cell coordinate, in the Sketch's own integer space (raster's
/// `toCoord` is the identity on in-bounds points). Declared here rather than
/// borrowed from `sketch.zig` because `base/` may not import upward.
pub const BundleCell = struct {
    x: i32,
    y: i32,
};

/// The sets whose origin is `origin`, in order — for a producer that REPLACES
/// one origin's population and must not take the others down with it.
/// guarded-by: ledger_test.zig "keepOrigin selects exactly one origin's sets"
pub fn keepOrigin(
    allocator: std.mem.Allocator,
    sets: []const Bundle,
    origin: BundleOrigin,
) error{OutOfMemory}![]const Bundle {
    var n: usize = 0;
    for (sets) |s| {
        if (s.origin == origin) n += 1;
    }
    if (n == 0) return &.{};
    const out = try allocator.alloc(Bundle, n);
    var i: usize = 0;
    for (sets) |s| {
        if (s.origin != origin) continue;
        out[i] = s;
        i += 1;
    }
    return out;
}

/// `head ++ tail`, members BORROWED. Order is provenance only (every set is
/// scanned), but `head` first reads in the order the origins were established.
/// guarded-by: ledger_test.zig "keepOrigin selects exactly one origin's sets"
pub fn concatBundles(
    allocator: std.mem.Allocator,
    head: []const Bundle,
    tail: []const Bundle,
) error{OutOfMemory}![]const Bundle {
    if (tail.len == 0) return head;
    if (head.len == 0) return tail;
    const out = try allocator.alloc(Bundle, head.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..], tail);
    return out;
}

/// True iff both edges appear in one bundle. Asked about DISTINCT ids: an
/// edge and itself is a question about ownership, which the caller answers
/// before it gets here.
/// guarded-by: ledger_test.zig "co-membership needs both edges inside one set"
pub fn bundleMembers(sets: []const Bundle, first: EdgeId, second: EdgeId) bool {
    return bundleMembersAt(sets, first, second, null);
}

/// `bundleMembers`, asked ABOUT A CELL: a set whose `cells` list is non-null
/// answers only for the cells it licenses. `at = null` asks the membership
/// question with NO position — "are these two ever co-members?", the right
/// question for a report or a test — and no set's scope applies.
/// guarded-by: ledger_test.zig "a cell-scoped bundle answers only inside its licensed cells"
pub fn bundleMembersAt(sets: []const Bundle, first: EdgeId, second: EdgeId, at: ?BundleCell) bool {
    for (sets) |set| {
        var saw_first = false;
        var saw_second = false;
        for (set.members) |m| {
            if (m == first) saw_first = true;
            if (m == second) saw_second = true;
        }
        if (!saw_first or !saw_second) continue;
        if (!licensesPair(set, first, second, at)) continue;
        return true;
    }
    return false;
}

/// Does this set speak for the position `at`? A set with no `cells` list
/// licenses everywhere; `at = null` is the position-free question, which no
/// set's scope narrows.
fn licenses(set: Bundle, at: ?BundleCell) bool {
    const cells = set.cells orelse return true;
    const here = at orelse return true;
    for (cells) |c| {
        if (c.x == here.x and c.y == here.y) return true;
    }
    return false;
}

/// `at`'s cells, for the PAIR `(a, b)` specifically, inside a
/// `.pairwise`-scoped set. `null` means "no pairwise table — fall back to
/// the set's flat scope", never "licenses everywhere": a `.pairwise` set
/// with no entry for this exact pair licenses NOTHING for it, because that
/// pair never declared a common approach of its own.
fn pairEntry(set: Bundle, a: EdgeId, b: EdgeId) ?[]const BundleCell {
    const list = set.pairwise orelse return null;
    for (list) |p| {
        if ((p.a == a and p.b == b) or (p.a == b and p.b == a)) return p.cells;
    }
    return &.{};
}

/// Does this set license the PAIR `(first, second)` at `at`? A `.pairwise`
/// set answers from that pair's own common approach alone, never another
/// pair's; every other set answers from its flat `.cells` scope, as before.
fn licensesPair(set: Bundle, first: EdgeId, second: EdgeId, at: ?BundleCell) bool {
    if (set.pairwise == null) return licenses(set, at);
    const here = at orelse return true;
    const cells = pairEntry(set, first, second) orelse return true;
    for (cells) |c| {
        if (c.x == here.x and c.y == here.y) return true;
    }
    return false;
}

/// Does this set license MEMBER `edge` at `at`, over EVERY pair it appears
/// in? Used where only one edge is known (`bundleOf`): a `.pairwise` set
/// answers yes if `edge` reached `at` together with ANY other member: its
/// own approach ink includes that cell, whichever partner it shared it
/// with.
fn licensesMember(set: Bundle, edge: EdgeId, at: ?BundleCell) bool {
    const list = set.pairwise orelse return licenses(set, at);
    const here = at orelse return true;
    for (list) |p| {
        if (p.a != edge and p.b != edge) continue;
        for (p.cells) |c| {
            if (c.x == here.x and c.y == here.y) return true;
        }
    }
    return false;
}

// -- Bundle identity --------------------------------------------------------

/// Result of resolving one edge against the structural, unscoped population
/// of a bundle roster. `unique` is a roster index: bundle identity stays a
/// `BundleId`, separate from the set's structural provenance.
pub const StructuralBundleResolution = union(enum) {
    absent,
    unique: usize,
    multiple,
};

/// Resolve `edge` to exactly one structural, unscoped set. Cell-scoped sets
/// and `.port_share` sets cannot name a whole rail, even if they contain the
/// edge. Returning the set index lets callers detect two distinct sets before
/// reading their stamped bundle identities.
pub fn resolveStructuralBundle(sets: []const Bundle, edge: EdgeId) StructuralBundleResolution {
    var found: ?usize = null;
    for (sets, 0..) |set, i| {
        if (!structuralUnscoped(set) or !hasMember(set.members, edge)) continue;
        if (found != null) return .multiple;
        found = i;
    }
    return if (found) |i| .{ .unique = i } else .absent;
}

fn structuralUnscoped(set: Bundle) bool {
    if (set.cells != null or set.pairwise != null) return false;
    return switch (set.origin) {
        .selected_bundle, .fan_rail => true,
        .port_share => false,
    };
}

fn hasMember(members: []const EdgeId, edge: EdgeId) bool {
    for (members) |member| {
        if (member == edge) return true;
    }
    return false;
}

/// Stamp every set with its identity: its 1-based position in THIS list.
///
/// The list a Sketch carries IS that render's bundle roster, so a position is
/// a name that is unique inside the render by construction — which is the
/// property the stitch needs, where children that each numbered their own fans
/// from one are merged into one roster, and the property a re-plan needs,
/// where the roster is rebuilt from a different decision.
///
/// Returns a fresh slice; members and cells are borrowed unchanged.
/// guarded-by: ledger_test.zig "a numbered roster names every set exactly once"
pub fn numberBundles(
    allocator: std.mem.Allocator,
    sets: []const Bundle,
) error{OutOfMemory}![]const Bundle {
    if (sets.len == 0) return sets;
    const out = try allocator.alloc(Bundle, sets.len);
    for (sets, out, 1..) |set, *slot, i| {
        slot.* = set;
        slot.bundle = @intCast(i);
    }
    return out;
}

/// True iff every set on this roster has been stamped. A roster holding an
/// unstamped set cannot answer the identity question — `bundleOf` would read
/// that set's members as riding their own private bundles and report two
/// declared bundle-mates as strangers — so a reader that needs identity asks
/// this first and abstains rather than answering wrongly.
/// guarded-by: ledger_test.zig "a numbered roster names every set exactly once"
pub fn rosterNumbered(sets: []const Bundle) bool {
    for (sets) |set| {
        if (set.bundle == no_bundle) return false;
    }
    return true;
}

/// The bundle `edge` rides AT `at`: the identity of the first stamped set
/// that both names it and licenses that cell, and otherwise the edge's own
/// private bundle.
///
/// ONE edge, ONE bundle at one cell. Where two stamped sets both name an edge
/// at one position — a fan rail whose member also shares a perimeter port —
/// roster order decides, and it reads as the structural set's, because the
/// narrower `.port_share` origin is always APPENDED after them. That this
/// single-valued reading agrees with the pairwise membership scan it replaces
/// is a MEASURED fact, not an assumed one: `tiling/bundles.zig` counts the
/// two answers against each other on every carrier the render files.
pub fn bundleOf(sets: []const Bundle, edge: EdgeId, at: ?BundleCell) BundleId {
    for (sets) |set| {
        if (set.bundle == no_bundle) continue;
        if (!licensesMember(set, edge, at)) continue;
        for (set.members) |m| {
            if (m == edge) return set.bundle;
        }
    }
    return privateBundle(edge);
}

/// Do two carriers share a bundle at `at`, read off RECORDED IDENTITY: both
/// sides name the same bundle. Nothing is recomputed from membership here —
/// two lookups and one comparison — which is the whole difference from
/// `bundleMembersAt`.
pub fn bundlesAgree(sets: []const Bundle, first: EdgeId, second: EdgeId, at: ?BundleCell) bool {
    if (first == second) return true;
    return bundleOf(sets, first, at) == bundleOf(sets, second, at);
}
