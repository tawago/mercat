//! Unit tests for `tiling/rails.zig`, over a hand-built Sketch + lattice +
//! side table: the complete fused run first, then one deliberate divergence
//! at a time so each bucket is shown to be the ONLY thing that moves, then
//! the negatives that pin where the population stops.
//!
//! THE FIXTURE IS THE POINT. The shape this tier exists for — two rails
//! sharing one crossbar row, two pivots above, two leaves below — is rare
//! enough in real renders that a corpus run proves nothing about it. It is
//! constructed here directly, and driven to BOTH verdicts.

const std = @import("std");
const lattice = @import("../lattice.zig");
const sketch = @import("../sketch.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");
const rails = @import("rails.zig");

const testing = std.testing;

const W: u32 = 8;
const H: u32 = 8;
/// The shared crossbar row.
const R: i32 = 3;

/// Row-major linear index — the key `Aux.cell` uses.
fn idx(x: i32, y: i32) u32 {
    return @intCast(y * @as(i32, @intCast(W)) + x);
}

/// Two fan-OUT rails whose crossbars sit on row 3 with overlapping spans —
/// one continuous line from x=1 to x=6:
///
///   pivots 0 (x 0..2) and 1 (x 4..6) above, leaves 2 and 3 below.
///   rail A: pivot 0, span [1,5], taps edge 0 -> node 2 at x=1,
///                                     edge 1 -> node 3 at x=5.
///   rail B: pivot 1, span [2,6], taps edge 2 -> node 2 at x=2,
///                                     edge 3 -> node 3 at x=6.
///
/// Declared distinct pairs = 4; asserted cross pairs = |{0,1}| x |{2,3}| = 4.
const Fixture = struct {
    cells: [W * H]lattice.Cell = undefined,
    nodes: [4]sketch.NodePlacement = undefined,
    taps_a: [2]sketch.Tap = undefined,
    taps_b: [2]sketch.Tap = undefined,
    bars: [2]sketch.Rail = undefined,
    /// Branch records, in `Aux.lessThan` order: (cell, kind, value).
    recs: [4]lattice.Aux = undefined,
    n_recs: usize = 4,
    lines: [1][]const u8 = .{"n"},

    fn placement(self: *Fixture, id: u32, x: i32, y: i32) sketch.NodePlacement {
        return .{ .id = id, .rect = .{ .x = x, .y = y, .w = 3, .h = 2 }, .shape = .rect, .lines = &self.lines, .cluster_id = null };
    }

    fn init(self: *Fixture) void {
        for (&self.cells) |*c| c.* = lattice.Cell.empty;
        // The fused run itself: one unbroken stroke across the whole span,
        // so every branch cell holds ink and could carry a record.
        var x: i32 = 1;
        while (x <= 6) : (x += 1) {
            self.cells[idx(x, R)] = .{
                .occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid, .role = .fan_out_rail } },
                .neighbours = .{ .e = true, .w = true },
            };
        }

        self.nodes = .{
            self.placement(0, 0, 0), self.placement(1, 4, 0),
            self.placement(2, 0, 6), self.placement(3, 4, 6),
        };
        self.taps_a = .{
            .{ .edge = 0, .node = 2, .at = .{ .x = 1, .y = R }, .landing = .{ .x = 1, .y = 6 } },
            .{ .edge = 1, .node = 3, .at = .{ .x = 5, .y = R }, .landing = .{ .x = 5, .y = 6 } },
        };
        self.taps_b = .{
            .{ .edge = 2, .node = 2, .at = .{ .x = 2, .y = R }, .landing = .{ .x = 2, .y = 6 } },
            .{ .edge = 3, .node = 3, .at = .{ .x = 6, .y = R }, .landing = .{ .x = 6, .y = 6 } },
        };
        self.bars = .{
            .{ .pivot = 0, .stem = &.{}, .crossbar = .{ .{ .x = 1, .y = R }, .{ .x = 5, .y = R } }, .taps = &self.taps_a, .kind = .solid },
            .{ .pivot = 1, .stem = &.{}, .crossbar = .{ .{ .x = 2, .y = R }, .{ .x = 6, .y = R } }, .taps = &self.taps_b, .kind = .solid },
        };
        self.recs = .{
            .{ .cell = idx(1, R), .value = 0, .kind = .tap },
            .{ .cell = idx(2, R), .value = 2, .kind = .tap },
            .{ .cell = idx(5, R), .value = 1, .kind = .tap },
            .{ .cell = idx(6, R), .value = 3, .kind = .tap },
        };
        self.n_recs = 4;
    }

    fn lat(self: *Fixture) lattice.Lattice {
        return .{ .width = W, .height = H, .cells = &self.cells, .aux = self.recs[0..self.n_recs] };
    }

    fn sk(self: *Fixture) sketch.Sketch {
        return .{
            .bbox = .{ .x = 0, .y = 0, .w = W, .h = H },
            .direction = .TD,
            .nodes = &self.nodes,
            .clusters = &.{},
            .edges = &.{},
            .rails = &self.bars,
            .diagnostics = &.{},
            .budget = .{ .max_width = 80, .rung = 0 },
        };
    }
};

fn run(f: *Fixture) counts.Counts {
    const l = f.lat();
    var c: counts.Counts = .{};
    rails.check(testing.allocator, cell.View.init(&l), f.sk(), &c);
    return c;
}

/// Bucket ownership, asked of whatever state the fixture is in.
fn ownership(c: counts.Counts) !void {
    try testing.expectEqual(
        c.n_rail_pairs_asserted,
        c.c_rail_pair_accounted + c.d_rail_pair_undeclared +
            c.d_rail_branch_unrecorded + c.u_rail_pair_unevidenced,
    );
}

test "rails: a complete fused run accounts for every pair it asserts" {
    var f: Fixture = .{};
    f.init();
    const c = run(&f);
    try testing.expectEqual(@as(u32, 1), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 4), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 4), c.c_rail_pair_accounted);
    try testing.expectEqual(@as(u32, 0), c.d_rail_pair_undeclared);
    try testing.expectEqual(@as(u32, 0), c.d_rail_branch_unrecorded);
    try testing.expectEqual(@as(u32, 0), c.u_rail_run_records_absent);
    try testing.expectEqual(@as(u32, 0), c.u_audit_oom);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try ownership(c);
}

test "rails: a fan-IN run resolves its sides from the rail role" {
    var f: Fixture = .{};
    f.init();
    // Same geometry, opposite polarity: each pivot is now the LOWER-stage
    // node and the tapped members are the upper ones. The cross product is
    // the same four pairs, so the verdict must be identical.
    f.bars[0].role = .fan_in_rail;
    f.bars[1].role = .fan_in_rail;
    const c = run(&f);
    try testing.expectEqual(@as(u32, 1), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 4), c.c_rail_pair_accounted);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "rails: a pair no member declares is the fabrication bucket" {
    var f: Fixture = .{};
    f.init();
    // Rail B loses its branch to leaf 3. Leaf 3 is still on the run (rail A
    // taps it), so the line still asserts pivot 1 -> leaf 3 — and now
    // nothing branches for it.
    f.bars[1].taps = f.taps_b[0..1];
    const c = run(&f);
    try testing.expectEqual(@as(u32, 1), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 4), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 3), c.c_rail_pair_accounted);
    try testing.expectEqual(@as(u32, 1), c.d_rail_pair_undeclared);
    try testing.expectEqual(@as(u32, 0), c.d_rail_branch_unrecorded);
    // The now-orphaned record for edge 3 is ignored: a record naming an
    // edge no rail of the run declares cannot rescue an undeclared pair.
    try testing.expectEqual(@as(u32, 1), c.defectTotal());
    try ownership(c);
}

test "rails: a declared pair whose branch left no record is a lost trace" {
    var f: Fixture = .{};
    f.init();
    // Drop the record for edge 3 only (it sorts last). The pair is honest;
    // the reader has nothing marking where that member leaves the run.
    f.n_recs = 3;
    const c = run(&f);
    try testing.expectEqual(@as(u32, 4), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 3), c.c_rail_pair_accounted);
    try testing.expectEqual(@as(u32, 0), c.d_rail_pair_undeclared);
    try testing.expectEqual(@as(u32, 1), c.d_rail_branch_unrecorded);
    try testing.expectEqual(@as(u32, 0), c.u_rail_run_records_absent);
    try testing.expectEqual(@as(u32, 1), c.defectTotal());
    try ownership(c);
}

test "rails: two rails on different rows are two runs, not one" {
    var f: Fixture = .{};
    f.init();
    // The lane-separated shape: distinct crossbar rows cannot fuse.
    f.bars[1].crossbar = .{ .{ .x = 2, .y = R + 1 }, .{ .x = 6, .y = R + 1 } };
    const c = run(&f);
    try testing.expectEqual(@as(u32, 0), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 0), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "rails: one row but disjoint spans is still two runs" {
    var f: Fixture = .{};
    f.init();
    f.bars[0].crossbar = .{ .{ .x = 1, .y = R }, .{ .x = 2, .y = R } };
    f.bars[1].crossbar = .{ .{ .x = 5, .y = R }, .{ .x = 6, .y = R } };
    const c = run(&f);
    try testing.expectEqual(@as(u32, 0), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "rails: rails sharing one pivot are the lone-pivot shape, never two-sided" {
    var f: Fixture = .{};
    f.init();
    // One endpoint every member really does share: the run stands for it
    // honestly, so there is nothing here for it to fabricate.
    f.bars[1].pivot = 0;
    const c = run(&f);
    try testing.expectEqual(@as(u32, 0), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 0), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "rails: an uncollected side table is a limitation, never a defect" {
    var f: Fixture = .{};
    f.init();
    // The run is complete and correct; the records were simply not
    // collected. An empty slice means "nothing recorded OR nothing
    // collected", so no BRANCH may be judged from it — but every pair is
    // still asserted and still counted, and every one of them is honest.
    f.n_recs = 0;
    const c = run(&f);
    try testing.expectEqual(@as(u32, 1), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 1), c.u_rail_run_records_absent);
    try testing.expectEqual(@as(u32, 4), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 4), c.u_rail_pair_unevidenced);
    try testing.expectEqual(@as(u32, 0), c.c_rail_pair_accounted);
    try testing.expectEqual(@as(u32, 0), c.d_rail_branch_unrecorded);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try ownership(c);
}

test "rails: an uncollected side table still exposes a pair nothing declares" {
    var f: Fixture = .{};
    f.init();
    // The fabrication and the missing side table at once. "No rail of this
    // run declares this pair" is readable off the Sketch alone, so the
    // absent records may downgrade the three honest pairs to unevidenced
    // and must NOT take the fabrication down with them.
    f.bars[1].taps = f.taps_b[0..1];
    f.n_recs = 0;
    const c = run(&f);
    try testing.expectEqual(@as(u32, 1), c.u_rail_run_records_absent);
    try testing.expectEqual(@as(u32, 4), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 1), c.d_rail_pair_undeclared);
    try testing.expectEqual(@as(u32, 3), c.u_rail_pair_unevidenced);
    try testing.expectEqual(@as(u32, 0), c.c_rail_pair_accounted);
    try testing.expectEqual(@as(u32, 1), c.defectTotal());
    try ownership(c);
}

test "rails: an off-grid branch cell is unreadable, never a lost trace" {
    var f: Fixture = .{};
    f.init();
    // The row is on the grid and carries records, so the run-level gate
    // passes; this one member's branch cell is off the east edge. Nothing
    // can be read there, so its pair is an audit limitation and the other
    // three are untouched.
    f.taps_b[1].at = .{ .x = @intCast(W + 2), .y = R };
    const c = run(&f);
    try testing.expectEqual(@as(u32, 0), c.u_rail_run_records_absent);
    try testing.expectEqual(@as(u32, 4), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 3), c.c_rail_pair_accounted);
    try testing.expectEqual(@as(u32, 1), c.u_rail_pair_unevidenced);
    try testing.expectEqual(@as(u32, 0), c.d_rail_branch_unrecorded);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try ownership(c);
}

/// Put one cell of ink just outside the fixture's span on the crossbar row.
fn outside(f: *Fixture, x: i32, nb: lattice.Neighbours) void {
    f.cells[idx(x, R)] = .{
        .occupant = .{ .edge_segment = .{ .edge = 9, .kind = .solid, .role = .forward } },
        .neighbours = nb,
    };
}

test "rails: a collinear jog past the crossbar is a continued run" {
    // The span is [1,6]. An ordinary edge's horizontal jog arriving at x=0
    // and reciprocating east joins the crossbar into ONE longer line whose
    // far endpoint this tier cannot attribute. The pairs it can still see
    // are judged exactly as before — a continued run is a limit on the
    // answer, never a defect and never a reason to stop answering.
    var f: Fixture = .{};
    f.init();
    outside(&f, 0, .{ .e = true, .w = true });
    const c = run(&f);
    try testing.expectEqual(@as(u32, 1), c.u_rail_run_continued);
    try testing.expectEqual(@as(u32, 1), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 4), c.c_rail_pair_accounted);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try ownership(c);

    // The east end counts the same way, and one run is counted once.
    f.init();
    outside(&f, 7, .{ .e = true, .w = true });
    try testing.expectEqual(@as(u32, 1), run(&f).u_rail_run_continued);
}

test "rails: an untouched run, a crossing one, and a terminated one are not continued" {
    var f: Fixture = .{};
    f.init();
    // Nothing outside the span at all.
    try testing.expectEqual(@as(u32, 0), run(&f).u_rail_run_continued);
    // Ink that merely passes the row vertically does not lengthen the line.
    f.init();
    outside(&f, 0, .{ .n = true, .s = true });
    try testing.expectEqual(@as(u32, 0), run(&f).u_rail_run_continued);
    // An arrowhead ENDS the line; it adds no endpoint to attribute. Matching
    // `strokes.zig`, only a stroke neighbour continues a run.
    f.init();
    f.cells[idx(7, R)] = .{
        .occupant = .{ .arrowhead = .{ .dir = .east, .edge = 9 } },
        .neighbours = .{ .w = true },
    };
    try testing.expectEqual(@as(u32, 0), run(&f).u_rail_run_continued);
}

test "rails: a LONE rail whose line is continued is still reported" {
    // The shape that makes this bucket necessary. One rail is a lone-pivot
    // run: it fails the group gate and the two-sided gate, so every pair
    // bucket stays 0. Extended at both ends by ordinary jogs, the line it
    // draws IS two-sided. The population zero below is therefore not
    // evidence of no fused line, and this is the counter that says so.
    var f: Fixture = .{};
    f.init();
    outside(&f, 0, .{ .e = true, .w = true });
    outside(&f, 7, .{ .e = true, .w = true });
    var one = [_]sketch.Rail{f.bars[0]};
    var s = f.sk();
    s.rails = &one;
    const l = f.lat();
    var c: counts.Counts = .{};
    rails.check(testing.allocator, cell.View.init(&l), s, &c);
    try testing.expectEqual(@as(u32, 1), c.u_rail_run_continued);
    try testing.expectEqual(@as(u32, 0), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 0), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "rails: an empty population is named, not silent" {
    // The two zeros this pair exists to tell apart. With no first-class rail
    // the tier declines: every bucket it owns stays 0 — including
    // `u_rail_run_continued`, which cannot fire past the return — and
    // without the marker that state is byte-identical to a measured run
    // that found nothing. `u_` keeps the abstention out of the defect total;
    // it is a limitation, not a fault in the picture.
    var f: Fixture = .{};
    f.init();
    var s = f.sk();
    s.rails = &.{};
    const l = f.lat();
    var c: counts.Counts = .{};
    rails.check(testing.allocator, cell.View.init(&l), s, &c);
    try testing.expectEqual(@as(u32, 0), c.n_rails_first_class);
    try testing.expectEqual(@as(u32, 1), c.u_rail_population_absent);
    try testing.expectEqual(@as(u32, 0), c.u_rail_run_continued);
    try testing.expectEqual(@as(u32, 0), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 0), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try ownership(c);
}

test "rails: the entry denominator is published before the tier can decline" {
    // A NON-empty population reaches every gate, so the marker stays silent
    // and the denominator says what the zeros below were measured over.
    var f: Fixture = .{};
    f.init();
    const c = run(&f);
    try testing.expectEqual(@as(u32, 2), c.n_rails_first_class);
    try testing.expectEqual(@as(u32, 0), c.u_rail_population_absent);

    // A lone rail is still a population: the tier measures it and declines
    // nothing, which is exactly the case the marker must NOT claim.
    var f2: Fixture = .{};
    f2.init();
    var one = [_]sketch.Rail{f2.bars[0]};
    var s = f2.sk();
    s.rails = &one;
    const l = f2.lat();
    var c2: counts.Counts = .{};
    rails.check(testing.allocator, cell.View.init(&l), s, &c2);
    try testing.expectEqual(@as(u32, 1), c2.n_rails_first_class);
    try testing.expectEqual(@as(u32, 0), c2.u_rail_population_absent);
}

test "rails: every asserted pair lands in exactly one bucket" {
    // The invariant, over every divergence the fixture can express.
    var f: Fixture = .{};
    f.init();
    try ownership(run(&f));
    f.bars[1].taps = f.taps_b[0..1];
    try ownership(run(&f));
    f.init();
    f.n_recs = 2;
    const c = run(&f);
    try ownership(c);
    try testing.expectEqual(@as(u32, 4), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 2), c.d_rail_branch_unrecorded);
}

test "rails: a lone rail is never a fused run" {
    var f: Fixture = .{};
    f.init();
    var one = [_]sketch.Rail{f.bars[0]};
    var s = f.sk();
    s.rails = &one;
    const l = f.lat();
    var c: counts.Counts = .{};
    rails.check(testing.allocator, cell.View.init(&l), s, &c);
    try testing.expectEqual(@as(u32, 0), c.n_rail_runs_two_sided);
}

test "rails: a failing allocator reports a skipped tier, never a verdict" {
    var f: Fixture = .{};
    f.init();
    const l = f.lat();
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var c: counts.Counts = .{};
    rails.check(failing.allocator(), cell.View.init(&l), f.sk(), &c);
    try testing.expectEqual(@as(u32, 1), c.u_audit_oom);
    try testing.expectEqual(@as(u32, 0), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try ownership(c);
}

test "rails: a scratch failure at any point leaves the buckets owned" {
    // Index 0 alone only shows the tier declining before it starts. Two
    // independent runs and a SWEEP of every failure point show the claim the
    // header actually makes: each group's allocations all happen before that
    // group's first increment, so the four pair buckets partition the
    // denominator no matter where the scratch runs out.
    var f: Fixture = .{};
    f.init();
    var far_a = f.taps_a;
    var far_b = f.taps_b;
    for (&far_a) |*t| t.at.y = R + 3;
    for (&far_b) |*t| t.at.y = R + 3;
    var four = [_]sketch.Rail{
        f.bars[0],
        f.bars[1],
        .{ .pivot = 0, .stem = &.{}, .crossbar = .{ .{ .x = 1, .y = R + 3 }, .{ .x = 5, .y = R + 3 } }, .taps = &far_a, .kind = .solid },
        .{ .pivot = 1, .stem = &.{}, .crossbar = .{ .{ .x = 2, .y = R + 3 }, .{ .x = 6, .y = R + 3 } }, .taps = &far_b, .kind = .solid },
    };
    var s = f.sk();
    s.rails = &four;
    const l = f.lat();

    var saw_oom = false;
    var saw_whole = false;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        var c: counts.Counts = .{};
        rails.check(failing.allocator(), cell.View.init(&l), s, &c);
        try ownership(c);
        if (c.u_audit_oom > 0) {
            saw_oom = true;
            try testing.expectEqual(@as(u32, 0), c.defectTotal());
        } else {
            saw_whole = true;
            try testing.expectEqual(@as(u32, 2), c.n_rail_runs_two_sided);
            try testing.expectEqual(@as(u32, 8), c.n_rail_pairs_asserted);
        }
    }
    // The sweep has to span both regimes, or it pinned nothing.
    try testing.expect(saw_oom and saw_whole);
}
