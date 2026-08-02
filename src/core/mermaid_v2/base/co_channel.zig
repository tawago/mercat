//! Co-channel membership vocabulary (D-IR item 4's companion record): the
//! sets of edges that legally share ink because ONE structural decision put
//! them on the same channel, plus the cell coordinate a narrowed set scopes
//! itself to.
//!
//! Split out of base/ledger.zig, which sat exactly at the mermaid_v2
//! 500-line cap. ledger.zig re-exports every symbol here, so existing
//! `pb.CoSet` / `pb.coMembers` / `pb.coSetsFromPlan` call sites are
//! source-compatible and type-identical.
//!
//! Pure data + pure functions; imports only base siblings. Universally
//! importable (base/ no-deps tier). Tests live in ledger_test.zig.

const std = @import("std");

/// Structurally the ledger's own handle (`pb.EdgeId`); redeclared rather than
/// imported so this file never closes an import loop back through ledger.zig.
/// guarded-by: ledger_test.zig "identity handles match prim's"
const EdgeId = u32;

/// Where a co-channel set came from. Provenance only: every reader treats
/// the origins alike, and the tag exists so a set can be attributed in a
/// report and so a later law can scope itself to one origin.
pub const CoOrigin = enum {
    /// One realized selected join (`RealizedJoins.selected_joins`).
    selected_join,
    /// One fan's peers sharing a rail lane (layout/fan.zig). The only
    /// population a clustered or recursed render can have: those renders
    /// carry an empty realized plan (V-D-IR-07).
    fan_rail,
    /// Edges a producer deliberately routed through ONE perimeter port, so
    /// their approach ink is one run (`sketch_ports.portShareCoSets`). Derived
    /// from the sketch's own declared polylines — the producers' agreement on
    /// a coordinate IS the declaration — and always APPENDED to the sets the
    /// other origins contributed, never substituted for them.
    port_share,
};

/// A CO-CHANNEL set: edges that legally share ink because ONE structural
/// decision put them on the same channel.
///
/// Membership is an EXPLICIT edge-id list, never a numeric channel id. Ids
/// are read in the id space of the Sketch that holds the set: a set built
/// inside a recursion child is rewritten by `cluster/stitch.zig` into the
/// merged Sketch's single, globally unique edge-id space, because carrying it
/// verbatim would fuse two children the moment both numbered a channel alike.
pub const CoSet = struct {
    origin: CoOrigin,
    members: []const EdgeId,
    /// The cells this set licenses, or `null` for "licenses everywhere".
    ///
    /// A structural decision (a realized join, a fan rail) makes
    /// its members ONE channel wherever they meet, so it leaves this null. A
    /// `.port_share` set is narrower: two edges routed through one perimeter
    /// port share the ink of their COMMON APPROACH and nothing else. Anywhere
    /// else the two are strangers and a meeting is still a transversal.
    /// guarded-by: sketch_ports_test.zig "a port share licenses only its shared approach"
    cells: ?[]const CoCell = null,
};

/// A lattice cell coordinate, in the Sketch's own integer space (raster's
/// `toCoord` is the identity on in-bounds points). Declared here rather than
/// borrowed from `sketch.zig` because `base/` may not import upward.
pub const CoCell = struct {
    x: i32,
    y: i32,
};

/// The sets whose origin is `origin`, in order — for a producer that REPLACES
/// one origin's population and must not take the others down with it.
/// guarded-by: ledger_test.zig "keepOrigin selects exactly one origin's sets"
pub fn keepOrigin(
    allocator: std.mem.Allocator,
    sets: []const CoSet,
    origin: CoOrigin,
) error{OutOfMemory}![]const CoSet {
    var n: usize = 0;
    for (sets) |s| {
        if (s.origin == origin) n += 1;
    }
    if (n == 0) return &.{};
    const out = try allocator.alloc(CoSet, n);
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
pub fn concatSets(
    allocator: std.mem.Allocator,
    head: []const CoSet,
    tail: []const CoSet,
) error{OutOfMemory}![]const CoSet {
    if (tail.len == 0) return head;
    if (head.len == 0) return tail;
    const out = try allocator.alloc(CoSet, head.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..], tail);
    return out;
}

/// True iff both edges appear in one co-set. Asked about DISTINCT ids: an
/// edge and itself is a question about ownership, which the caller answers
/// before it gets here.
/// guarded-by: ledger_test.zig "co-membership needs both edges inside one set"
pub fn coMembers(sets: []const CoSet, first: EdgeId, second: EdgeId) bool {
    return coMembersAt(sets, first, second, null);
}

/// `coMembers`, asked ABOUT A CELL: a set whose `cells` list is non-null
/// answers only for the cells it licenses. `at = null` asks the membership
/// question with NO position — "are these two ever co-members?", the right
/// question for a report or a test — and no set's scope applies.
/// guarded-by: ledger_test.zig "a cell-scoped co-set answers only inside its licensed cells"
pub fn coMembersAt(sets: []const CoSet, first: EdgeId, second: EdgeId, at: ?CoCell) bool {
    for (sets) |set| {
        if (set.cells) |cells| if (at) |here| {
            var licensed = false;
            for (cells) |c| {
                if (c.x == here.x and c.y == here.y) {
                    licensed = true;
                    break;
                }
            }
            if (!licensed) continue;
        };
        var saw_first = false;
        var saw_second = false;
        for (set.members) |m| {
            if (m == first) saw_first = true;
            if (m == second) saw_second = true;
        }
        if (saw_first and saw_second) return true;
    }
    return false;
}
