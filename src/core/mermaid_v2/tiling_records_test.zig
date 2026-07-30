//! Cross-instrument checks for the lattice side table, run against REAL
//! renders: parse -> permits -> select -> rasterize -> scan.
//!
//! WHY THIS EXISTS. The side table is the audit's only source of facts the
//! Cell grid cannot hold — which edges are anonymous at a shared cell,
//! whose label a glyph is, which edge attached to a border. Those records
//! are written by the raster and read by the tiling zone, and NEITHER side
//! can check the other: raster cannot see the audit, and the tiling zone is
//! forbidden from importing raster at all. So the agreement is pinned here,
//! at the root, where both are reachable — the same arrangement, and the
//! same lint-row grant, as `tiling_crosscheck_test.zig`.
//!
//! Split from that file only to keep both under the 500-line cap; the three
//! root-level tiling tests are one instrument.

const std = @import("std");
const lattice = @import("lattice.zig");
const sem_graph = @import("sem_graph.zig");
const sketch = @import("sketch.zig");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");
const scan = @import("tiling/scan.zig");
const cell = @import("tiling/cell.zig");

const testing = std.testing;

const Rendered = struct {
    graph: sem_graph.SemGraph,
    sketch: sketch.Sketch,
    report: raster.RasterReport,

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

/// The production path with the side table collected, exactly as the
/// composition root drives it.
fn render(a: std.mem.Allocator, source: []const u8, width: u32) !Rendered {
    const graph = try parse(a, source);
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const flat = !built.report.join_permits_skipped_clustered;
    const winner = try select.choose(a, graph, &plan, flat, width, false, false);
    const report = try raster.rasterize(a, winner.sketch, .bridge, .{ .collect_aux = true });
    return .{ .graph = graph, .sketch = winner.sketch, .report = report };
}

/// Shapes that exercise every writer of a record: shared cells, crossings,
/// fans (rails and taps), labels of all three owner kinds, and clusters.
const corpus = [_][]const u8{
    "flowchart TD\n  A --> B\n  B --> C\n",
    "flowchart LR\n  A --> B\n  B --> C\n  C --> D\n",
    "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n  A --> E\n",
    "flowchart TD\n  A -->|yes| B\n  A -->|no| C\n",
    "flowchart TD\n  A --> A\n  A --> B\n",
    "flowchart TD\n  A ~~~ B\n  B --> C\n",
    "flowchart TD\n  subgraph S[\"Stage one\"]\n    A --> B\n  end\n  B --> C\n",
    "flowchart TD\n  subgraph S1\n    A --> B\n  end\n  subgraph S2\n    C --> D\n  end\n  A --> D\n  C --> B\n",
    "flowchart TD\n  A[Start] --> B{Check}\n  B -->|yes| C[Run]\n  B -->|no| D[Stop]\n  C --> E[Done]\n  D --> E\n",
};

const widths = [_]u32{ 60, 120 };

test "suppressed carriers and the crossing tallies count the same events" {
    // The crossing rule's THREE refusal classes are counted in aggregate by
    // the rasterizer and per-cell by the side table. Each `true` return
    // from a crossing predicate suppresses exactly one edge at exactly one
    // position, so the two instruments must agree exactly — and if a
    // refusal path is ever added without a record, this is what says so.
    for (corpus) |source| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const x = r.report.crossings;
        const refusals = x.legal_crossing + x.foreign_junction_violation + x.arrowhead_transit_violation;

        var suppressed: u32 = 0;
        for (r.report.lattice.aux) |rec| {
            if (rec.kind != .carrier) continue;
            if (rec.detail == @intFromEnum(lattice.CarrierKind.suppressed)) suppressed += 1;
        }
        if (suppressed != refusals) {
            std.debug.print(
                "source:\n{s}refusals={d} suppressed_records={d}\n",
                .{ source, refusals, suppressed },
            );
            return error.CarrierTallyMismatch;
        }
    };
}

test "a merged carrier never restates the id its cell already carries" {
    // The anti-desync law, mechanically: a record may only carry a fact the
    // Cell cannot express. A merged carrier naming the cell's OWN occupant
    // would be a second, staleable copy of a Cell field.
    for (corpus) |source| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const lat = r.report.lattice;
        for (lat.aux) |rec| {
            if (rec.kind != .carrier) continue;
            if (rec.detail != @intFromEnum(lattice.CarrierKind.merged)) continue;
            const c = lat.cells[rec.cell];
            const named: ?u32 = switch (c.occupant) {
                .edge_segment => |seg| seg.edge,
                .arrowhead => |h| h.edge,
                else => null,
            };
            // Later passes may replace the occupant entirely (a label, a
            // weld), which is exactly why the record survives; the law only
            // bites when the cell still names an edge.
            if (named) |id| try testing.expect(id != rec.value);
        }
    };
}

test "every painted label glyph has a recorded owner, and the owner exists" {
    for (corpus) |source| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const lat = r.report.lattice;
        const v = cell.View.init(&lat);

        var y: u32 = 0;
        while (y < lat.height) : (y += 1) {
            var x: u32 = 0;
            while (x < lat.width) : (x += 1) {
                if (lat.atConst(x, y).occupant != .label_char) continue;
                const owner = v.at(x, y).?.labelOwner() orelse {
                    std.debug.print("source:\n{s}unowned label glyph at ({d},{d})\n", .{ source, x, y });
                    return error.UnownedLabelGlyph;
                };
                if (!ownerExists(r.sketch, owner)) {
                    std.debug.print(
                        "source:\n{s}label at ({d},{d}) names a {s} {d} the Sketch does not declare\n",
                        .{ source, x, y, @tagName(owner.kind), owner.id },
                    );
                    return error.UnknownLabelOwner;
                }
            }
        }
    };
}

/// True when the Sketch declares the entity a `label_owner` record names.
/// The record is a claim about the geometry, so it has to be checkable
/// against it.
fn ownerExists(s: sketch.Sketch, owner: cell.LabelOwner) bool {
    switch (owner.kind) {
        .node => {
            for (s.nodes) |np| if (np.id == owner.id) return true;
        },
        .cluster => {
            for (s.clusters) |cf| if (cf.id == owner.id) return true;
        },
        .edge => {
            for (s.edges) |ep| if (ep.id == owner.id) return true;
            for (s.busbars) |bb| for (bb.taps) |tap| {
                if (tap.edge == owner.id) return true;
            };
        },
    }
    return false;
}

test "the terminal law's departure verdict comes from the records, not the mask" {
    // The flip, proved on the instrument rather than argued: audit the same
    // shipped lattice twice, once with its side table and once with the
    // table hidden. Every departure must move into the unrecorded-arm
    // bucket, and NOTHING else on the line may move — if the verdict were
    // still being read off the neighbour mask, both runs would agree.
    var departures_seen: u32 = 0;
    for (corpus) |source| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const with = scan.run(a, r.ctx());

        var blind = r;
        blind.report.lattice.aux = &.{};
        const without = scan.run(a, blind.ctx());

        departures_seen += with.c_term_departure_recorded;
        try testing.expectEqual(@as(u32, 0), with.c_term_ring_arm_unrecorded);
        try testing.expectEqual(@as(u32, 0), without.c_term_departure_recorded);
        try testing.expectEqual(with.c_term_departure_recorded, without.c_term_ring_arm_unrecorded);

        // Same pairs, same everything else: only the two departure buckets
        // trade places.
        try testing.expectEqual(with.n_term_abut, without.n_term_abut);
        try testing.expectEqual(with.defectTotal(), without.defectTotal());
        try testing.expectEqual(with.c_term_node_ns_arrow, without.c_term_node_ns_arrow);
        try testing.expectEqual(with.c_term_frame_bare, without.c_term_frame_bare);
    };
    // Counted over the corpus rather than per render: an LR/RL flow has NO
    // recorded departures at all, because the port stroke is issued for
    // vertical exits only (east/west would spoil the `|` source border).
    try testing.expect(departures_seen > 0);
}

test "collecting the side table changes no painted cell" {
    // The channel is opt-in, and the score path runs with it off: if
    // collecting it moved a single cell, every candidate the selector
    // priced would have been priced against a different render than the one
    // that ships.
    for (corpus) |source| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const graph = try parse(a, source);
        const built = try permits.build(a, graph, .joined);
        const plan = built.plan;
        const flat = !built.report.join_permits_skipped_clustered;
        const winner = try select.choose(a, graph, &plan, flat, width, false, false);

        const on = try raster.rasterize(a, winner.sketch, .bridge, .{ .collect_aux = true });
        const off = try raster.rasterize(a, winner.sketch, .bridge, .{});

        try testing.expect(on.lattice.aux.len > 0);
        try testing.expectEqual(@as(usize, 0), off.lattice.aux.len);
        try testing.expectEqualSlices(lattice.Cell, off.lattice.cells, on.lattice.cells);
    };
}
