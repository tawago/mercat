//! Fan-role shadow comparator — report-only, off unless the composition
//! root sets `MERCAT_FANROLE_SHADOW=1`.
//!
//! WHAT IT COMPARES. `raster/edge_roles.zig`'s post-walk pass decides two
//! things about every fan cell by INFERENCE from the finished grid: which
//! cells are shared fan runs (role `fan_out_rail` / `fan_in_rail`, deduced
//! from a dropper role plus a mask carrying both a vertical and a
//! horizontal arm), and, for fan-OUT, which of two vertical arms is a real
//! trunk continuation and which is a child descent to be stripped. Both
//! answers are also derivable from what the PRODUCERS recorded while they
//! drew: the side table's `.rail_member` / `.tap` records (which member's
//! ink rides which cell) plus the Sketch's fan facts (which node is the
//! fan's pivot). This module computes the producer-derived answer and
//! counts where the two disagree. The number it reports is the gate for
//! replacing the inference with the derivation.
//!
//! NOT A LAW. Nothing here is a defect claim about the rendering. A
//! mismatch says "these two ways of answering the same question differ",
//! and the residual is expected to be small but not necessarily zero.
//! `counts.zig`'s n_/m_/c_/d_/u_ prefix contract belongs to the ink-law
//! taxonomy and deliberately does NOT apply to this struct.
//!
//! SCOPE — exactly the cells the stamping pass governs. A position covered
//! by a first-class `sketch.Rail` (its stem run or its crossbar span) is
//! stamped by `raster/busbars.zig` straight from geometry, and the pass
//! skips it: its role is already a rail role, so the pass's `switch` falls
//! through. Those cells are counted (`rail_owned`) and judged on neither
//! dimension — there is no inference there to shadow.
//!
//! NON-MUTATION. Same threefold guarantee as `scan.zig`: checks read a
//! `cell.View`, which hands out `Typed` COPIES; the lint zone denies
//! `raster/`, so no writer is reachable from here; and the emitter is a
//! pure function of its inputs.
//!
//! Imports: `std`, `prim`, `lattice.zig`, `sketch.zig`, tiling siblings.

const std = @import("std");
const prim = @import("prim");
const lattice = @import("../lattice.zig");
const sketch = @import("../sketch.zig");
const cell = @import("cell.zig");

/// Leading token of the emitted stderr line — the grep handle.
pub const line_prefix = "mercat-fanrole-shadow:";

/// Byte budget of one emitted line; `writeLine` truncates rather than
/// failing. Sized well past the worst case (every counter at a u32's full
/// ten digits).
pub const line_buf_len: usize = 1024;

/// Everything the comparator reads. Assembled by the composition root from
/// values already live there.
pub const Ctx = struct {
    /// The winning Sketch — the source of the fan facts (rails and their
    /// pivots, fan-role edges and their endpoints, node rects).
    sketch: sketch.Sketch,
    /// The SHIPPED lattice — post-stamping, post-reconcile, pre-paint.
    lat: *const lattice.Lattice,
};

/// Per-fan-family tallies. One instance per `lattice.RailPolarity`.
pub const Bucket = struct {
    /// Records and lattice agree this cell is a shared run of this family.
    role_match: u32 = 0,
    /// The producers recorded a member riding here; the lattice does not
    /// carry this family's rail role. The inference missed a shared run.
    role_records_only: u32 = 0,
    /// The lattice carries this family's rail role; no producer recorded a
    /// second rider here. The inference invented a shared run.
    role_lattice_only: u32 = 0,
    /// A role-matched cell whose mask agrees with the producer-derived
    /// expectation.
    mask_match: u32 = 0,
    /// A role-matched cell whose mask does not: either the stamping
    /// precondition (one vertical arm and one horizontal arm) no longer
    /// holds, or a fan-OUT cell kept both vertical arms where the records
    /// name no continuing rail row on its column.
    mask_mismatch: u32 = 0,
    /// A fan-OUT cell that kept both vertical arms and whose pivot the fan
    /// facts could not place above or below it. The strip's decision is not
    /// derivable there, so the cell is counted as a mask match and tallied
    /// here instead of guessed at.
    pivot_unresolved: u32 = 0,

    /// This family's disagreements: the two role asymmetries plus the mask.
    pub fn mismatches(self: Bucket) u32 {
        return self.role_records_only + self.role_lattice_only + self.mask_mismatch;
    }
};

/// The whole comparison. `mismatchTotal()` is the one number the gate reads.
pub const Counts = struct {
    /// Cells carrying a fan fact on either side — the denominator.
    cells_judged: u32 = 0,
    /// Positions skipped because a first-class rail owns them (see the
    /// module doc's SCOPE note). Not judged, not a mismatch.
    rail_owned: u32 = 0,
    /// Positions carrying a fan record that the stamping pass cannot reach
    /// (an arrowhead, a border — it walks `.edge_segment` occupants only).
    /// Reported so those records are never silently absent from the totals.
    records_off_grid: u32 = 0,
    fan_out: Bucket = .{},
    fan_in: Bucket = .{},

    /// Every disagreement, both dimensions, both families — the gate number.
    pub fn mismatchTotal(self: Counts) u32 {
        return self.fan_out.mismatches() + self.fan_in.mismatches();
    }

    /// Render the one-line `mercat-fanrole-shadow: k=v ...` form into `buf`
    /// and return the written slice. Truncates at the buffer end instead of
    /// failing — a diagnostic line must never break a render. The per-family
    /// terms are reflection-driven, so a new `Bucket` field appears on the
    /// line the moment it is declared.
    /// guarded-by: fanrole_test.zig "writeLine carries every bucket field of both families plus the mismatch total"
    pub fn writeLine(self: Counts, buf: []u8) []const u8 {
        const head = std.fmt.bufPrint(buf, "{s} cells={d} rail_owned={d} records_off_grid={d}", .{
            line_prefix, self.cells_judged, self.rail_owned, self.records_off_grid,
        }) catch return buf[0..0];
        var i = head.len;
        inline for (.{ "fan_out", "fan_in" }) |family| {
            const b = @field(self, family);
            inline for (@typeInfo(Bucket).@"struct".fields) |f| {
                const term = std.fmt.bufPrint(buf[i..], " {s}_{s}={d}", .{ family, f.name, @field(b, f.name) }) catch break;
                i += term.len;
            }
        }
        const tail = std.fmt.bufPrint(buf[i..], " mismatch={d}", .{self.mismatchTotal()}) catch return buf[0..i];
        return buf[0 .. i + tail.len];
    }

    pub fn emitLine(self: Counts) void {
        var buf: [line_buf_len]u8 = undefined;
        std.debug.print("{s}\n", .{self.writeLine(&buf)});
    }
};

/// Compare and return the counts. Never fails and never allocates.
pub fn run(ctx: Ctx) Counts {
    var c: Counts = .{};
    const w = ctx.lat.width;
    const h = ctx.lat.height;
    if (w == 0 or h == 0) return c;

    const v = cell.View.init(ctx.lat);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const t = v.at(x, y) orelse continue;
            judge(ctx, v, x, y, t, &c);
        }
    }
    return c;
}

/// Run the comparison and emit its one stderr line. The composition root
/// gates this on `MERCAT_FANROLE_SHADOW=1`.
pub fn emit(ctx: Ctx) void {
    run(ctx).emitLine();
}

const both_polarities = [_]lattice.RailPolarity{ .out, .in };

fn judge(ctx: Ctx, v: cell.View, x: u32, y: u32, t: cell.Typed, c: *Counts) void {
    const recorded_out = hasRecord(t, .out);
    const recorded_in = hasRecord(t, .in);
    const stamped = railFamily(t);
    if (!recorded_out and !recorded_in and stamped == null) return;

    // A first-class rail writes its own role and mask from geometry; the
    // stamping pass never touches those cells, so there is no inference to
    // shadow there.
    if (onRail(ctx.sketch, x, y)) {
        c.rail_owned += 1;
        return;
    }
    // The pass walks `.edge_segment` occupants only. Records elsewhere are
    // real but out of its reach.
    if (t.edge_role == null) {
        c.records_off_grid += 1;
        return;
    }

    c.cells_judged += 1;
    for (both_polarities) |p| {
        const recorded = if (p == .out) recorded_out else recorded_in;
        const is_stamped = stamped == p;
        const b = bucketFor(c, p);
        if (recorded and is_stamped) {
            b.role_match += 1;
            if (maskAgrees(ctx, v, x, y, t, p, b)) {
                b.mask_match += 1;
            } else {
                b.mask_mismatch += 1;
            }
        } else if (recorded) {
            b.role_records_only += 1;
        } else if (is_stamped) {
            b.role_lattice_only += 1;
        }
    }
}

fn bucketFor(c: *Counts, p: lattice.RailPolarity) *Bucket {
    return switch (p) {
        .out => &c.fan_out,
        .in => &c.fan_in,
    };
}

/// True when a producer filed a fan-membership or tap record of `p` here.
/// Both kinds carry the polarity in `detail` and the member's edge id in
/// `value`.
fn hasRecord(t: cell.Typed, p: lattice.RailPolarity) bool {
    const d = @intFromEnum(p);
    for (t.ofKind(.rail_member)) |r| if (r.detail == d) return true;
    for (t.ofKind(.tap)) |r| if (r.detail == d) return true;
    return false;
}

/// The fan family whose SHARED-RUN role this cell carries, if any. Layout
/// only ever hands a dropper role to an `EdgePath` or a `Rail`, so a rail
/// role on the grid was written either by the bus-bar rasterizer (excluded
/// above) or by the stamping pass.
fn railFamily(t: cell.Typed) ?lattice.RailPolarity {
    const role = t.edge_role orelse return null;
    return switch (role) {
        .fan_out_rail => .out,
        .fan_in_rail => .in,
        else => null,
    };
}

/// The producer-derived mask expectation.
///
/// Two claims, both about the cell the pass stamped:
///   1. arity — a shared run still carries at least one vertical and at
///      least one horizontal arm. That is the pass's own stamping
///      precondition, and the later mask passes (phantom clearing,
///      reciprocity repair, arrowhead-base receiving) must not have
///      destroyed it.
///   2. strip (fan-OUT only) — both vertical arms survive at a shared-run
///      cell ONLY where a second rail row continues on this column. The
///      pass answers that by inspecting the neighbour's role and mask; the
///      records answer it by naming the same fan family one cell away.
///
/// A cell that kept both arms with no recorded continuation is a mismatch
/// unless the fan facts cannot say which side the pivot is on — the strip
/// only fires when one vertical side resolves to the source and the other
/// does not, so with the pivot unplaced no strip is predictable.
fn maskAgrees(
    ctx: Ctx,
    v: cell.View,
    x: u32,
    y: u32,
    t: cell.Typed,
    p: lattice.RailPolarity,
    b: *Bucket,
) bool {
    const n = t.mask & cell.bit(.north) != 0;
    const s = t.mask & cell.bit(.south) != 0;
    const horizontal = t.mask & (cell.bit(.east) | cell.bit(.west)) != 0;
    if (!(n or s) or !horizontal) return false;
    if (p == .in) return true;
    if (!(n and s)) return true;
    if (continuesColumn(v, x, y, p)) return true;
    if (pivotSide(ctx, t, p, y) == null) {
        b.pivot_unresolved += 1;
        return true;
    }
    return false;
}

/// The records' answer to `railJunctionAdjacent`: is the cell directly
/// above or below part of the same fan family's shared run?
fn continuesColumn(v: cell.View, x: u32, y: u32, p: lattice.RailPolarity) bool {
    for ([_]cell.Dir4{ .north, .south }) |d| {
        const q = cell.step(x, y, d, v.width(), v.height()) orelse continue;
        const nt = v.at(q.x, q.y) orelse continue;
        if (hasRecord(nt, p) or railFamily(nt) == p) return true;
    }
    return false;
}

/// Which vertical side of row `y` the fan's pivot node sits on, or null
/// when the fan facts do not place it on either (the pivot shares this
/// cell's rows, or the recorded edge has no fan geometry in the Sketch).
fn pivotSide(ctx: Ctx, t: cell.Typed, p: lattice.RailPolarity, y: u32) ?cell.Dir4 {
    const d = @intFromEnum(p);
    for ([_]lattice.AuxKind{ .rail_member, .tap }) |kind| {
        for (t.ofKind(kind)) |r| {
            if (r.detail != d) continue;
            const pivot = pivotOf(ctx.sketch, r.value, p) orelse continue;
            const rect = nodeRect(ctx.sketch, pivot) orelse continue;
            const row: i32 = @intCast(y);
            if (rect.bottom() <= row) return .north;
            if (rect.y > row) return .south;
        }
    }
    return null;
}

/// The pivot node of the fan that `edge_id` belongs to: the rail's pivot
/// when a first-class rail serves it, else the fan-side endpoint of its
/// own `EdgePath`.
fn pivotOf(s: sketch.Sketch, edge_id: u32, p: lattice.RailPolarity) ?prim.NodeId {
    for (s.busbars) |bb| {
        if (railRoleFamily(bb.role) != p) continue;
        for (bb.taps) |tap| {
            if (tap.edge == edge_id) return bb.pivot;
        }
    }
    for (s.edges) |e| {
        if (e.id != edge_id) continue;
        if (railRoleFamily(e.role) != p) return null;
        return switch (p) {
            .out => e.from,
            .in => e.to,
        };
    }
    return null;
}

/// Family of any fan role — rail or dropper, both members read the same.
fn railRoleFamily(role: prim.EdgeRole) ?lattice.RailPolarity {
    return switch (role) {
        .fan_out_rail, .fan_out_dropper => .out,
        .fan_in_rail, .fan_in_dropper => .in,
        else => null,
    };
}

fn nodeRect(s: sketch.Sketch, id: prim.NodeId) ?sketch.Rect {
    for (s.nodes) |np| {
        if (np.id == id) return np.rect;
    }
    return null;
}

/// True when `(x, y)` lies on a first-class rail's own geometry: its
/// crossbar span or any run of its stem, endpoints included.
fn onRail(s: sketch.Sketch, x: u32, y: u32) bool {
    const px: i32 = @intCast(x);
    const py: i32 = @intCast(y);
    for (s.busbars) |bb| {
        if (py == bb.crossbar[0].y and px >= bb.crossbar[0].x and px <= bb.crossbar[1].x) return true;
        var i: usize = 0;
        while (i + 1 < bb.stem.len) : (i += 1) {
            if (onSegment(bb.stem[i], bb.stem[i + 1], px, py)) return true;
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
