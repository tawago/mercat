//! End-to-end cross-checks for the report-only structural audit
//! (`tiling/`), run against REAL renders: parse -> permits -> select ->
//! rasterize -> scan -> paint.
//!
//! This file lives at the mermaid_v2 root rather than inside `tiling/`
//! because it needs privileges the tiling zone deliberately denies —
//! `raster/`, `select`, `paint` — to prove two things the zone cannot
//! prove about itself:
//!   1. INERTNESS: running the audit changes neither the lattice nor the
//!      painted bytes.
//!   2. CALIBRATION: the defect buckets stay silent on renders that are
//!      correct by construction, so a nonzero count means something.
//! Its import row is pinned in `tools/lint_imports.zig`.

const std = @import("std");
const prim = @import("prim");
const lattice = @import("lattice.zig");
const sem_graph = @import("sem_graph.zig");
const sketch = @import("sketch.zig");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");
const paint = @import("paint.zig");
const reconcile = @import("raster/reconcile.zig");
const arrow_base = @import("raster/arrow_base.zig");
const scan = @import("tiling/scan.zig");
const counts = @import("tiling/counts.zig");
const cell = @import("tiling/cell.zig");
const arrows = @import("tiling/arrows.zig");

const testing = std.testing;

/// One real render, carried far enough to audit.
const Rendered = struct {
    graph: sem_graph.SemGraph,
    sketch: sketch.Sketch,
    report: raster.RasterReport,
    mode: prim.SubgraphEdges,

    /// Pointer receiver on purpose: `Ctx.lat` aliases THIS frame's
    /// lattice, so the audit must never be handed the address of a
    /// by-value parameter copy.
    fn ctx(self: *const Rendered) scan.Ctx {
        return .{
            .graph = self.graph,
            .sketch = self.sketch,
            .lat = &self.report.lattice,
            .mode = self.mode,
            .labels_placed = self.report.labels_placed,
            .labels_dropped = self.report.labels_dropped,
            .labels_displaced = self.report.labels_displaced,
            .edge_cells_lost = self.report.edge_cells_lost,
        };
    }
};

/// Drive the production path exactly as the composition root does. The
/// permit plan lives on this frame only for the duration of `choose`,
/// mirroring `entry.zig`'s own contract.
fn render(a: std.mem.Allocator, source: []const u8, width: u32) !Rendered {
    return renderMode(a, source, width, .bridge);
}

fn renderMode(a: std.mem.Allocator, source: []const u8, width: u32, mode: prim.SubgraphEdges) !Rendered {
    const graph = try parse(a, source);
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const winner = try select.choose(a, graph, &plan, width, false, false);
    // `collect_aux` exactly as the composition root sets it: the audit reads
    // the side table, so rendering without it would audit a lattice that
    // never ships. See `tiling_records_test.zig`.
    const report = try raster.rasterize(a, winner.sketch, mode, .{ .collect_aux = true });
    return .{ .graph = graph, .sketch = winner.sketch, .report = report, .mode = mode };
}

/// Sources spanning the shapes the audit has to survive: a plain chain,
/// a fan, a labelled edge, a self-loop, an invisible link, clusters, and
/// a clustered crossing.
const corpus = [_][]const u8{
    "flowchart TD\n  A --> B\n  B --> C\n",
    "flowchart LR\n  A --> B\n  B --> C\n  C --> D\n",
    "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n  A --> E\n",
    "flowchart TD\n  A -->|yes| B\n  A -->|no| C\n",
    "flowchart TD\n  A --> A\n  A --> B\n",
    "flowchart TD\n  A ~~~ B\n  B --> C\n",
    "flowchart TD\n  subgraph S\n    A --> B\n  end\n  B --> C\n",
    "flowchart TD\n  subgraph S1\n    A --> B\n  end\n  subgraph S2\n    C --> D\n  end\n  A --> D\n  C --> B\n",
};

test "tiling audit is inert: lattice cells and painted bytes unchanged" {
    for (corpus) |source| for ([_]u32{ 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const lat = r.report.lattice;

        const cells_before = try a.dupe(lattice.Cell, lat.cells);
        const painted_before = try paint.paint(a, lat, r.sketch.budget.max_width);

        _ = scan.run(a, r.ctx());

        try testing.expectEqualSlices(lattice.Cell, cells_before, lat.cells);
        const painted_after = try paint.paint(a, lat, r.sketch.budget.max_width);
        try testing.expectEqualStrings(painted_before, painted_after);
    };
}

test "tiling audit is idempotent and its meta counters describe the render" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "flowchart TD\n  subgraph S\n    A --> B\n  end\n  B --> C\n";
    const r = try render(a, source, 80);

    const first = scan.run(a, r.ctx());
    const second = scan.run(a, r.ctx());
    try testing.expectEqual(first, second);

    const lat = r.report.lattice;
    try testing.expectEqual(lat.width * lat.height, first.n_cells);
    try testing.expectEqual(@as(u32, @intCast(r.graph.clusters.len)), first.n_clustered);
    try testing.expect(first.n_clustered > 0);
    try testing.expectEqual(@as(u32, 0), first.u_audit_oom);

    // Every arrowhead in the lattice is accounted for.
    var arrowheads: u32 = 0;
    for (lat.cells) |c| {
        if (c.occupant == .arrowhead) arrowheads += 1;
    }
    try testing.expectEqual(arrowheads, first.n_arrow_cells);
}

test "clustered crossing render has zero orphan arrowhead laterals" {
    // The clustered-crossing adversarial fixture: on clustered renders
    // the crossing suppression pass is inert (its permits are skipped)
    // and the edge writer OR-merges foreign transversal bits into
    // arrowhead cells. If any of that legal population landed in a
    // defect bucket, the audit would be measuring the renderer's
    // conventions instead of its mistakes. The answer to a legal case is
    // a new `c_` bucket, never a filter — so this asserts ZERO, not
    // "small".
    const clustered = [_][]const u8{
        "flowchart TD\n  subgraph S1\n    A --> B\n  end\n  subgraph S2\n    C --> D\n  end\n  A --> D\n  C --> B\n",
        "flowchart LR\n  subgraph S1\n    A --> B\n  end\n  subgraph S2\n    C --> D\n  end\n  A --> D\n  C --> B\n",
        "flowchart TD\n  subgraph Outer\n    subgraph Inner\n      A --> B\n    end\n    B --> C\n  end\n  C --> D\n  A --> D\n",
    };
    for (clustered) |source| for ([_]u32{ 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const c = scan.run(a, r.ctx());
        if (c.d_arrow_lat_orphan != 0) {
            var buf: [counts.line_buf_len]u8 = undefined;
            std.debug.print("source:\n{s}{s}\n", .{ source, c.writeLine(&buf) });
            return error.OrphanLateral;
        }
    };
}

test "the whole corpus is free of structural defects" {
    // The calibration floor: every shape in `corpus`, at both widths, and
    // EVERY defect bucket — not just the one the commit that added the
    // fixture cared about. A bucket that fires here is either a real
    // finding or a law that needs a convention bucket; never a filter.
    for (corpus) |source| for ([_]u32{ 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try expectSilent(arena.allocator(), source, width);
    };
}

test "an invisible link contributes no ink and no arrowhead law" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try render(a, "flowchart TD\n  A ~~~ B\n", 80);
    const v = cell.View.init(&r.report.lattice);
    var y: u32 = 0;
    while (y < v.height()) : (y += 1) {
        var x: u32 = 0;
        while (x < v.width()) : (x += 1) {
            const t = v.at(x, y).?;
            if (t.kind == .ghost) try testing.expectEqual(@as(u4, 0), t.ink);
        }
    }
    try testing.expectEqual(@as(u32, 0), scan.run(a, r.ctx()).defectTotal());
}

// -- Decomposition identity --------------------------------------------------

/// The buckets the base ladder produces from `arrow_base.validate`'s
/// violation set. `c_base_label` is deliberately absent: it is the
/// validator's EXEMPTION, not one of its violations.
fn baseViolationBuckets(c: counts.Counts) u32 {
    return c.u_base_oob + c.c_base_side_fed + c.d_base_blank +
        c.c_base_fan_trunk + c.c_base_foreign + c.c_base_frame + c.d_base_unfed;
}

test "base buckets decompose arrow_base.validate exactly" {
    // The acceptance gate for the base partition: over every shape in the
    // corpus, at both widths, the audit's seven violation buckets must sum
    // to the renderer's own single count. A bucket that swallowed a case
    // the validator counts (or invented one it does not) breaks this.
    for (corpus) |source| for ([_]u32{ 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const c = scan.run(a, r.ctx());
        const truth = arrow_base.validate(&r.report.lattice).violations;
        if (baseViolationBuckets(c) != truth) {
            var buf: [counts.line_buf_len]u8 = undefined;
            std.debug.print(
                "source:\n{s}validate={d} buckets={d}\n{s}\n",
                .{ source, truth, baseViolationBuckets(c), c.writeLine(&buf) },
            );
            return error.BaseDecompositionMismatch;
        }
        // Every arrowhead is accounted for exactly once: fed, exempt, or
        // in one of the violation buckets.
        try testing.expect(c.c_base_label + baseViolationBuckets(c) <= c.n_arrow_cells);
    };
}

// -- Mirror pins -------------------------------------------------------------

const all_occupants = [_]lattice.Occupant{
    .empty,
    .{ .node_interior = 1 },
    .{ .node_border = .{ .node = 1, .role = .edge_n } },
    .{ .cluster_border = .{ .cluster = 0, .role = .edge_n } },
    .{ .edge_segment = .{ .edge = 2, .kind = .solid } },
    .{ .edge_segment = .{ .edge = 2, .kind = .invisible } },
    .{ .arrowhead = .{ .dir = .south, .edge = 2 } },
    .{ .label_char = 'x' },
    .label_cont,
};

const all_dirs = [_]lattice.Dir4{ .north, .east, .south, .west };

test "the mirror matrices below enumerate every Occupant variant" {
    // A hand-written literal cannot be checked the way a switch is: without
    // this, a new Occupant would join the lattice while every drift pin
    // below kept passing without ever having seen it.
    inline for (@typeInfo(lattice.Occupant).@"union".fields) |f| {
        var seen = false;
        for (all_occupants) |occ| seen = seen or std.mem.eql(u8, @tagName(occ), f.name);
        if (!seen) std.debug.print("Occupant.{s} missing from all_occupants\n", .{f.name});
        try testing.expect(seen);
    }
}

test "cell.isReal mirrors reconcile.isRealConnection over every occupant" {
    for (all_occupants) |occ| {
        const c = lattice.Cell{ .occupant = occ, .neighbours = .{} };
        try testing.expectEqual(reconcile.isRealConnection(occ), cell.isReal(cell.classify(c)));
    }
}

test "cell.gapReprieve mirrors reconcile.bitIsPhantom over a mask x occupant matrix" {
    // The mirrored branch is the one the audit actually uses: the adjacent
    // cell is EMPTY and the question is whether the run resumes one step
    // further along the axis. (When the adjacent cell is real, reconcile
    // answers "not phantom" without walking, and no tiling check calls
    // gapReprieve there.)
    var buf: [25]lattice.Cell = undefined;
    for (all_dirs) |d| {
        for (all_occupants) |occ| {
            var m: u5 = 0;
            while (m < 16) : (m += 1) {
                for (&buf) |*c| c.* = lattice.Cell.empty;
                var lat = lattice.Lattice{ .width = 5, .height = 5, .cells = &buf };
                lat.at(2, 2).* = .{
                    .occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid } },
                    .neighbours = lattice.Neighbours.fromMask(@intCast(m)),
                };
                // Two steps along `d` from the centre of a 5x5 is always
                // in bounds; the cell between them stays empty.
                const two: struct { x: u32, y: u32 } = switch (d) {
                    .north => .{ .x = 2, .y = 0 },
                    .south => .{ .x = 2, .y = 4 },
                    .west => .{ .x = 0, .y = 2 },
                    .east => .{ .x = 4, .y = 2 },
                };
                lat.at(two.x, two.y).* = .{ .occupant = occ, .neighbours = lattice.Neighbours.fromMask(@intCast(m)) };

                const v = cell.View.init(&lat);
                try testing.expectEqual(!reconcile.bitIsPhantom(&lat, 2, 2, d), v.gapReprieve(2, 2, d));
            }
        }
    }
}

test "the base ladder's fed/exempt steps mirror arrow_base.baseFeedsArrow" {
    var buf: [9]lattice.Cell = undefined;
    for (all_occupants) |occ| {
        for (all_dirs) |tip| {
            var m: u5 = 0;
            while (m < 16) : (m += 1) {
                for (&buf) |*c| c.* = lattice.Cell.empty;
                var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };
                lat.at(1, 1).* = .{ .occupant = occ, .neighbours = lattice.Neighbours.fromMask(@intCast(m)) };
                const v = cell.View.init(&lat);
                const t = v.at(1, 1).?;
                // The audit's steps 2 and 3, in that order.
                const audit_fed = t.kind == .glyph or (t.mask & cell.intoArrowBit(tip) != 0);
                try testing.expectEqual(arrow_base.baseFeedsArrow(lat.atConst(1, 1), tip), audit_fed);
            }
        }
    }
}

test "sideFed mirrors raster/arrow_base.sideFed over an occupant x mask matrix" {
    var buf: [9]lattice.Cell = undefined;
    for (all_dirs) |tip| {
        for (all_occupants) |occ| {
            var m: u5 = 0;
            while (m < 16) : (m += 1) {
                for (&buf) |*c| c.* = lattice.Cell.empty;
                var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };
                lat.at(1, 1).* = .{ .occupant = .{ .arrowhead = .{ .dir = tip, .edge = 0 } }, .neighbours = .{} };
                // Populate BOTH perpendicular neighbours so the "either
                // probe fires" disjunction is exercised, then each alone.
                const perp = cell.perpendicular(tip);
                for ([3]u2{ 0, 1, 2 }) |which| {
                    for (&buf) |*c| c.* = lattice.Cell.empty;
                    lat.at(1, 1).* = .{ .occupant = .{ .arrowhead = .{ .dir = tip, .edge = 0 } }, .neighbours = .{} };
                    const nb = lattice.Neighbours.fromMask(@intCast(m));
                    for (perp, 0..) |p, i| {
                        if (which != 2 and which != i) continue;
                        const q = cell.step(1, 1, p, 3, 3).?;
                        lat.at(q.x, q.y).* = .{ .occupant = occ, .neighbours = nb };
                    }
                    const v = cell.View.init(&lat);
                    try testing.expectEqual(arrow_base.sideFed(&lat, 1, 1, tip), arrows.sideFed(v, 1, 1, tip));
                }
            }
        }
    }
}

// -- Adversarial fixtures ----------------------------------------------------

/// Assert the audit finds nothing to complain about, printing the whole
/// counts line when it does — a bare "expected 0" would say nothing about
/// WHICH law fired.
fn expectSilent(a: std.mem.Allocator, source: []const u8, width: u32) !void {
    const r = try render(a, source, width);
    const c = scan.run(a, r.ctx());
    if (c.defectTotal() != 0) {
        var buf: [counts.line_buf_len]u8 = undefined;
        std.debug.print("source:\n{s}{s}\n", .{ source, c.writeLine(&buf) });
        return error.UnexpectedDefect;
    }
}

test "the calibration floor: chains, fans and clusters are defect-free" {
    const fixtures = [_][]const u8{
        // TD-CHAIN and LR-CHAIN: the simplest thing the renderer does.
        "flowchart TD\n  A --> B\n  B --> C\n  C --> D\n",
        "flowchart LR\n  A --> B\n  B --> C\n  C --> D\n",
        // FAN-BUSBAR: one trunk, many taps, ids shared across the strip.
        "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n  A --> E\n  A --> F\n",
        "flowchart TD\n  B --> A\n  C --> A\n  D --> A\n  E --> A\n",
        // SUBROUTINE and other shapes: inner walls inside the interior.
        "flowchart TD\n  A[[Sub]] --> B{Choice}\n  B --> C((Round))\n",
        // CROSS-MODE frame welds and nested frames.
        "flowchart TD\n  subgraph S\n    A --> B\n  end\n  B --> C\n  C --> A\n",
        "flowchart LR\n  subgraph Outer\n    subgraph Inner\n      A --> B\n    end\n    B --> C\n  end\n  C --> D\n",
        // Self-loops, labels, and an invisible link in one diagram.
        "flowchart TD\n  A -->|go| A\n  A ~~~ B\n  A -->|stop| B\n",
    };
    for (fixtures) |source| for ([_]u32{ 40, 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try expectSilent(arena.allocator(), source, width);
    };
}

test "every terminal abutment a real render makes is a convention" {
    // The acceptance gate for the terminal law. Chains are the shape it sees
    // most of, so they are named explicitly alongside the wider corpus:
    // if a plain `A --> B` chain filed a defect here, the law would be
    // measuring the renderer's conventions instead of its mistakes.
    const chains = [_][]const u8{
        "flowchart TD\n  A --> B\n  B --> C\n  C --> D\n",
        "flowchart LR\n  A --> B\n  B --> C\n  C --> D\n",
    };
    for (chains ++ corpus) |source| for ([_]u32{ 40, 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const c = scan.run(a, r.ctx());
        // Every render lands ink on a ring somewhere.
        try testing.expect(c.n_term_abut > 0);
        if (c.d_term_node_corner != 0 or c.d_term_frame_arrow != 0) {
            var buf: [counts.line_buf_len]u8 = undefined;
            std.debug.print("source:\n{s}{s}\n", .{ source, c.writeLine(&buf) });
            return error.TerminalDefect;
        }
    };
}

test "the expectation tier finds every declared terminal and arrowhead" {
    for (corpus) |source| for ([_]u32{ 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const c = scan.run(a, r.ctx());

        // The census must agree with the geometry it was derived from.
        try testing.expectEqual(@as(u32, @intCast(r.sketch.nodes.len)), c.m_sketch_nodes);
        try testing.expectEqual(@as(u32, @intCast(r.graph.nodes.len)), c.m_graph_nodes);
        // Cross-instrument agreement on the label census: a mismatch here
        // would be an audit bug, not a renderer one.
        try testing.expectEqual(@as(u32, 0), c.u_label_census_mismatch);
        try testing.expectEqual(@as(u32, 0), c.u_audit_oom);
        try testing.expect(c.n_edges_declared <= c.m_sketch_edges);
    };
}

test "cross mode: frame welds move from the defect bucket to the convention bucket" {
    // The `cross` notation welds edges INTO subgraph borders by design;
    // `bridge` refuses that fusion outright, so a surviving frame arm
    // there is a leak. Same source, same geometry, opposite verdicts —
    // and the audit must read the mode it was actually rendered in.
    const clustered = [_][]const u8{
        "flowchart TD\n  subgraph S\n    A --> B\n  end\n  B --> C\n  C --> A\n",
        "flowchart TD\n  subgraph S1\n    A --> B\n  end\n  subgraph S2\n    C --> D\n  end\n  A --> D\n  C --> B\n",
        "flowchart LR\n  subgraph Outer\n    subgraph Inner\n      A --> B\n    end\n    B --> C\n  end\n  C --> D\n",
    };
    for (clustered) |source| for ([_]u32{ 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try renderMode(a, source, width, .cross);
        const c = scan.run(a, r.ctx());
        try testing.expectEqual(@as(u32, 1), c.n_mode_cross);
        // Under `cross`, no frame arm may be filed as foreign.
        try testing.expectEqual(@as(u32, 0), c.d_frame_arm_foreign);
        if (c.defectTotal() != 0) {
            var buf: [counts.line_buf_len]u8 = undefined;
            std.debug.print("source:\n{s}{s}\n", .{ source, c.writeLine(&buf) });
            return error.UnexpectedDefect;
        }
    };
}

test "an all-ASCII render grows no continuation cells" {
    // The ASCII byte-identity argument, mechanically: `labels.cellSpan` is
    // 1 for every ASCII codepoint, so every writer advance is the one it
    // always was and no continuation can exist. A failure here means an
    // ASCII render moved.
    for (corpus) |source| for ([_]u32{ 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        for (r.report.lattice.cells) |c| switch (c.occupant) {
            .label_cont => return error.AsciiRenderGrewAContinuation,
            else => {},
        };
    };
}

test "a wide-label render claims exactly the columns it paints" {
    // The acceptance criterion for the EAW writer fix stated in the
    // audit's own vocabulary: every wide glyph now holds both the cells it
    // paints, so no row paints more columns than it has cells.
    const wide = [_][]const u8{
        "flowchart TD\n  A[日本語] --> B[設定]\n",
        "flowchart LR\n  A[日本語] -->|ラベル| B[設定]\n",
        "flowchart TD\n  subgraph S[\"日本語設定\"]\n    A[入力] --> B[出力]\n  end\n  B --> C\n",
    };
    for (wide) |source| for ([_]u32{ 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const c = scan.run(a, r.ctx());
        try testing.expect(c.m_wide_label_cells > 0);
        try testing.expectEqual(@as(u32, 0), c.m_row_col_overflow);
    };
}
