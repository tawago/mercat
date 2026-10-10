const std = @import("std");
const ledger = @import("base/ledger.zig");
const bundle_mod = @import("base/bundle.zig");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");
const crossings = @import("raster/crossings.zig");
const lattice = @import("lattice.zig");
const sketch_mod = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");

const testing = std.testing;

const Rendered = struct {
    graph: sem_graph.SemGraph,
    sketch: sketch_mod.Sketch,
    report: raster.RasterReport,
};

fn render(a: std.mem.Allocator, source: []const u8, width: u32) !Rendered {
    const graph = try parse(a, source);
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const winner = try select.choose(a, graph, &plan, width, .bridge);
    const report = try raster.rasterize(a, winner.cand.sketch, .bridge);
    return .{ .graph = graph, .sketch = winner.cand.sketch, .report = report };
}

fn ownerOf(cell: *const lattice.Cell) ?ledger.EdgeId {
    return switch (cell.occupant) {
        .edge_segment => |seg| seg.edge,
        else => null,
    };
}

fn expectNoRasterDefect(report: raster.RasterReport) !void {
    try testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    try testing.expectEqual(@as(u32, 0), report.arrow_base.lateral_arms);
    try testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
    try testing.expectEqual(@as(u32, 0), report.arrow_base.violations);
}

fn arrowheadCells(lat: *const lattice.Lattice) u32 {
    var n: u32 = 0;
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            if (lat.at(x, y).occupant == .arrowhead) n += 1;
        }
    }
    return n;
}

const three_way_port_share =
    \\flowchart TB
    \\  subgraph S1[Group One]
    \\    A
    \\    B
    \\  end
    \\  C ==>|lab9| E
    \\  F -.->|lab3| E
    \\  F --> D
    \\  F ==> A
    \\  F -.-> C
    \\  C -.-> B
    \\  B -->|lab1| C
    \\  E ==>|lab6| F
    \\  F -->|lab4| D
    \\  B -.-> E
    \\  D --> C
    \\  D --> A
    \\  D --> F
    \\
;

test "junction licence: a reconstructed three-way port share keeps exact pair scopes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try render(a, three_way_port_share, 140);

    var found: ?bundle_mod.Bundle = null;
    for (r.sketch.sharing.bundles) |set| {
        if (set.origin == .port_share and set.members.len == 3) found = set;
    }
    const share = found orelse return error.MissingThreeWayPortShare;
    const cells = share.cells orelse return error.MissingPortShareScope;
    const pairs = share.pairwise orelse return error.MissingPairScopes;

    // The share scope is one contiguous vertical run leaving the port.
    for (cells[1..], cells[0 .. cells.len - 1]) |cell, prev| {
        try testing.expectEqual(prev.x, cell.x);
        try testing.expectEqual(prev.y - 1, cell.y);
    }
    // Each pair's scope is a prefix of it, and exactly one pair reaches further than the others.
    try testing.expectEqual(@as(usize, 3), pairs.len);
    var longest: usize = 0;
    for (pairs, 0..) |pair, i| {
        try testing.expect(pair.cells.len <= cells.len);
        for (pair.cells, cells[0..pair.cells.len]) |pc, sc| try testing.expect(pc.x == sc.x and pc.y == sc.y);
        if (pair.cells.len > pairs[longest].cells.len) longest = i;
    }
    const far = pairs[longest].cells[pairs[longest].cells.len - 1];
    const only_share = [_]bundle_mod.Bundle{share};
    for (pairs, 0..) |pair, i| {
        if (i != longest) try testing.expect(pair.cells.len < pairs[longest].cells.len);
        try testing.expectEqual(i == longest, bundle_mod.bundleMembersAt(&only_share, pair.a, pair.b, far));
    }
    try expectNoRasterDefect(r.report);
}

const multilayer =
    \\flowchart TD
    \\    OR[OrderReceived]
    \\    VP[ValidatePayment]
    \\    CI[CheckInventory]
    \\    VA[VerifyAddress]
    \\    FC[FraudCheck]
    \\    RS[ReserveStock]
    \\    US[UpdateShipping]
    \\    AD[ApplyDiscount]
    \\    CC[ChargeCard]
    \\    PI[PackItems]
    \\    GL[GenerateLabel]
    \\    DO[DispatchOrder]
    \\
    \\    OR --> VP
    \\    OR --> CI
    \\    OR --> VA
    \\    VP --> FC
    \\    VP --> AD
    \\    CI --> RS
    \\    CI --> AD
    \\    VA --> US
    \\    VA --> RS
    \\    FC --> CC
    \\    AD --> CC
    \\    AD --> PI
    \\    RS --> PI
    \\    US --> GL
    \\    CC --> DO
    \\    PI --> DO
    \\    GL --> DO
    \\
;

const arrow_ends =
    \\flowchart TD
    \\    Service[Payment Service]
    \\    Ledger[Ledger DB]
    \\    Metrics[Metrics Sink]
    \\    Legacy[Legacy Gateway]
    \\    Queue[Event Queue]
    \\    Worker[Settlement Worker]
    \\
    \\    Service --> Ledger
    \\    Service --o Metrics
    \\    Service --x Legacy
    \\    Service --> Queue
    \\    Queue --> Worker
    \\    Worker <--> Ledger
    \\
;

const stitched_rail_arrowhead =
    \\flowchart TD
    \\subgraph S1
    \\  A1 --> C
    \\  A2 --> C
    \\  A3 --> C
    \\end
    \\subgraph S2
    \\  B1 --> D
    \\  B2 --> D
    \\end
    \\H --> A1
    \\C --> E
    \\C --> H
    \\
;

const crossing_bridges =
    \\graph LR
    \\    subgraph auth-service/
    \\        INDEX[src/index.ts<br/>Entry point]
    \\        PROV[src/provider.ts<br/>Provider config]
    \\        CFG[src/config/]
    \\        ADAPT[src/adapters/account.ts]
    \\        CLAIMS[src/claims/custom-claims.ts]
    \\        INTER[src/interactions/]
    \\        VIEWS[views/*.ejs]
    \\        DATA[data/users.yaml]
    \\    end
    \\    INDEX --> PROV
    \\    PROV --> CFG
    \\    PROV --> ADAPT
    \\    PROV --> CLAIMS
    \\    PROV --> INTER
    \\    INTER --> VIEWS
    \\    ADAPT --> DATA
    \\    subgraph web-app/
    \\        AUTH[contexts/auth-context.tsx]
    \\        ROUTES[routes/_authenticated/]
    \\    end
    \\    AUTH -.->|OIDC flow| PROV
    \\    subgraph api-server/
    \\        COMPOSE[docker-compose.yaml]
    \\        VALID[JWT validation]
    \\    end
    \\    COMPOSE -->|runs| INDEX
    \\    VALID -.->|fetch JWKS| PROV
    \\
;

fn stubCells(lat: *const lattice.Lattice) u32 {
    var n: u32 = 0;
    for (lat.cells) |cell| {
        if (cell.occupant == .edge_segment and @popCount(cell.neighbours.toMask()) == 1) n += 1;
    }
    return n;
}

/// The one double-ended edge's north head must sit right under a node border.
fn expectBidirectionalHeadOnBorder(graph: sem_graph.SemGraph, lat: *const lattice.Lattice) !void {
    var both: ?ledger.EdgeId = null;
    for (graph.edges) |e| if (e.arrow_from != .none and e.arrow_to != .none) {
        both = e.id;
    };
    var north_heads: u32 = 0;
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) switch (lat.atConst(x, y).occupant) {
            .arrowhead => |head| if (head.edge == both.? and head.dir == .north) {
                north_heads += 1;
                try testing.expect(y >= 1 and lat.atConst(x, y - 1).occupant == .node_border);
            },
            else => {},
        };
    }
    try testing.expectEqual(@as(u32, 1), north_heads);
}

const Checks = struct {
    foreign: bool = true,
    transit: bool = true,
    lateral: bool = true,
    lost: bool = true,
    base: bool = true,

    fn expectClean(c: Checks, report: raster.RasterReport) !void {
        if (c.foreign) try testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
        if (c.transit) try testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
        if (c.lateral) try testing.expectEqual(@as(u32, 0), report.arrow_base.lateral_arms);
        if (c.lost) try testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
        if (c.base) try testing.expectEqual(@as(u32, 0), report.arrow_base.violations);
    }
};

fn naturalRaw(candidates: anytype) sketch_mod.Sketch {
    for (candidates) |cand| if (cand.rung == .natural and cand.transform == .raw) return cand.sketch;
    unreachable;
}

test "regression corpus renders with no raster defect" {
    const Case = struct {
        source: []const u8,
        widths: []const u32,
        /// Lay out the declared rung only (no ladder), with production permits.
        natural: bool = false,
        /// Use the production permit resolver instead of joined permits.
        resolve: bool = false,
        stubs: bool = false,
        head_on_border: bool = false,
        /// The defect counters each regression pins (all five by default).
        checks: Checks = .{},
    };
    const cases = [_]Case{
        // Shapes with no foreign meeting.
        .{ .source = "flowchart TD\n  A --> B\n  B --> C\n", .widths = &.{60} },
        .{ .source = "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n", .widths = &.{60} },
        // A render that merges, honestly.
        .{ .source = "flowchart TD\n  A --> C\n  A --> D\n  B --> C\n  B --> E\n", .widths = &.{60} },
        // The two-rail K(2,2): the smallest render that could fabricate a junction.
        .{ .source = "flowchart TD\n  A --> C\n  B --> C\n  A --> D\n  B --> D\n", .widths = &.{60} },
        // flowchart_multilayer_dag_td_12: no one-owner junction, no run that stops in open space.
        .{ .source = multilayer, .widths = &.{ 60, 90, 120 }, .stubs = true, .checks = .{ .transit = false, .lateral = false, .base = false } },
        // flowchart_arrow_ends_td_6: every head drawn into its port, the declared direction kept.
        .{ .source = arrow_ends, .widths = &.{90}, .head_on_border = true, .checks = .{ .foreign = false, .lost = false, .base = false } },
        // Cluster unification: a bridge never transits a stitched rail's arrowhead.
        .{ .source = stitched_rail_arrowhead, .widths = &.{120}, .natural = true, .resolve = true, .checks = .{ .base = false } },
        // Cluster unification: bridges route around each other, not through.
        .{ .source = crossing_bridges, .widths = &.{120}, .resolve = true, .checks = .{ .lost = false, .base = false } },
    };
    for (cases) |c| for (c.widths) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try parse(a, c.source);
        const plan = if (c.resolve) (try select.resolvePermits(a, graph)).plan else (try permits.build(a, graph, .joined)).plan;
        const sketch = if (c.natural) naturalRaw(try select.enumerateAll(a, graph, &plan, w)) else (try select.choose(a, graph, &plan, w, .bridge)).cand.sketch;
        const report = try raster.rasterize(a, sketch, .bridge);
        try c.checks.expectClean(report);
        if (c.stubs) try testing.expectEqual(@as(u32, 0), stubCells(&report.lattice));
        if (c.head_on_border) {
            try testing.expectEqual(graph.direction, sketch.direction);
            try expectBidirectionalHeadOnBorder(graph, &report.lattice);
        }
    };
}

fn edgeId(graph: sem_graph.SemGraph, from: []const u8, to: []const u8) ledger.EdgeId {
    for (graph.edges) |e| {
        if (std.mem.eql(u8, nodeRaw(graph, e.from), from) and std.mem.eql(u8, nodeRaw(graph, e.to), to)) return e.id;
    }
    unreachable;
}

fn nodeRaw(graph: sem_graph.SemGraph, id: u32) []const u8 {
    for (graph.nodes) |n| if (n.id == id) return n.raw_id;
    unreachable;
}

fn fanInRailOf(s: sketch_mod.Sketch, edge: ledger.EdgeId) sketch_mod.Rail {
    for (s.rails) |rail| {
        if (rail.role != .fan_in_dropper and rail.role != .fan_in_rail) continue;
        for (rail.taps) |tap| if (tap.edge == edge) return rail;
    }
    unreachable;
}

const both_ends = "flowchart TD\n  A --> B\n  B --> C\n  A --> C\n";

const both_ends_mirrored = "flowchart TD\n  A --> B\n  B --> C\n  A --> C\n  D --> B\n  A --> E\n";

fn twoStructuralSets(sets: []const bundle_mod.Bundle, edge: ledger.EdgeId) ![2]bundle_mod.Bundle {
    var out: [2]bundle_mod.Bundle = undefined;
    var n: usize = 0;
    for (sets) |set| {
        if (set.cells != null or set.pairwise != null or set.origin == .port_share) continue;
        for (set.members) |m| if (m == edge) {
            if (n == 2) return error.ThirdStructuralSet;
            out[n] = set;
            n += 1;
        };
    }
    if (n != 2) return error.NotTwoStructuralSets;
    return out;
}

test "junction licence: rail membership at both ends — the tap cell reads both members as one bundle, mirrored or not" {
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = try render(arena.allocator(), both_ends, 94);
        const s = r.sketch;
        const bc = edgeId(r.graph, "B", "C");
        const ac = edgeId(r.graph, "A", "C");

        const sets = try twoStructuralSets(s.sharing.bundles, ac);
        try testing.expect(std.mem.indexOfScalar(ledger.EdgeId, sets[1].members, bc) != null);

        const rail = fanInRailOf(s, ac);
        try testing.expectEqual(@as(usize, 2), rail.taps.len);
        try testing.expectEqual(bc, rail.taps[0].edge);
        try testing.expectEqual(ac, rail.taps[1].edge);
        try testing.expect(rail.taps[1].continues);
        const x: u32 = @intCast(rail.taps[1].at.x);
        const y: u32 = @intCast(rail.taps[1].at.y);
        try testing.expectEqual(bc, ownerOf(r.report.lattice.atConst(x, y)).?);
        try testing.expect(s.sharing.sameBundle(bc, ac, crossings.bundleCellAt(x, y)));
        try expectNoRasterDefect(r.report);

        // In production the skip-layer edge is selected at both ends and drawn as one member stroke.
        try testing.expectEqual(@as(usize, 2), s.rails.len);
        try testing.expectEqual(@as(usize, 2), s.sharing.realized.selected_bundles.len);
        for (s.sharing.realized.memberships) |rm| if (rm.edge == ac) {
            try testing.expect(rm.source.? == .selected and rm.target.? == .selected);
        };
        var strokes: usize = 0;
        for (s.edges) |e| strokes += @intFromBool(e.role == .member_stroke);
        try testing.expectEqual(@as(usize, 1), strokes);
    }
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = try render(arena.allocator(), both_ends_mirrored, 94);
        const s = r.sketch;
        const bc = edgeId(r.graph, "B", "C");
        const ac = edgeId(r.graph, "A", "C");
        const ae = edgeId(r.graph, "A", "E");

        const sets = try twoStructuralSets(s.sharing.bundles, ac);
        try testing.expect(std.mem.indexOfScalar(ledger.EdgeId, sets[0].members, ae) != null);
        try testing.expect(std.mem.indexOfScalar(ledger.EdgeId, sets[1].members, bc) != null);

        const rail = fanInRailOf(s, ac);
        try testing.expectEqual(@as(usize, 2), rail.taps.len);
        try testing.expectEqual(ac, rail.taps[0].edge);
        try testing.expect(rail.taps[0].continues);
        try testing.expectEqual(bc, rail.taps[1].edge);
        const x: u32 = @intCast(rail.taps[1].at.x);
        const y: u32 = @intCast(rail.taps[1].at.y);
        try testing.expectEqual(ac, ownerOf(r.report.lattice.atConst(x, y)).?);
        try testing.expect(s.sharing.sameBundle(ac, bc, crossings.bundleCellAt(x, y)));
        try expectNoRasterDefect(r.report);
    }
}

const labeled_fan_cases = [_]struct { source: []const u8, labels: u32, heads: u32, omitted: u32 = 0 }{
    .{ .source = "flowchart TD\n  P -->|alpha-member-1| A\n  P -->|bravo-member-2| B\n  P -.->|charlie-member-3| C\n  P -.->|delta-member-4| D\n  P ==>|echo-member-5| E\n  P ==>|foxtrot-member-6| F\n", .labels = 6, .heads = 6 },
    .{ .source = "flowchart TD\n  P -->|alpha| A\n  P -->|bravo| B\n  P -->|charlie| C\n", .labels = 3, .heads = 3, .omitted = 1 },
    .{ .source = "flowchart TD\n  A -->|left-source-label| T\n  B -->|middle-source-label| T\n  C -->|right-source-label| T\n", .labels = 3, .heads = 1 },
    .{ .source = "flowchart TD\n  P --> A\n  P -->|only-label| B\n  P --> C\n", .labels = 1, .heads = 3 },
    .{ .source = "flowchart TD\n  P -->|a| A\n  P -->|b| A\n  P -->|c| B\n", .labels = 3, .heads = 3 },
    .{ .source = "flowchart BT\n  P -->|alpha| A\n  P -->|bravo| B\n  P -->|charlie| C\n", .labels = 3, .heads = 3, .omitted = 1 },
    .{ .source = "flowchart TD\n  P -->|x| A\n  P --> B\n  subgraph G\n    B\n  end\n", .labels = 1, .heads = 2 },
    .{ .source = "flowchart TD\n  A -->|left| T\n  B -->|right| T\n  subgraph G\n    T\n  end\n", .labels = 2, .heads = 1 },
    .{ .source = "flowchart TD\n  P --> A\n  P --o|private| A\n  P --> B\n", .labels = 1, .heads = 3 },
    .{ .source = "flowchart TD\n  P --> A\n  P --o|private| A\n  P --> B\n  subgraph G\n    B\n  end\n", .labels = 1, .heads = 3 },
};

fn sketchEdgeCount(s: sketch_mod.Sketch) usize {
    var taps: usize = 0;
    for (s.rails) |rail| taps += rail.taps.len;
    return s.edges.len + taps;
}

test "fan labels: feasible mixed, in-out, star-law-refused, clustered, duplicate-leaf and BT renders lose none but a label whose only room was beside the crossbar" {
    for (labeled_fan_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try render(a, case.source, 60);
        try testing.expectEqual(case.omitted, r.report.labels_dropped);
        try testing.expectEqual(case.heads, arrowheadCells(&r.report.lattice));
        try testing.expectEqual(r.graph.edges.len, sketchEdgeCount(r.sketch));
        try testing.expect(r.sketch.bbox.w <= 60);
    }
}

test "fan labels: explicit clipping reports width overflow and declared loss" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try render(a, "flowchart TD\n  P -->|abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789| A\n  P -->|short| B\n", 20);
    var marked = false;
    for (r.sketch.diagnostics) |d| switch (d) {
        .width_overflow => marked = true,
        else => {},
    };
    try testing.expect(marked);
    try testing.expectEqual(@as(u32, 1), r.report.labels_dropped);
}
