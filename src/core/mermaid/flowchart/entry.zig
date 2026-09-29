const std = @import("std");
const builtin = @import("builtin");

pub const parse = @import("parse.zig").parse;

pub const sem_graph = @import("sem_graph.zig");

pub const NodeId = sem_graph.NodeId;
pub const EdgeId = sem_graph.EdgeId;
pub const ClusterId = sem_graph.ClusterId;

const coords_mod = @import("layout.zig");
const validate_mod = @import("layout/validate.zig");
const rasterize_mod = @import("raster.zig");
const paint_mod = @import("paint.zig");
const ladder_pkg = @import("budget.zig");
const select_mod = @import("select.zig");
const ledger = @import("base/ledger.zig");
const permits_mod = @import("ledger/permits.zig");
const prim = @import("prim");

pub const layoutFlowchart = coords_mod.layout;
pub const validateSketch = validate_mod.validate;

pub const rasterize = rasterize_mod.rasterize;

pub const paint = paint_mod.paint;

pub const Rung = ladder_pkg.Rung;

pub const RenderResult = struct {
    output: []const u8,
    width: u32,
    height: u32,
    is_fallback: bool,
    fallback_reason: ?[]const u8 = null,
};

pub const RenderOptions = struct {
    max_width: u32 = 120,
    subgraph_edges: prim.SubgraphEdges = .bridge,
};

/// Selection and diagnostic overrides reachable only from tests; production renders use the defaults.
pub const TestOptions = struct {
    force_rung: ?ladder_pkg.Rung = null,
};

pub fn render(allocator: std.mem.Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    return renderFlowchart(allocator, source, options);
}

pub fn renderFlowchart(allocator: std.mem.Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    return renderWith(allocator, source, options, .{});
}

/// Renders with test overrides; a compile error outside test builds.
pub fn renderForTest(allocator: std.mem.Allocator, source: []const u8, options: RenderOptions, overrides: TestOptions) !RenderResult {
    if (!builtin.is_test) @compileError("renderForTest is test-only");
    return renderWith(allocator, source, options, overrides);
}

fn renderWith(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: RenderOptions,
    overrides: TestOptions,
) !RenderResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const graph = parse(aa, source) catch |err| {
        std.log.warn("mermaid_v2 parse failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 pipeline error: parse");
    };
    if (graph.skipped_lines > 0) {
        std.log.warn("mermaid_v2 parse: skipped {d} unparseable non-edge line(s); rendering the rest", .{graph.skipped_lines});
    }

    const branch_result = resolveBundlePermits(aa, graph) catch |err| {
        std.log.warn("mermaid_v2 branch plan failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 pipeline error: branch plan");
    };
    const bundle_permits = branch_result.plan;

    const chosen = blk: {
        if (overrides.force_rung) |rung| {
            break :blk ladder_pkg.runForced(aa, graph, &bundle_permits, options.max_width, rung) catch |err| {
                std.log.warn("mermaid_v2/entry: forced-rung layout failed: {s}", .{@errorName(err)});
                return fallback(source, "v2 ladder error");
            };
        }
        break :blk select_mod.choose(aa, graph, &bundle_permits, options.max_width, options.subgraph_edges) catch |err| {
            std.log.warn("mermaid_v2/entry: ladder failed: {s}", .{@errorName(err)});
            return fallback(source, "v2 ladder error");
        };
    };
    const sketch_val = chosen.sketch;

    for (sketch_val.edges) |e| if (e.polyline.len < 2 and e.kind != .invisible) {
        std.log.warn("mermaid_v2: edge {d} ({s} -> {s}) could not be routed without illegal ink and is not drawn", .{ e.id, nodeRawId(graph, e.from), nodeRawId(graph, e.to) });
    };

    const raster_report = rasterize(aa, sketch_val, options.subgraph_edges) catch |err| {
        std.log.warn("mermaid_v2 rasterize failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 raster error");
    };

    const budget = sketch_val.budget.max_width;
    const true_width = raster_report.lattice.width;
    const painted = paint(allocator, raster_report.lattice, budget) catch |err| {
        std.log.warn("mermaid_v2 paint failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 paint error");
    };

    if (true_width > budget) {
        std.log.warn("mermaid_v2: diagram clipped: true width {d} > budget {d}", .{ true_width, budget });
    }

    return .{
        .output = painted,
        .width = @min(true_width, budget),
        .height = raster_report.lattice.height,
        .is_fallback = false,
        .fallback_reason = null,
    };
}

fn nodeRawId(graph: sem_graph.SemGraph, id: sem_graph.NodeId) []const u8 {
    for (graph.nodes) |n| if (n.id == id) return n.raw_id;
    return "?";
}

fn resolveBundlePermits(allocator: std.mem.Allocator, graph: sem_graph.SemGraph) !permits_mod.BuildResult {
    const result = try permits_mod.build(allocator, graph, .joined);
    if (result.report.bundle_permits_skipped_clustered) return result;
    const validation = try permits_mod.validate(allocator, graph, result.plan);
    if (!validation.valid()) return error.InvalidBundlePermits;
    return result;
}

fn fallback(source: []const u8, reason: []const u8) RenderResult {
    return .{
        .output = source,
        .width = 0,
        .height = 0,
        .is_fallback = true,
        .fallback_reason = reason,
    };
}

test "V-D-POLICY-02: production resolver originates joined for a flat graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\nA --> B\nA --> C\n");

    const result = try resolveBundlePermits(a, graph);
    try std.testing.expectEqual(ledger.BundlePolicy.joined, result.plan.policy);
    try std.testing.expect(!result.report.bundle_permits_skipped_clustered);
    try std.testing.expectEqual(@as(usize, 1), result.plan.groups.len);
}

test "V-D-POLICY-03: policy has no config CLI or environment surface" {
    try std.testing.expect(!@hasField(RenderOptions, "policy"));
    try std.testing.expect(!@hasField(TestOptions, "policy"));

    const source = "flowchart TD\nA --> B\n";
    const left = try renderFlowchart(std.testing.allocator, source, .{});
    defer std.testing.allocator.free(left.output);
    const right = try renderFlowchart(std.testing.allocator, source, .{});
    defer std.testing.allocator.free(right.output);
    try std.testing.expectEqualStrings(left.output, right.output);
}

test "default test overrides render what production renders" {
    const source = "flowchart TD\nA --> B\nA --> C\n";
    const production = try renderFlowchart(std.testing.allocator, source, .{});
    defer std.testing.allocator.free(production.output);
    const overridden = try renderForTest(std.testing.allocator, source, .{}, .{});
    defer std.testing.allocator.free(overridden.output);
    try std.testing.expectEqualStrings(production.output, overridden.output);
}

test "V-D-IR-07: a clustered graph's bundles ride piece plans; the root plan stays skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\subgraph S
        \\  A --> B
        \\end
        \\B --> C
        \\
    );

    const result = try resolveBundlePermits(a, graph);
    try std.testing.expectEqual(ledger.BundlePolicy.joined, result.plan.policy);
    try std.testing.expect(result.report.bundle_permits_skipped_clustered);
    try std.testing.expect(result.report.edgeid_scope_clustered_skipped);
    const laid_out = try ladder_pkg.runForced(a, graph, &result.plan, 120, .natural);
    try std.testing.expectEqual(@as(usize, 0), laid_out.sketch.bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 2), laid_out.sketch.bundles.memberships.len);
    const bridge_row = laid_out.sketch.bundles.memberships[1];
    try std.testing.expect(bridge_row.source == null and bridge_row.target == null);
}

test "cluster unification: a subgraph-internal fan-in realizes a rail and ships it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\subgraph S
        \\  A --> C
        \\  B --> C
        \\end
        \\
    );

    const result = try resolveBundlePermits(a, graph);
    const laid_out = try ladder_pkg.runForced(a, graph, &result.plan, 80, .natural);
    try std.testing.expectEqual(@as(usize, 1), laid_out.sketch.bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 2), laid_out.sketch.bundles.selected_bundles[0].members.len);

    const rendered = try renderFlowchart(std.testing.allocator, "flowchart TD\nsubgraph S\n  A --> C\n  B --> C\nend\n", .{ .max_width = 80 });
    defer std.testing.allocator.free(rendered.output);
    try std.testing.expect(!rendered.is_fallback);
    const expected =
        \\┌─ S ────────────────┐
        \\│                    │
        \\│   ┌───┐    ┌───┐   │
        \\│   │ A │    │ B │   │
        \\│   └─┬─┘    └─┬─┘   │
        \\│     └───┬────┘     │
        \\│         │          │
        \\│         ▼          │
        \\│       ┌───┐        │
        \\│       │ C │        │
        \\│       └───┘        │
        \\│                    │
        \\└────────────────────┘
    ;
    try std.testing.expectEqualStrings(expected, std.mem.trimRight(u8, rendered.output, "\n"));
}

test "cluster unification: two subgraph rails keep their own members through nonzero stitch bases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\subgraph S
        \\  A --> C
        \\  B --> C
        \\end
        \\subgraph T
        \\  D --> F
        \\  E --> F
        \\end
        \\
    );

    const result = try resolveBundlePermits(a, graph);
    const laid_out = try ladder_pkg.runForced(a, graph, &result.plan, 80, .natural);
    const bundles = laid_out.sketch.bundles.selected_bundles;
    try std.testing.expectEqual(@as(usize, 2), bundles.len);
    try std.testing.expectEqual(@as(usize, 2), laid_out.sketch.rails.len);
    for (bundles) |j| {
        try std.testing.expectEqual(@as(usize, 2), j.members.len);
        var matched = false;
        for (laid_out.sketch.rails) |rail| {
            if (rail.taps.len != 2) continue;
            const fwd = (rail.taps[0].edge == j.members[0] and rail.taps[1].edge == j.members[1]);
            const rev = (rail.taps[0].edge == j.members[1] and rail.taps[1].edge == j.members[0]);
            if (fwd or rev) matched = true;
        }
        try std.testing.expect(matched);
    }
    try std.testing.expect(bundles[0].members[0] != bundles[1].members[0]);
    try std.testing.expect(bundles[0].members[1] != bundles[1].members[1]);
}

test "cluster unification: a bridge never transits a stitched rail's arrowhead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
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
    );
    const result = try resolveBundlePermits(a, graph);
    const laid_out = try ladder_pkg.runForced(a, graph, &result.plan, 120, .natural);
    const report = try rasterize(a, laid_out.sketch, .bridge);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try std.testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
    try std.testing.expectEqual(@as(u32, 0), report.arrow_base.lateral_arms);
}

test "cluster unification: bridges route around each other, not through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
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
    );
    const result = try resolveBundlePermits(a, graph);
    const winner = try select_mod.choose(a, graph, &result.plan, 120, .bridge);
    const report = try rasterize(a, winner.sketch, .bridge);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    try std.testing.expectEqual(@as(u32, 0), report.arrow_base.lateral_arms);
}

test {
    _ = @import("layout/sugiyama.zig");
    _ = @import("layout/crossing.zig");
    _ = @import("layout/validate.zig");
    _ = @import("layout/mirror.zig");
    _ = @import("layout.zig");
    _ = @import("raster.zig");
    _ = @import("paint.zig");
    _ = @import("onrun_paint_test.zig");
    _ = @import("budget.zig");
    _ = @import("score.zig");
    _ = @import("select.zig");
    _ = @import("audit.zig");
    _ = @import("motif.zig");
    _ = @import("recurse.zig");
    _ = @import("cluster/split.zig");
    _ = @import("cluster/split_test.zig");
    _ = @import("cluster/stitch.zig");
    _ = @import("cluster/stitch_bundle_sets.zig");
    _ = @import("cluster/bridges.zig");
    _ = @import("cluster/bridge_plan.zig");
    _ = @import("cluster/bridge_rails.zig");
    _ = @import("cluster/bridge_bundle_sets.zig");
    _ = @import("base/ledger.zig");
    _ = @import("base/ledger_test.zig");
    _ = @import("base/bundle.zig");
    _ = @import("base/rail_closure.zig");
    _ = @import("base/rail_closure_test.zig");
    _ = @import("layout/fan_rail_licence.zig");
    _ = @import("ledger/permits.zig");
    _ = @import("ledger/permits_test.zig");
    _ = @import("ledger/realized_production_test.zig");
    _ = @import("layout/ports.zig");
    _ = @import("layout/ports_test.zig");
    _ = @import("layout/ports_step7_test.zig");
    _ = @import("layout/port_plan_test.zig");
    _ = @import("layout/bundle_commit_test.zig");
    _ = @import("layout/route_clearance_test.zig");
    _ = @import("select_test.zig");
    _ = @import("sketch_ports_test.zig");
    _ = @import("sketch_bundles_test.zig");
    _ = @import("junction_licence_test.zig");
    _ = @import("decoration_cell_test.zig");
    _ = @import("route_once_test.zig");
    _ = @import("grapheme_width_test.zig");
}
