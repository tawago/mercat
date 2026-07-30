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
const lattice = @import("lattice.zig");
const sem_graph = @import("sem_graph.zig");
const sketch = @import("sketch.zig");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");
const paint = @import("paint.zig");
const scan = @import("tiling/scan.zig");
const counts = @import("tiling/counts.zig");
const cell = @import("tiling/cell.zig");

const testing = std.testing;

/// One real render, carried far enough to audit.
const Rendered = struct {
    graph: sem_graph.SemGraph,
    sketch: sketch.Sketch,
    report: raster.RasterReport,

    /// Pointer receiver on purpose: `Ctx.lat` aliases THIS frame's
    /// lattice, so the audit must never be handed the address of a
    /// by-value parameter copy.
    fn ctx(self: *const Rendered) scan.Ctx {
        return .{
            .graph = self.graph,
            .sketch = self.sketch,
            .lat = &self.report.lattice,
            .mode = .bridge,
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
    const graph = try parse(a, source);
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const flat = !built.report.join_permits_skipped_clustered;
    const winner = try select.choose(a, graph, &plan, flat, width, false, false);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    return .{ .graph = graph, .sketch = winner.sketch, .report = report };
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
    // The adversarial fixture for R1: on clustered renders the crossing
    // suppression pass is inert (its permits are skipped) and the edge
    // writer OR-merges foreign transversal bits into arrowhead cells. If
    // any of that legal population landed in a defect bucket, the audit
    // would be measuring the renderer's conventions instead of its
    // mistakes. The answer to a legal case is a new `c_` bucket, never a
    // filter — so this asserts ZERO, not "small".
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

test "the whole corpus is free of arrowhead lateral defects" {
    // The calibration floor: every shape in `corpus`, at both widths.
    for (corpus) |source| for ([_]u32{ 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const c = scan.run(a, r.ctx());
        if (c.defectTotal() != 0) {
            var buf: [counts.line_buf_len]u8 = undefined;
            std.debug.print("source:\n{s}{s}\n", .{ source, c.writeLine(&buf) });
            return error.UnexpectedDefect;
        }
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
