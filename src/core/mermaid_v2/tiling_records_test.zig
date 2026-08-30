//! Cross-instrument checks for real renders, where raster and tiling can meet.
const std = @import("std");
const ledger = @import("base/ledger.zig");
const lattice = @import("lattice.zig");
const sem_graph = @import("sem_graph.zig");
const sketch = @import("sketch.zig");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");
const paint = @import("paint.zig");
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

/// Production path with the side table collected.
fn render(a: std.mem.Allocator, source: []const u8, width: u32) !Rendered {
    const graph = try parse(a, source);
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const winner = try select.choose(a, graph, &plan, width, false, false, .bridge);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    return .{ .graph = graph, .sketch = winner.sketch, .report = report };
}

/// Shapes that exercise every writer of a record: shared cells, crossings,
/// fans (rails and taps), labels of all three owner kinds, and clusters.
///
/// The fan-IN, the fan declined for mixed stroke kinds and the one wide
/// enough to wrap into a grid at w=60 are here because the membership
/// records for those come from the edge walk instead of the rail
/// rasterizer, and a corpus of rails alone would leave that writer
/// unexercised. The last entry also stresses the construction gate: its
/// incompatible peers must remain private rather than share incidentally.
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
    // The kept dotted class {C1, C2} is uniformly forward one-way, so the
    // clustered fan holds its star licence and files final rail claims.
    "flowchart TD\n  subgraph S1\n    A <-->|a longer label 0| C0\n    A -.->|a longer label 1| C1\n    A -.-> C2\n    A --- C3\n  end\n  C0 -.-> OUT\n  OUT -.- A\n",
    // Same shape with a mixed kept class {arrow-free C1, forward C2}: the
    // star licence refuses it (non-blocking member) and every member routes
    // privately — the record shape a refused clustered fan files is pinned
    // by "a refused clustered fan files no rail claim ..." below.
    refused_clustered_fan_source,
};

const widths = [_]u32{ 60, 120 };

/// The original mixed-class clustered fan: `A -.- C1` is arrow-free while
/// `A -.-> C2` is forward one-way, so the kept dotted class mixes a
/// non-blocking member with a directional one and loses the star licence.
const refused_clustered_fan_source =
    "flowchart TD\n  subgraph S1\n    A <-->|a longer label 0| C0\n    A -.-|a longer label 1| C1\n    A -.-> C2\n    A --- C3\n  end\n  C0 -.-> OUT\n  OUT -.- A\n";

test "a refused clustered fan files no rail claim and routes every member privately" {
    for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, refused_clustered_fan_source, width);
        // No shared ink anywhere: the refused fan keeps no rail, files no
        // claim, and the lone non-fan edges never form one.
        try testing.expectEqual(@as(usize, 0), r.sketch.rails.len);
        try testing.expectEqual(@as(usize, 0), r.sketch.rail_claims.len);
        try testing.expectEqual(@as(usize, 0), r.report.lattice.rail_claims.len);
        // Every declared edge still owns private geometry (traceability): one routed
        // path per edge, none fused, none discharged, none lost.
        try testing.expectEqual(r.graph.edges.len, r.sketch.edges.len);
        for (r.sketch.edges) |edge| try testing.expect(edge.polyline.len != 0);
    }
}

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
            if (rec.detail == @intFromEnum(lattice.CarrierKind.suppressed)) continue;
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
            for (s.rails) |rail| for (rail.taps) |tap| {
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

        departures_seen += with.c_term_port_recorded;
        try testing.expectEqual(@as(u32, 0), with.c_term_ring_arm_unrecorded);
        try testing.expectEqual(@as(u32, 0), without.c_term_port_recorded);
        try testing.expectEqual(with.c_term_port_recorded, without.c_term_ring_arm_unrecorded);

        // Same pairs; the record-based buckets trade places. The rings
        // family is record-based too (uniform port erasure files a `.port`
        // for every border arm it merges), so blinding the table moves each
        // port-explained arm into ITS unrecorded bucket — a defect there,
        // exactly because a real unexplained arm is one.
        try testing.expectEqual(with.n_term_abut, without.n_term_abut);
        try testing.expectEqual(with.c_border_arm_port, without.d_border_arm_unrecorded);
        try testing.expectEqual(
            with.defectTotal() + with.c_border_arm_port,
            without.defectTotal(),
        );
        try testing.expectEqual(with.c_term_node_ns_arrow, without.c_term_node_ns_arrow);
        try testing.expectEqual(with.c_term_frame_bare, without.c_term_frame_bare);
    };
    // Counted over the corpus rather than per render, out of caution for
    // degenerate entries (an all-invisible flow records nothing).
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
    // checking nothing: the rail rasterizer files for first-class rails,
    // the edge walk for the peer-drawn fans (declined and grid-wrapped).
    try testing.expect(rail_members > 0);
    try testing.expect(peer_members > 0);
}

/// True when `edge` is a tap of a rail of `polarity`.
fn railTap(s: sketch.Sketch, edge: u32, polarity: lattice.RailPolarity) bool {
    for (s.rails) |rail| {
        const fan_in = rail.role == .fan_in_rail or rail.role == .fan_in_dropper;
        if ((polarity == .in) != fan_in) continue;
        for (rail.taps) |tap| if (tap.edge == edge) return true;
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

fn finalCarrier(s: sketch.Sketch, id: u32) bool {
    for (s.edges) |edge| if (edge.id == id) return true;
    for (s.rails) |rail| for (rail.taps) |tap| if (tap.edge == id) return true;
    return false;
}

test "AUX and RailClaim metadata preserve production cells and audit counts" {
    var first_class_claims = false;
    var peer_claims = false;
    var clustered_final_claims = false;
    for (corpus) |source| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const graph = try parse(a, source);
        const built = try permits.build(a, graph, .joined);
        const winner = try select.choose(a, graph, &built.plan, width, false, false, .bridge);
        const on = try raster.rasterize(a, winner.sketch, .bridge);
        try testing.expect(on.lattice.aux.len > 0);
        if (winner.sketch.rail_claims.len != 0) {
            try testing.expectEqual(winner.sketch.rail_claims.ptr, on.lattice.rail_claims.ptr);
            const on_counts = scan.run(a, (&Rendered{ .graph = graph, .sketch = winner.sketch, .report = on }).ctx());
            var blind = on.lattice;
            blind.rail_claims = &.{};
            try testing.expectEqualStrings(try paint.paint(a, on.lattice, width), try paint.paint(a, blind, width));
            var no_claims = winner.sketch;
            no_claims.rail_claims = &.{};
            const removed = try raster.rasterize(a, no_claims, .bridge);
            try testing.expectEqualSlices(lattice.Cell, on.lattice.cells, removed.lattice.cells);
            if (on_counts.c_rail_star_valid == on_counts.n_rail_claims) {
                if (winner.sketch.rails.len == 0) peer_claims = true else first_class_claims = true;
            }
            if (graph.clusters.len != 0) {
                for (on.lattice.rail_claims) |claim| for (claim.members) |member| try testing.expect(finalCarrier(winner.sketch, member.edge));
                clustered_final_claims = true;
            }
        }
    };
    try testing.expect(first_class_claims);
    try testing.expect(peer_claims);
    try testing.expect(clustered_final_claims);
}

test "a peer-drawn rail role and its membership record are one event" {
    // The write-time role stamp and membership record remain one observation.
    // Authoritative claims admit only a star-law-valid family to shared ink.
    var roles_checked: u32 = 0;
    var records_without_role: u32 = 0;
    for (corpus) |source| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const r = try render(a, source, width);
        const lat = r.report.lattice;
        var y: u32 = 0;
        while (y < lat.height) : (y += 1) {
            var x: u32 = 0;
            while (x < lat.width) : (x += 1) {
                // A first-class rail writes both role and geometry itself;
                // its cells are the rail rasterizer's, not the walk's.
                if (onOwnedRail(r.sketch, x, y)) continue;
                const c = lat.atConst(x, y).*;
                const stamped = railFamilyAt(lat, x, y);
                const recorded = recordedFamilyAt(lat, x, y);
                if (stamped == null and recorded == null) continue;
                // role ⇒ record of the same family; a record with no role is
                // legal only for a reason the producer states.
                const agree = if (stamped) |fam|
                    recorded == fam
                else
                    recordWithoutRoleIsExplained(c, recorded.?);
                if (!agree) {
                    std.debug.print(
                        "source:\n{s}cell ({d},{d}): role says {?s}, records say {?s} (occupant {s})\n",
                        .{ source, x, y, tagOf(stamped), tagOf(recorded), @tagName(std.meta.activeTag(c.occupant)) },
                    );
                    return error.FanRoleRecordDisagreement;
                }
                if (stamped == null) records_without_role += 1 else roles_checked += 1;
            }
        }
    };
    // The corpus carries peer-drawn shared cells, but the construction gate
    // keeps incompatible peers private. Record-only membership is retained
    // for malformed/manual lattices and covered directly by fan_roles_test
    // "a rider of another family, or of no fan at all, stamps nothing".
    try testing.expect(roles_checked > 0);
    try testing.expectEqual(@as(u32, 0), records_without_role);
}

/// The two — and only two — low-level reasons `fan_roles.markShared` files a
/// `.rail_member` record and then declines to stamp the family's rail role:
/// (1) the occupant carries NO role at all (an `.arrowhead`; the rail
/// rasterizer records on those for the same reason), or (2) the cell's role
/// belongs to the OTHER family — two families met on one cell and a Cell
/// holds exactly one role, so the record is the only place the second
/// membership can be said. Anything else — a record on a plain `.forward`
/// segment, say — means a record was filed where the stamp never looked.
fn recordWithoutRoleIsExplained(c: lattice.Cell, recorded: lattice.RailPolarity) bool {
    const seg = switch (c.occupant) {
        .edge_segment => |q| q,
        else => return true, // (1) role-less occupant
    };
    return switch (seg.role) { // (2) the other family owns this cell's role
        .fan_out_rail, .fan_out_dropper => recorded == .in,
        .fan_in_rail, .fan_in_dropper => recorded == .out,
        else => false,
    };
}

fn tagOf(p: ?lattice.RailPolarity) ?[]const u8 {
    return if (p) |q| @tagName(q) else null;
}

/// The fan family whose SHARED-RUN role the cell at (x, y) carries.
fn railFamilyAt(lat: lattice.Lattice, x: u32, y: u32) ?lattice.RailPolarity {
    return switch (lat.atConst(x, y).occupant) {
        .edge_segment => |seg| switch (seg.role) {
            .fan_out_rail => .out,
            .fan_in_rail => .in,
            else => null,
        },
        else => null,
    };
}

/// The fan family a `.rail_member` record names at (x, y), if any.
fn recordedFamilyAt(lat: lattice.Lattice, x: u32, y: u32) ?lattice.RailPolarity {
    const idx = lat.cellIndex(x, y);
    for (lat.aux) |rec| {
        if (rec.kind != .rail_member or rec.cell != idx) continue;
        return @enumFromInt(rec.detail);
    }
    return null;
}

/// True when (x, y) lies on a first-class rail's own stem or crossbar.
fn onOwnedRail(s: sketch.Sketch, x: u32, y: u32) bool {
    const px: i32 = @intCast(x);
    const py: i32 = @intCast(y);
    for (s.rails) |rail| {
        if (py == rail.crossbar[0].y and px >= rail.crossbar[0].x and px <= rail.crossbar[1].x) return true;
        var i: usize = 0;
        while (i + 1 < rail.stem.len) : (i += 1) {
            const p = rail.stem[i];
            const q = rail.stem[i + 1];
            if (p.x == q.x and p.x == px and py >= @min(p.y, q.y) and py <= @max(p.y, q.y)) return true;
            if (p.y == q.y and p.y == py and px >= @min(p.x, q.x) and px <= @max(p.x, q.x)) return true;
        }
    }
    return false;
}
