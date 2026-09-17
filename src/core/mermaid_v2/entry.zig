//! mermaid_v2 entry point.
//!
//! Composition root for the flowchart rendering pipeline: Parse ->
//! SemGraph -> Layout -> Sketch -> Rasterize -> Lattice -> Paint. Sole
//! flowchart renderer; `src/core/mermaid/render.zig` dispatches here and
//! maps the result back into the legacy `types.RenderResult` shape.
//!
//! `RenderResult`/`RenderOptions` are redeclared here (not imported from
//! `../mermaid/types.zig`) because Zig modules cannot import files outside their own module root.

const std = @import("std");
const builtin = @import("builtin");

/// Re-export of the flowchart parser entry point. Allows callers outside
/// the parse subdir to reach the parser without importing through deep
/// relative paths.
pub const parse = @import("parse.zig").parse;

/// Namespace re-export of sem_graph.zig. Callers write e.g.
/// `v2.sem_graph.Node` instead of the former `v2.SgNode` aliases.
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
const invariants_mod = @import("ledger/invariants.zig");
const prim = @import("prim");

pub const layoutFlowchart = coords_mod.layout;
pub const validateSketch = validate_mod.validate;

pub const rasterize = rasterize_mod.rasterize;

pub const paint = paint_mod.paint;

pub const Rung = ladder_pkg.Rung;
pub const LadderResult = ladder_pkg.LadderResult;

pub const RenderResult = struct {
    output: []const u8,
    /// Columns actually emitted (clipped to the budget); the true
    /// geometric width lives in the sketch bbox. The painter clips to
    /// `budget.max_width`, so this is `min(lattice.width,
    /// budget.max_width)` and matches what was painted — it flows into
    /// the surrounding markdown layout, which must size to the real
    /// output width, not the pre-clip geometry.
    width: u32,
    height: u32,
    is_fallback: bool,
    fallback_reason: ?[]const u8 = null,
    /// Set when the diagram's true geometric width exceeded the budget
    /// and the painter clipped it. `null` when the diagram fit. Optional
    /// + defaulted so existing consumers compile unchanged.
    width_overflow: ?struct { true_width: u32, budget: u32 } = null,
};

pub const RenderOptions = struct {
    max_width: u32 = 120,
    unicode_mode: bool = true,
    /// Subgraph frame-border notation (owner ruling, tawago 2026-07-19): a
    /// user choice threaded down to the raster. `.bridge` (default) draws
    /// frame-solid; `.cross` reproduces the pre-Slice-1 junction weld.
    subgraph_edges: prim.SubgraphEdges = .bridge,
};

/// Environment knobs, read ONCE at the top of `renderFlowchart` — the
/// composition root is the only getenv site in the pipeline (budget.zig
/// et al. never call getenv) — and passed down as plain values.
const EnvOptions = struct {
    /// MERCAT_FORCE_RUNG=<natural|tight|wrap_labels|
    /// switch_direction|truncate>: lay out and return exactly that rung
    /// (bypassing both the ladder acceptance AND the score) so external
    /// diagnostics tooling can render any single candidate for audit. An
    /// unrecognized value is ignored. Takes precedence over the other knobs.
    force_rung: ?ladder_pkg.Rung,
    /// MERCAT_SCORE_OFF=1: restore the original ladder behavior (the
    /// incumbent: first-accepting rung wins) — the A/B escape hatch.
    score_off: bool,
    /// MERCAT_SCORE_SHADOW=1: emit one machine-readable `mercat-score-shadow:`
    /// line to stderr when the score's argmin differs from the ladder
    /// incumbent. With the score live this is behavior-DELTA telemetry
    /// ("this render differs from what the old ladder would have shipped");
    /// combined with MERCAT_SCORE_OFF=1 it reproduces the original shadow mode
    /// exactly (incumbent returned, disagreement line emitted).
    shadow_telemetry: bool,
    /// MERCAT_INTEGRITY=1: emit one `mercat-integrity:` counts line per diagram
    /// to stderr (see `emitIntegrityLine`).
    integrity: bool,
    fn read() EnvOptions {
        return .{
            .force_rung = blk: {
                const env = std.posix.getenv("MERCAT_FORCE_RUNG") orelse break :blk null;
                break :blk std.meta.stringToEnum(ladder_pkg.Rung, env);
            },
            .score_off = envIsOne("MERCAT_SCORE_OFF"),
            .shadow_telemetry = envIsOne("MERCAT_SCORE_SHADOW"),
            .integrity = envIsOne("MERCAT_INTEGRITY"),
        };
    }
};

/// Top-level render entry — mirrors the legacy `mermaid.render` shape
/// used by `src/core/mermaid/render.zig`'s dispatcher.
pub fn render(allocator: std.mem.Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    return renderFlowchart(allocator, source, options);
}

/// Render a flowchart through the v2 pipeline. The painted bytes are
/// allocated from `allocator` and owned by the caller. All intermediate
/// allocations (SemGraph, Sketch, Lattice, diagnostics) live in an
/// internal arena released before return.
///
/// On any pipeline error this falls back to `is_fallback=true` with the
/// original source as `output`. The caller (`src/core/render/blocks.zig`)
/// will defer to the legacy renderer in that case.
pub fn renderFlowchart(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: RenderOptions,
) !RenderResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const env = EnvOptions.read();

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

    const ladder_result: ladder_pkg.LadderResult = blk: {
        if (env.force_rung) |rung| {
            break :blk ladder_pkg.runForced(aa, graph, &bundle_permits, options.max_width, rung) catch |err| {
                std.log.warn("mermaid_v2/entry: forced-rung layout failed: {s}", .{@errorName(err)});
                return fallback(source, "v2 ladder error");
            };
        }
        if (env.score_off and !env.shadow_telemetry) {
            break :blk ladder_pkg.run(aa, graph, &bundle_permits, options.max_width) catch |err| {
                std.log.warn("mermaid_v2/entry: ladder failed: {s}", .{@errorName(err)});
                return fallback(source, "v2 ladder error");
            };
        }
        // LIVE selection (select.zig): raw ladder candidates + motif-
        // packed candidates, scored; argmin wins with the truncate gate
        // and natural-preference margin anchored to the RAW natural.
        // `choose` propagates exactly the errors `run()` would hit before
        // its incumbent, so this catch matches the run() error path; any
        // scoring/packing failure degrades internally to the incumbent —
        // the render never fails on selection.
        // @guarded-by: select_test.zig "choose: merged selection anchors to raw natural and never fails the render"
        break :blk select_mod.choose(aa, graph, &bundle_permits, options.max_width, env.score_off, env.shadow_telemetry, options.subgraph_edges) catch |err| {
            std.log.warn("mermaid_v2/entry: ladder failed: {s}", .{@errorName(err)});
            return fallback(source, "v2 ladder error");
        };
    };
    const sketch_val = ladder_result.sketch;

    const integrity: validate_mod.Counts = blk: {
        const result = validate_mod.validate(aa, sketch_val) catch break :blk .{};
        if (comptime builtin.mode == .Debug) {
            switch (result) {
                .ok => {},
                .failed => |violations| {
                    for (violations) |v| {
                        std.log.debug("mermaid_v2/entry: sketch validation: {s}: {s}", .{ @tagName(v.kind), v.message });
                    }
                },
            }
        }
        break :blk validate_mod.counts(result, sketch_val);
    };

    // An unrouted edge is honest degradation of one relation: the sketch
    // declares it and draws nothing, so the reader is told which one.
    for (sketch_val.edges) |e| if (e.polyline.len < 2 and e.kind != .invisible) {
        std.log.warn("mermaid_v2: edge {d} ({s} -> {s}) could not be routed without illegal ink and is not drawn", .{ e.id, nodeRawId(graph, e.from), nodeRawId(graph, e.to) });
    };

    const raster_report = rasterize(aa, sketch_val, options.subgraph_edges) catch |err| {
        std.log.warn("mermaid_v2 rasterize failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 raster error");
    };

    if (env.integrity) emitIntegrityLine(
        integrity,
        raster_report,
        graph.skipped_lines,
        sketch_val.closure,
        invariants_mod.gapRowsUnaccounted(sketch_val.gap_rows),
        invariants_mod.gapRowsUnclaimedInk(sketch_val.direction, sketch_val.edges, sketch_val.rails, sketch_val.gap_rows),
    );

    const budget = sketch_val.budget.max_width;
    const true_width = raster_report.lattice.width;
    const painted = paint(allocator, raster_report.lattice, budget) catch |err| {
        std.log.warn("mermaid_v2 paint failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 paint error");
    };

    const clipped = true_width > budget;
    if (clipped) {
        std.log.warn("mermaid_v2: diagram clipped: true width {d} > budget {d}", .{ true_width, budget });
    }

    return .{
        .output = painted,
        .width = @min(true_width, budget),
        .height = raster_report.lattice.height,
        .is_fallback = false,
        .fallback_reason = null,
        .width_overflow = if (clipped) .{ .true_width = true_width, .budget = budget } else null,
    };
}

/// The source spelling of a node by its id (sketch node ids are graph
/// node ids, not positions in `graph.nodes`).
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

/// Emit one machine-readable integrity line per rendered diagram to
/// STDERR. The caller gates on `EnvOptions.integrity` (MERCAT_INTEGRITY=1).
/// External diagnostics tooling captures these lines; normal CLI/TUI use never
/// sets the variable. Stdout bytes are identical whether or
/// not the variable is set — this writes to stderr only and changes no
/// pipeline decision.
///
/// `r_phantom_arms` is informational (repaired masks, not shipped
/// defects) and is EXCLUDED from the per-render violation total.
///
/// Field roles under the plan-governed regime (clustered sharing rides
/// piece plans like flat; nothing is licensed post-routing): the x_*
/// violation fields are conformance counts against the plan and are
/// expected zero except where routing genuinely cannot avoid ink (the
/// counts are the evidence when it cannot); rail_* / co_* are the closure
/// licence's refusal inventory — legitimately nonzero on refusing inputs —
/// except `co_double_discharge`, which is a conformance assert and must
/// stay zero. The line's field set and order are frozen for external
/// tooling; demotions change doc meaning, never fields. New fields are
/// appended at the end: `tip_not_port` (a head whose tip is not on its
/// port) and `arm_into_head` (an arm into a decoration cell from a
/// lateral side, refused or shipped) joined 2026-09-03, then
/// `v_edge_unrouted` (a visible edge the router laid no ink for, because
/// every producer refused every candidate).
fn emitIntegrityLine(
    v: validate_mod.Counts,
    raster_report: rasterize_mod.RasterReport,
    skipped_lines: u32,
    /// The SHIPPED candidate's report-only rail construction inventory.
    closure: ledger.ClosureCounts,
    /// Gaps whose spacing disagrees with their row ledger (ledger/invariants.zig).
    gap_rows_unaccounted: u32,
    /// Cross-axis runs painted in a gap on a row the ledger did not claim for them.
    gap_rows_unclaimed_ink: u32,
) void {
    std.debug.print(
        "mercat-integrity: v_path_through_interior={d} v_bbox={d} r_edge_cells_lost={d} r_labels_dropped={d} r_labels_displaced={d} r_phantom_arms={d} x_legal_crossing={d} x_foreign_junction={d} x_arrowhead_transit={d} b_frame_bridge={d} b_border_fusion_refused={d} a_arrowhead_base={d} skipped_lines={d} rail_deco_mixed={d} rail_member_style_mixed={d} rail_star_violation={d} rail_closure_undeclared={d} co_undeclared={d} co_double_discharge={d} tip_not_port={d} arm_into_head={d} v_edge_unrouted={d} gap_rows_unaccounted={d} gap_rows_unclaimed_ink={d}\n",
        .{
            v.path_through_interior,
            v.bbox_overflow,
            raster_report.edge_cells_lost,
            raster_report.labels_dropped,
            raster_report.labels_displaced,
            raster_report.phantom_arms_cleared,
            raster_report.crossings.legal_crossing,
            raster_report.crossings.foreign_junction_violation,
            raster_report.crossings.arrowhead_transit_violation,
            raster_report.crossings.b_frame_bridge,
            raster_report.crossings.b_border_fusion_refused,
            raster_report.arrow_base.violations,
            skipped_lines,
            closure.rail_deco_mixed,
            closure.rail_member_style_mixed,
            closure.rail_star_violation,
            closure.rail_closure_undeclared,
            closure.co_undeclared,
            closure.co_double_discharge,
            raster_report.arrow_base.tip_not_port,
            raster_report.armIntoHead(),
            v.edge_unrouted,
            gap_rows_unaccounted,
            gap_rows_unclaimed_ink,
        },
    );
}
fn envIsOne(name: [:0]const u8) bool {
    const env = std.posix.getenv(name) orelse return false;
    return std.mem.eql(u8, env, "1");
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
    try std.testing.expect(!@hasField(EnvOptions, "policy"));

    const source = "flowchart TD\nA --> B\n";
    const left = try renderFlowchart(std.testing.allocator, source, .{});
    defer std.testing.allocator.free(left.output);
    const right = try renderFlowchart(std.testing.allocator, source, .{});
    defer std.testing.allocator.free(right.output);
    try std.testing.expectEqualStrings(left.output, right.output);
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
    const laid_out = try ladder_pkg.run(a, graph, &result.plan, 120);
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
    const laid_out = try ladder_pkg.run(a, graph, &result.plan, 80);
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
    const laid_out = try ladder_pkg.run(a, graph, &result.plan, 80);
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
    const laid_out = try ladder_pkg.run(a, graph, &result.plan, 120);
    const report = try rasterize(a, laid_out.sketch, .bridge);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try std.testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
    try std.testing.expectEqual(@as(u32, 0), report.arrow_base.tip_not_port);
    try std.testing.expectEqual(@as(u32, 0), report.armIntoHead());
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
    const winner = try select_mod.choose(a, graph, &result.plan, 120, false, false, .bridge);
    const report = try rasterize(a, winner.sketch, .bridge);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    try std.testing.expectEqual(@as(u32, 0), report.arrow_base.tip_not_port);
    try std.testing.expectEqual(@as(u32, 0), report.armIntoHead());
}

test {
    _ = @import("layout/sugiyama.zig");
    _ = @import("layout/crossing.zig");
    _ = @import("layout/validate.zig");
    _ = @import("layout/mirror.zig");
    _ = @import("layout.zig");
    _ = @import("raster.zig");
    _ = @import("raster/aux.zig");
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
    _ = @import("ledger/invariants.zig");
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
    _ = @import("cluster_corridor_test.zig");
    _ = @import("decoration_cell_test.zig");
    _ = @import("route_once_test.zig");
    _ = @import("grapheme_width_test.zig");
}
