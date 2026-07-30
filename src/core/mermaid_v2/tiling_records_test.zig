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
const fanrole = @import("tiling/fanrole.zig");

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
///
/// The last three are the fans the router does NOT lay down as a
/// first-class rail — a fan-IN, a fan declined for mixed stroke kinds, and
/// one wide enough to wrap into a grid at w=60. They are here because the
/// membership records for those come from the edge walk instead of the
/// bus-bar rasterizer, and a corpus of rails alone would leave that writer
/// unexercised.
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
    "flowchart TD\n  A --> D\n  B --> D\n  C --> D\n",
    "flowchart TD\n  A --> B\n  A -.-> C\n  A ==> D\n",
    "flowchart TD\n  A --> B1\n  A --> B2\n  A --> B3\n  A --> B4\n  A --> B5\n  A --> B6\n  A --> B7\n  A --> B8\n",
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

test "the frame-bridge tallies and the per-cell intrusion records count the same events" {
    // The frame-solid ruling has two outcomes and counts them in aggregate;
    // the side table names the edge and the position of each one. The two
    // instruments are written at the same two sites, so they must agree
    // exactly — and a third site added without a record is precisely what
    // this catches.
    var bridges_seen: u32 = 0;
    var refusals_seen: u32 = 0;
    for (corpus) |source| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        var bridged: u32 = 0;
        var refused: u32 = 0;
        for (r.report.lattice.aux) |rec| {
            if (rec.kind != .intrusion) continue;
            switch (@as(lattice.IntrusionKind, @enumFromInt(rec.detail))) {
                .bridge => bridged += 1,
                .fusion_refused => refused += 1,
            }
        }
        const x = r.report.crossings;
        if (bridged != x.b_frame_bridge or refused != x.b_border_fusion_refused) {
            std.debug.print(
                "source:\n{s}tallies: bridge={d} refused={d}; records: bridge={d} refused={d}\n",
                .{ source, x.b_frame_bridge, x.b_border_fusion_refused, bridged, refused },
            );
            return error.IntrusionTallyMismatch;
        }
        bridges_seen += bridged;
        refusals_seen += refused;
    };
    // Agreement at zero would be no evidence at all: the corpus has to
    // actually drive an edge through a subgraph frame.
    try testing.expect(bridges_seen + refusals_seen > 0);
}

test "every rail-membership record names an edge the fan actually serves" {
    // A membership record is a claim about geometry the Cell cannot hold,
    // so it has to be checkable against the geometry: the named edge must
    // be a member of a fan of the recorded polarity, and no record may
    // restate the id its own cell carries.
    var rail_members: u32 = 0;
    var peer_members: u32 = 0;
    for (corpus) |source| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const lat = r.report.lattice;
        for (lat.aux) |rec| {
            switch (rec.kind) {
                .rail_member, .tap => {},
                else => continue,
            }
            const polarity: lattice.RailPolarity = @enumFromInt(rec.detail);
            // A `.tap` names a branch, which only a first-class rail
            // declares; a `.rail_member` may also come from a peer-drawn fan.
            const served = if (rec.kind == .tap)
                railTap(r.sketch, rec.value, polarity)
            else
                railTap(r.sketch, rec.value, polarity) or fanPeer(r.sketch, rec.value, polarity);
            if (!served) {
                std.debug.print(
                    "source:\n{s}{s} record names edge {d} ({s}), which no fan serves\n",
                    .{ source, @tagName(rec.kind), rec.value, @tagName(polarity) },
                );
                return error.UnservedRailRecord;
            }
            if (rec.kind == .rail_member) {
                rail_members += 1;
                if (!railTap(r.sketch, rec.value, polarity)) peer_members += 1;
                // Anti-desync: a membership record may never restate the id
                // its own cell carries.
                switch (lat.cells[rec.cell].occupant) {
                    .edge_segment => |seg| try testing.expect(seg.edge != rec.value),
                    .arrowhead => |head| try testing.expect(head.edge != rec.value),
                    else => {},
                }
            }
        }
    };
    // Both producers must actually be exercised, or this test would pass by
    // checking nothing: the bus-bar rasterizer files for first-class rails,
    // the edge walk for the peer-drawn fans (declined and grid-wrapped).
    try testing.expect(rail_members > 0);
    try testing.expect(peer_members > 0);
}

/// True when `edge` is a tap of a bus-bar rail of `polarity`.
fn railTap(s: sketch.Sketch, edge: u32, polarity: lattice.RailPolarity) bool {
    for (s.busbars) |bb| {
        const fan_in = bb.role == .fan_in_rail or bb.role == .fan_in_dropper;
        if ((polarity == .in) != fan_in) continue;
        for (bb.taps) |tap| if (tap.edge == edge) return true;
    }
    return false;
}

/// True when `edge` is a peer-drawn fan member of `polarity` — a fan the
/// router laid down as N sibling polylines rather than one owned rail.
fn fanPeer(s: sketch.Sketch, edge: u32, polarity: lattice.RailPolarity) bool {
    for (s.edges) |ep| {
        if (ep.id != edge) continue;
        return switch (ep.role) {
            .fan_out_rail, .fan_out_dropper => polarity == .out,
            .fan_in_rail, .fan_in_dropper => polarity == .in,
            else => false,
        };
    }
    return false;
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

test "the fan-role shadow reaches both readings on real renders and moves nothing" {
    // The comparator is the instrument that decides whether the post-walk
    // stamping pass can be replaced by the producers' own records, so it has
    // to be shown running on real geometry: reaching cells where the two
    // readings AGREE (or it would be measuring nothing), reaching cells a
    // first-class rail owns (the population it must decline to judge), and
    // leaving the shipped lattice exactly as it found it.
    //
    // The residual divergence is deliberately NOT pinned to a number here.
    // It is the corpus-wide gate the harness measures, and it moves whenever
    // fan routing does; freezing it in a unit test would turn an instrument
    // reading into a rule.
    var agreements: u32 = 0;
    var rail_owned: u32 = 0;
    for (corpus) |source| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const before = try a.dupe(lattice.Cell, r.report.lattice.cells);

        const c = fanrole.run(.{ .sketch = r.sketch, .lat = &r.report.lattice });
        try testing.expectEqualSlices(lattice.Cell, before, r.report.lattice.cells);

        // Bookkeeping identity, per family: the mask dimension is judged on
        // exactly the cells whose role the two readings agree on.
        inline for (.{ "fan_out", "fan_in" }) |family| {
            const b = @field(c, family);
            try testing.expectEqual(b.role_match, b.mask_match + b.mask_mismatch);
            try testing.expect(b.pivot_unresolved <= b.mask_match);
        }
        agreements += c.fan_out.role_match + c.fan_in.role_match;
        rail_owned += c.rail_owned;
    };
    try testing.expect(agreements > 0);
    try testing.expect(rail_owned > 0);
}
