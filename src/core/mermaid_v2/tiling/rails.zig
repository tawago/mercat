//! Fused-crossbar accountability tier of the report-only structural audit:
//! when several fan rails end up sharing ONE crossbar row, does the drawn
//! result account for every endpoint pair that one continuous run asserts?
//!
//! WHAT THIS CHECKS, EXACTLY. Two rails whose crossbars sit on the same row
//! with touching x-spans raster into one continuous horizontal line. A
//! reader tracing that line can get from any upper-stage endpoint on it to
//! any lower-stage endpoint on it, so the run ASSERTS the whole cross
//! product of its two sides. This tier asks whether each asserted pair is
//! DECLARED by some rail of the run (a tap of that rail names it) and
//! whether that member's branch cell carries a `.tap` record — i.e. whether
//! a reader can follow that one member off the shared run. The population
//! is the two-sided runs: more than one distinct upper-stage node AND more
//! than one distinct lower-stage node, which is the only shape where a run
//! can stand for a pivot nothing declares.
//!
//! ASSERTED-vs-DRAWN, NEVER DECLARED-vs-DRAWN. `layout/fan_lanes.zig` is
//! what compares the SOURCE's declared pairs against what a fused run would
//! assert, and it does that over the SemGraph, before anything rasters. This
//! tier checks the other half of the chain and nothing more: that the DRAWN
//! run's branch records cover the DRAWN run's cross pairs. A layout that
//! invented a tap for a pair the source never stated reads as accounted
//! here. The counts line therefore must NOT be read as "the layout gate was
//! right"; it is read as "the picture accounts for the line it drew".
//!
//! IDENTITY. Two id spaces, both internal to one render, so neither of
//! `expect.zig`'s two limits is crossed. Sketch node ids (`Rail.pivot`,
//! `Tap.node`) are used for distinctness and cardinality only — the same way
//! `expect.nodeTier` reads `np.id`/`tp.node` — and they are unique across a
//! whole Sketch INCLUDING a stitched one (`sketch.zig`'s member-id note).
//! Sketch edge ids are matched against `Aux.value` on `.tap` records, which
//! `raster/rails.zig` files straight from `sketch.Rail.taps[].edge`: one
//! producer, one id space. That keying is legal precisely where CELL-id
//! keying is not — a Cell holds one edge id and is first-writer-lossy, while
//! the aux bundle is PLURAL per cell and append-only under the anti-desync
//! law, so two taps branching at one cell both keep their record. That the
//! record's `value` really is a Sketch edge id of a rail the record's own
//! cell belongs to is pinned corpus-wide from the raster side.
//! @guarded-by: tiling_records_test.zig "every rail-membership record names an edge the fan actually serves"
//!
//! DERIVED POPULATION, NOT A FLAG READ BACK. Nothing upstream is asked
//! whether it admitted a group. The population is the CONSEQUENCE — rails
//! that actually share a row — read off `Sketch.rails` geometry. It is
//! therefore wider than any one upstream gate's admitted set: rails from
//! different children stitched onto one row, and gaps that never reached the
//! gate at all, are in it too. On those a shortfall is a true positive, and
//! the bucket names below describe the DRAWN run only.
//!
//! EVIDENCE BEFORE VERDICT. Two of the four pair buckets are defects and
//! two are not, and which one a pair lands in turns on what the picture can
//! be ASKED, never on what it happens to answer. "No rail of this run
//! declares this pair" is a pure Sketch fact, readable with no side table
//! at all, so it is filed as a defect unconditionally. "This member's
//! branch left no record" is only a lost trace when a record COULD have
//! been read — the run's row carries `.tap` records at all and the branch
//! cell is on the grid; otherwise the evidence was unavailable and the pair
//! is an audit limitation. A missing side table therefore suppresses
//! nothing: it downgrades the questions it cannot answer and leaves the
//! ones it never needed to.
//!
//! WHAT IT DOES NOT SEE, stated plainly:
//!   - THE POPULATION IS RAIL CROSSBARS ONLY, AND THAT SHORTFALL IS
//!     COUNTED, NOT ASSUMED AWAY. A crossbar row's continuous ink is
//!     routinely LONGER than the crossbars on it: an ordinary edge's
//!     horizontal jog can land collinear with a crossbar and extend the
//!     drawn line past its end, adding endpoints that never enter the
//!     sides computed here. The extended run can assert pairs this tier
//!     does not compute, and can be two-sided where the crossbars alone
//!     are not — a single lone-pivot rail extended at both ends draws a
//!     genuinely two-sided line while reading as population 0 here.
//!     Attributing those endpoints needs a walk from the run's ink down
//!     every branch to a placement, which this tier does not do. What it
//!     does instead is REPORT the limit: `u_rail_run_continued` counts
//!     every run whose drawn line outgrows its crossbars, so the zero
//!     above is never silent about the line it did not measure.
//!     No other family covers this. `strokes.zig`'s fused-run pair is not
//!     a fallback: the junction where the jog meets the crossbar has three
//!     or four arms, so `strokes.zig` reads it as a genuine crossing and
//!     files the CONVENTION bucket `c_run_fused_crossing`, leaving
//!     `d_run_fused_collinear` at zero. Measured, not assumed — a
//!     one-subgraph six-edge TD flowchart draws one continuous row joining
//!     three upper nodes to two lower ones and the whole audit's
//!     `d_total` is 0.
//!     @guarded-by: tiling_rails_e2e_test.zig "rails: a run the crossbars under-measure is reported as continued, not as silence"
//!   - `stands_for` is a SemGraph fact absent from the Sketch, so
//!     the asserted set used here is the CROSS-pairs floor. A run carrying a
//!     member that does not block a leaf-to-leaf trace also asserts
//!     within-side pairs, and those are not counted. Under-counting, the
//!     safe direction, exactly like `d_run_fused_collinear`.
//!   - peer-drawn fans reach the grid through the edge walk, which files no
//!     `.tap` record at all (`raster/rails.zig`'s GAP note). They have no
//!     `sketch.Rail`, so they are outside the population entirely.
//!   - a `.tap` record naming an edge no rail of the run declares is ignored.
//!   - the record, not the surviving glyph, is what is read at a branch
//!     cell. Labels raster after rails and the aux bundle is
//!     append-only, so a branch cell whose glyph was overwritten by opaque
//!     text keeps its record and still reads as accounted. Same limit
//!     `expect.zig` states for someone else's opaque ink, and the same
//!     direction: this tier does not manufacture a defect out of it.
//!
//! Imports: `std`, `prim`, `sketch.zig`, `cell.zig`, `counts.zig` (per-file
//! row in `tools/lint/imports.zig`).

const std = @import("std");
const sketch = @import("../sketch.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");

/// Direction discriminant of a rail, read exactly as `raster/rails.zig`
/// reads it: any fan-IN role means the pivot is the LOWER-stage node and the
/// members are the upper-stage ones; everything else reads as fan-OUT (which
/// is also the `Rail.role` default).
fn isOut(role: sketch.EdgeRole) bool {
    return switch (role) {
        .fan_in_rail, .fan_in_dropper => false,
        else => true,
    };
}

/// The upper-stage endpoint of the pair one tap declares.
fn upperOf(rail: sketch.Rail, tp: sketch.Tap) u32 {
    return if (isOut(rail.role)) rail.pivot else tp.node;
}

/// The lower-stage endpoint of the pair one tap declares.
fn lowerOf(rail: sketch.Rail, tp: sketch.Tap) u32 {
    return if (isOut(rail.role)) tp.node else rail.pivot;
}

/// Do two crossbars land on one row with touching-or-overlapping spans —
/// i.e. would they raster into one continuous line? The span predicate is
/// the same interval test the lane separator groups by.
/// @guarded-by: rails_test.zig "rails: two rails on different rows are two runs, not one"
fn fuses(a: sketch.Rail, b: sketch.Rail) bool {
    if (a.crossbar[0].y != b.crossbar[0].y) return false;
    return !(a.crossbar[1].x < b.crossbar[0].x or b.crossbar[1].x < a.crossbar[0].x);
}

/// A distinct-id accumulator. Linear: a fused run's sides are a handful of
/// nodes, and a set keyed by id would need an allocation per group.
const IdSet = struct {
    items: std.ArrayList(u32) = .empty,

    fn add(self: *IdSet, a: std.mem.Allocator, id: u32) error{OutOfMemory}!void {
        for (self.items.items) |x| {
            if (x == id) return;
        }
        try self.items.append(a, id);
    }
};

/// What the picture can be asked about one member's branch cell. The three
/// states are kept apart because only the middle one is a defect: an
/// off-grid branch cell is a position the audit cannot read at all, which
/// is an audit limitation and not evidence of a lost trace.
const Branch = enum { recorded, unrecorded, offgrid };

/// Does this tap's branch cell carry a `.tap` record naming this member?
/// The record is filed at the branch cell itself (`raster/rails.zig` files
/// it at `tap.at` wherever ink landed), so the position is the key and the
/// edge id picks the member out of a plural bundle.
fn branchEvidence(v: cell.View, tp: sketch.Tap) Branch {
    if (tp.at.x < 0 or tp.at.y < 0) return .offgrid;
    const t = v.at(@intCast(tp.at.x), @intCast(tp.at.y)) orelse return .offgrid;
    for (t.ofKind(.tap)) |r| {
        if (r.value == tp.edge) return .recorded;
    }
    return .unrecorded;
}

/// The run's row, and the union of its crossbar spans. `null` when the row
/// itself is off the grid, which leaves nothing to ask about it.
fn runSpan(s: sketch.Sketch, gr: []const u32) ?struct { y: i32, lo: i32, hi: i32 } {
    const y = s.rails[gr[0]].crossbar[0].y;
    if (y < 0) return null;
    var lo = s.rails[gr[0]].crossbar[0].x;
    var hi = s.rails[gr[0]].crossbar[1].x;
    for (gr) |gi| {
        lo = @min(lo, s.rails[gi].crossbar[0].x);
        hi = @max(hi, s.rails[gi].crossbar[1].x);
    }
    if (hi < 0) return null;
    return .{ .y = y, .lo = lo, .hi = hi };
}

/// Does the drawn line continue past this run's crossbars? The cell just
/// outside each end of the union span is asked whether it is stroke ink
/// reciprocating INWARD along the row — the same adjacency test
/// `strokes.zig` uses for a fused run, and restricted to `.stroke` for the
/// same reason, so an arrowhead terminating the line is not a continuation.
/// Ink here belongs to no crossbar of the run (the span covers them all),
/// so it is exactly the ink whose endpoints this tier cannot attribute.
/// @guarded-by: rails_test.zig "rails: a collinear jog past the crossbar is a continued run"
fn runContinues(v: cell.View, s: sketch.Sketch, gr: []const u32) bool {
    const sp = runSpan(s, gr) orelse return false;
    const y: u32 = @intCast(sp.y);
    if (sp.lo > 0) {
        if (v.at(@intCast(sp.lo - 1), y)) |t| {
            if (t.kind == .stroke and t.ink & cell.bit(.east) != 0) return true;
        }
    }
    if (v.at(@intCast(@max(sp.hi, 0) + 1), y)) |t| {
        if (t.kind == .stroke and t.ink & cell.bit(.west) != 0) return true;
    }
    return false;
}

/// Any `.tap` record anywhere on the run's own row, across its whole span.
/// None at all means the side table was not collected for this render (or
/// the row is off-grid): "nothing recorded OR nothing collected", per
/// `cell.zig`'s empty-slice rule, and never a defect. It gates only the
/// branch question — never whether a pair is declared.
/// @guarded-by: rails_test.zig "rails: an uncollected side table still exposes a pair nothing declares"
fn runHasRecords(v: cell.View, s: sketch.Sketch, gr: []const u32) bool {
    const sp = runSpan(s, gr) orelse return false;
    var x: i32 = @max(sp.lo, 0);
    while (x <= sp.hi) : (x += 1) {
        const t = v.at(@intCast(x), @intCast(sp.y)) orelse continue;
        if (t.ofKind(.tap).len > 0) return true;
    }
    return false;
}

/// File one asserted pair into exactly one bucket. A pair several members
/// declare (parallel edges to one leaf) is accounted as soon as ONE of them
/// carries its record — the run is traceable for that pair either way.
/// `row_records` says whether the branch question is answerable at all on
/// this run; it can only move a DECLARED pair between the lost-trace defect
/// and the limitation, never rescue an undeclared one.
/// @guarded-by: rails_test.zig "rails: a pair no member declares is the fabrication bucket"
/// @guarded-by: rails_test.zig "rails: a declared pair whose branch left no record is a lost trace"
/// @guarded-by: rails_test.zig "rails: an off-grid branch cell is unreadable, never a lost trace"
fn accountPair(v: cell.View, s: sketch.Sketch, gr: []const u32, u: u32, l: u32, row_records: bool, c: *counts.Counts) void {
    var declared = false;
    var readable = false;
    for (gr) |gi| {
        const rail = s.rails[gi];
        for (rail.taps) |tp| {
            if (upperOf(rail, tp) != u or lowerOf(rail, tp) != l) continue;
            declared = true;
            switch (branchEvidence(v, tp)) {
                .recorded => {
                    c.c_rail_pair_accounted += 1;
                    return;
                },
                .unrecorded => readable = true,
                .offgrid => {},
            }
        }
    }
    if (!declared) {
        c.d_rail_pair_undeclared += 1;
        return;
    }
    if (row_records and readable) c.d_rail_branch_unrecorded += 1 else c.u_rail_pair_unevidenced += 1;
}

/// Run the tier. Never fails: a scratch failure reuses `u_audit_oom` ("a
/// tier was skipped") and returns, and every allocation for a group happens
/// BEFORE that group's first increment, so the bucket-ownership invariant
/// `n_rail_pairs_asserted == c_ + d_ + d_ + u_rail_pair_unevidenced`
/// survives a partial run.
/// @guarded-by: rails_test.zig "rails: every asserted pair lands in exactly one bucket"
/// @guarded-by: rails_test.zig "rails: a scratch failure at any point leaves the buckets owned"
pub fn check(alloc: std.mem.Allocator, v: cell.View, s: sketch.Sketch, c: *counts.Counts) void {
    c.n_rails_first_class = @intCast(s.rails.len);

    if (s.rails.len == 0) {
        c.u_rail_population_absent += 1;
        return;
    }

    const seen = alloc.alloc(bool, s.rails.len) catch {
        c.u_audit_oom += 1;
        return;
    };
    defer alloc.free(seen);
    @memset(seen, false);

    var group: std.ArrayList(u32) = .empty;
    defer group.deinit(alloc);
    var upper: IdSet = .{};
    defer upper.items.deinit(alloc);
    var lower: IdSet = .{};
    defer lower.items.deinit(alloc);

    for (0..s.rails.len) |i| {
        if (seen[i]) continue;
        seen[i] = true;
        group.clearRetainingCapacity();
        group.append(alloc, @intCast(i)) catch {
            c.u_audit_oom += 1;
            return;
        };

        var grew = true;
        while (grew) {
            grew = false;
            for (s.rails, 0..) |bj, j| {
                if (seen[j]) continue;
                for (group.items) |gi| {
                    if (!fuses(s.rails[gi], bj)) continue;
                    seen[j] = true;
                    group.append(alloc, @intCast(j)) catch {
                        c.u_audit_oom += 1;
                        return;
                    };
                    grew = true;
                    break;
                }
            }
        }
        if (runContinues(v, s, group.items)) c.u_rail_run_continued += 1;
        if (group.items.len < 2) continue;

        upper.items.clearRetainingCapacity();
        lower.items.clearRetainingCapacity();
        for (group.items) |gi| {
            const rail = s.rails[gi];
            for (rail.taps) |tp| {
                upper.add(alloc, upperOf(rail, tp)) catch {
                    c.u_audit_oom += 1;
                    return;
                };
                lower.add(alloc, lowerOf(rail, tp)) catch {
                    c.u_audit_oom += 1;
                    return;
                };
            }
        }
        if (upper.items.items.len < 2 or lower.items.items.len < 2) continue;

        c.n_rail_runs_two_sided += 1;
        const row_records = runHasRecords(v, s, group.items);
        if (!row_records) c.u_rail_run_records_absent += 1;
        for (upper.items.items) |u| {
            for (lower.items.items) |l| {
                c.n_rail_pairs_asserted += 1;
                accountPair(v, s, group.items, u, l, row_records, c);
            }
        }
    }
}
