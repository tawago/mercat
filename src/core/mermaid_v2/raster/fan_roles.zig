//! Fan role/mask stamping, derived from PRODUCER FACTS.
//!
//! Two questions have to be answered about every fan cell: which cells are
//! a SHARED RUN of the fan (role `fan_out_rail` / `fan_in_rail`), and, for
//! fan-OUT, which of two vertical arms at such a cell is a real rail
//! continuation and which is a child's descent to be dropped so the painter
//! resolves `┴`/`┬` instead of `┼`.
//!
//! Both answers come from what the producers KNOW, never from re-reading
//! the finished grid:
//!
//!   ROLE — `markShared` runs at write time, in the edge walk, at the one
//!   moment the fact exists: a fan member's ink has just landed on a cell
//!   the grid attributes to somebody else. That is the definition of a
//!   shared run, and it is the same event that files the cell's
//!   `.rail_member` record, so the role on the grid and the record in the
//!   side table are two spellings of one observation and cannot drift. A
//!   first-class rail (`raster/rails.zig`) needs none of this: it stamps
//!   its own rail role straight from `sketch.Rail` geometry.
//!
//!   MASK — `resolveMasks` runs once after the walk (both arms of a
//!   junction must exist before either can be judged) and decides the
//!   fan-OUT strip from the authoritative RailClaim on the Lattice. The
//!   checker-derived PIVOT identifies a Sketch rect and says which side the
//!   rail comes from, so the arm facing the pivot is the one that survives.
//!   Two grid reads bound it: `continuesColumn`, which asks
//!   whether a SECOND fan rail row sits one cell away on this column (a
//!   grid-wrapped fan threads its rail through such a row, and there both
//!   arms are real), and `armIsAnswered`, which refuses to sever an arm
//!   something answers — the stroke an arrowhead receives on its base side
//!   (owner ruling, see `raster/arrow_base.zig`), or one a neighbouring
//!   stroke asserts back. An answered arm is ink, never the spurious half
//!   of a junction, and the pivot only says which of two arms is spurious
//!   where one of them is.
//!
//! The strip is a VERTICAL-FLOW matter: `pivotSide` reads the pivot rect's
//! rows, which only says "the rail arrives from above/below" under TD/BT.
//! Under LR/RL the fan's shared run IS the vertical, so `resolveMasks`
//! declines outright rather than sever a rail.
//!
//! Fan-IN shared runs keep all four bits (the painter renders `┼`), so the
//! strip is a fan-OUT matter only.
//!
//! SCOPE. `resolveMasks` declines every position a first-class rail owns
//! (`onRail`): those masks are geometry, written cell by cell by the
//! rail rasterizer, and re-deciding them here would put a second author
//! on one fact.
//!
//! Allowed imports: base ledger, `sketch.zig`, `lattice.zig`, raster siblings.

const ledger = @import("../base/ledger.zig");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ew = @import("edges_write.zig");
const aux = @import("aux.zig");

/// The shared-run role of a fan family — the role a cell earns the moment a
/// second member of that fan is seen riding it.
fn railRole(p: lattice.RailPolarity) lattice.EdgeRole {
    return switch (p) {
        .out => .fan_out_rail,
        .in => .fan_in_rail,
    };
}

/// A fan member's ink just landed on `cell` at (x, y). When the cell is
/// attributed to a DIFFERENT edge, this is a shared run of the member's
/// fan: stamp the family's rail role and file the `.rail_member` record
/// that names the rider the grid cannot.
///
/// Called only after a write that actually deposited bits — a suppressed
/// crossing leaves no ink (a `.carrier` matter) and a cell lost to a node
/// or a label names neither an edge nor an arrowhead, so both return here.
/// A non-fan `role` files and stamps nothing (there is no family to name),
/// and a cell that still names this very edge is a lone rider so far.
///
/// The stamp needs the cell's own role to already be fan ink of the same
/// family, which the caller's merge guarantees (`edge_roles.mergeRole`
/// lifts a plain `forward` first writer to the arriving dropper role).
/// An ARROWHEAD occupant is recorded but never stamped: it carries no role
/// at all, so there is nothing on it a rail role could describe.
/// @guarded-by: fan_roles_test.zig "a second rider stamps the family rail role; a lone rider leaves the dropper"
pub fn markShared(
    rec: aux.Recorder,
    cell: *lattice.Cell,
    x: u32,
    y: u32,
    edge_id: u32,
    role: lattice.EdgeRole,
) void {
    const polarity = ew.railPolarity(role) orelse return;
    const named: u32 = switch (cell.occupant) {
        .edge_segment => |seg| seg.edge,
        .arrowhead => |head| head.edge,
        else => return,
    };
    if (named == edge_id) return;
    ew.recordRailMember(rec, x, y, edge_id, polarity);
    const seg = switch (cell.occupant) {
        .edge_segment => |s| s,
        else => return,
    };
    if (ew.railPolarity(seg.role) != polarity) return;
    cell.occupant = .{ .edge_segment = .{
        .edge = seg.edge,
        .kind = seg.kind,
        .role = railRole(polarity),
    } };
}

/// Resolve the fan-OUT strip over every shared run the producers named.
///
/// A `fan_out_rail` cell carrying BOTH vertical arms plus a horizontal one
/// is a junction that claims to conduct up, down and along. That is true
/// only where a second rail row of this fan continues on the column (a
/// grid-wrapped rail threading row K into row K+1); everywhere else one of
/// the two verticals is a child's straight descent through the run, and the
/// arm that survives is the one FACING the fan's pivot.
///
/// Where the pivot cannot be placed — no matching claim for the cell's own
/// edge, no checker-derived common pivot, no placement for that pivot, or a
/// pivot whose rows include this row — nothing is derivable and the cell is
/// left exactly as the walk wrote it. Nor does it strip an ANSWERED arm
/// (`armIsAnswered`): the pivot says which arm is spurious, but only where
/// one of them is.
/// @guarded-by: fan_roles_test.zig "a shared run below its pivot keeps N and drops the child's descent"
/// @guarded-by: fan_roles_test.zig "the arm an arrowhead stands on is never the spurious one"
/// @guarded-by: fan_roles_test.zig "an arm a stroke answers back is left for nobody to strip"
/// @guarded-by: fan_roles_test.zig "under LR/RL the vertical is the rail itself, so nothing is stripped"
pub fn resolveMasks(lat: *lattice.Lattice, s: sketch.Sketch) void {
    if (lat.width == 0 or lat.height == 0) return;
    switch (s.direction) {
        .TD, .BT => {},
        .LR, .RL => return,
    }
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.at(x, y);
            const seg = switch (cell.occupant) {
                .edge_segment => |q| q,
                else => continue,
            };
            if (seg.role != .fan_out_rail) continue;
            const nb = cell.neighbours;
            if (!(nb.n and nb.s)) continue;
            if (!(nb.e or nb.w)) continue;
            if (onRail(s, x, y)) continue;
            if (continuesColumn(lat, x, y)) continue;
            const rect = pivotRect(s, lat.rail_claims, seg.edge, .out) orelse continue;
            const side = pivotSide(rect, y) orelse continue;
            const drop: lattice.Dir4 = switch (side) {
                .north => .south,
                .south => .north,
            };
            if (armIsAnswered(lat, x, y, drop)) continue;
            var m = nb;
            switch (drop) {
                .south => m.s = false,
                .north => m.n = false,
                else => unreachable,
            }
            cell.neighbours = m;
        }
    }
}

/// Which vertical side of row `y` the pivot sits on, or null when it sits
/// on neither (its own rows include `y`, so neither arm faces it).
fn pivotSide(rect: sketch.Rect, y: u32) ?enum { north, south } {
    const row: i32 = @intCast(y);
    if (rect.bottom() <= row) return .north;
    if (rect.y > row) return .south;
    return null;
}

/// True when the cell directly above or below (x, y) is a SECOND rail row
/// on this column: fan ink of EITHER family carrying a horizontal arm of
/// its own. That signature belongs to a grid-wrapped (rows > 1) fan-OUT —
/// a single-row fan's junction sees only pure-vertical neighbours (the
/// pivot stem above, a dropper or an arrowhead below) — so the guard cannot
/// fire on a flat fan.
///
/// Family-blind on purpose: a fan-OUT run stacked directly on a fan-IN run
/// is still two rail rows threaded on one column, and the vertical joining
/// them is still a real continuation. Asking for a matching polarity would
/// narrow the reprieve to same-family stacks and sever the other case.
/// @guarded-by: fan_roles_test.zig "a grid rail keeps the rail-to-rail vertical (┼ over ┼)"
/// @guarded-by: fan_roles_test.zig "a fan-IN rail row one cell away reprieves the fan-OUT junction too"
fn continuesColumn(lat: *const lattice.Lattice, x: u32, y: u32) bool {
    for ([_]i64{ -1, 1 }) |dy| {
        const yi: i64 = @as(i64, y) + dy;
        if (yi < 0 or yi >= @as(i64, @intCast(lat.height))) continue;
        const c = lat.atConst(x, @intCast(yi));
        const seg = switch (c.occupant) {
            .edge_segment => |q| q,
            else => continue,
        };
        if (ew.railPolarity(seg.role) == null) continue;
        if (!(c.neighbours.e or c.neighbours.w)) continue;
        return true;
    }
    return false;
}

/// True when the arm in direction `d` (`.north`/`.south`) is ANSWERED by
/// what it points at, in which case it is a real connection and never the
/// spurious half of a junction. Two answers count:
///
///   * a TERMINAL standing on this cell — an arrowhead whose tip points `d`,
///     so this cell is its base and owes it the stroke it receives (owner
///     ruling, `raster/arrow_base.zig`). Severing that orphans the head and
///     nothing heals it — no pass downstream ever adds a neighbour bit back
///     — so the painted arrowhead-base validator is left reporting the
///     violation this pass created. An arrowhead pointing the
///     OTHER way is fed from beyond it, not from here, and answers nothing.
///
///   * a STROKE asserting the reciprocal arm back at us. Both cells agree a
///     run continues across that boundary, and the neighbour's half of the
///     claim is not this pass's to overrule: stripping our half would open a
///     run the edge writer closed, leaving one end asserting a connection
///     the other no longer offers. A spurious arm is one nothing answers;
///     an answered arm is, by that definition, not one.
/// @guarded-by: fan_roles_test.zig "the arm an arrowhead stands on is never the spurious one"
/// @guarded-by: fan_roles_test.zig "an arm a stroke answers back is left for nobody to strip"
fn armIsAnswered(lat: *const lattice.Lattice, x: u32, y: u32, d: lattice.Dir4) bool {
    const dy: i64 = switch (d) {
        .north => -1,
        .south => 1,
        .east, .west => return false,
    };
    const yi: i64 = @as(i64, y) + dy;
    if (yi < 0 or yi >= @as(i64, @intCast(lat.height))) return false;
    const c = lat.atConst(x, @intCast(yi));
    return switch (c.occupant) {
        .arrowhead => |head| head.dir == d,
        .edge_segment => switch (d) {
            .north => c.neighbours.s,
            .south => c.neighbours.n,
            .east, .west => false,
        },
        else => false,
    };
}

/// The placed rect of the checker-derived pivot in the matching final claim.
/// Claim caches are deliberately ignored; members are the authority.
fn pivotRect(s: sketch.Sketch, claims: []const ledger.RailClaim, edge_id: u32, p: lattice.RailPolarity) ?sketch.Rect {
    const pivot = pivotOf(claims, edge_id, p) orelse return null;
    for (s.nodes) |np| {
        if (np.id == pivot) return np.rect;
    }
    return null;
}

fn pivotOf(claims: []const ledger.RailClaim, edge_id: u32, p: lattice.RailPolarity) ?ledger.NodeId {
    var found: ?ledger.NodeId = null;
    for (claims) |claim| {
        const same_polarity = switch (p) {
            .out => claim.polarity == .out,
            .in => claim.polarity == .in,
        };
        if (!same_polarity or !claimHasEdge(claim, edge_id)) continue;
        const checked = ledger.checkRailClaim(claim);
        if (checked.star_law.wrong_polarity_end) return null;
        const pivot = checked.derived_pivot orelse return null;
        if (found) |prior| {
            if (prior != pivot) return null;
        } else {
            found = pivot;
        }
    }
    return found;
}

fn claimHasEdge(claim: ledger.RailClaim, edge_id: u32) bool {
    for (claim.members) |member| if (member.edge == edge_id) return true;
    return false;
}

/// True when (x, y) lies on a first-class rail's own geometry: its crossbar
/// span or any run of its stem, endpoints included.
fn onRail(s: sketch.Sketch, x: u32, y: u32) bool {
    const px: i32 = @intCast(x);
    const py: i32 = @intCast(y);
    for (s.rails) |rail| {
        if (py == rail.crossbar[0].y and px >= rail.crossbar[0].x and px <= rail.crossbar[1].x) return true;
        var i: usize = 0;
        while (i + 1 < rail.stem.len) : (i += 1) {
            if (onSegment(rail.stem[i], rail.stem[i + 1], px, py)) return true;
        }
    }
    return false;
}

/// Membership on the axis-aligned closed segment `a`-`b`. A non-axis-aligned
/// pair (which a stem never contains) matches only its own endpoints.
fn onSegment(a: sketch.Point, b: sketch.Point, x: i32, y: i32) bool {
    if (a.x == b.x and a.x == x) return y >= @min(a.y, b.y) and y <= @max(a.y, b.y);
    if (a.y == b.y and a.y == y) return x >= @min(a.x, b.x) and x <= @max(a.x, b.x);
    return false;
}

test {
    _ = @import("fan_roles_test.zig");
}
