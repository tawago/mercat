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

// --- Layout pipeline re-exports --------------------------------------
// These let test modules (and any future external consumers) reach the
// v2 surface through a single module import (`@import("mermaid_v2")`)
// rather than rooting separate modules at deeply-nested files. The
// latter pattern fails for layout/*.zig because those files use
// relative `@import` paths that would cross Zig module boundaries if
// each layout file became its own module root.

/// Namespace re-export of sem_graph.zig. Callers write e.g.
/// `v2.sem_graph.Node` instead of the former `v2.SgNode` aliases.
pub const sem_graph = @import("sem_graph.zig");

// Id typedefs are re-exported at the top level for ergonomic use in
// tests and tools that already import "mermaid_v2" directly.
pub const NodeId = sem_graph.NodeId;
pub const EdgeId = sem_graph.EdgeId;
pub const ClusterId = sem_graph.ClusterId;

const sketch_types = @import("sketch.zig");
const coords_mod = @import("layout.zig");
const validate_mod = @import("layout/validate.zig");
const lattice_types = @import("lattice.zig");
const rasterize_mod = @import("raster.zig");
const labels_mod = @import("raster/labels.zig");
const paint_mod = @import("paint.zig");
const ladder_pkg = @import("budget.zig");
const select_mod = @import("select.zig");
const motif_mod = @import("motif.zig");
const ledger = @import("base/ledger.zig");
const permits_mod = @import("ledger/permits.zig");
const prim = @import("prim");

pub const Sketch = sketch_types.Sketch;
pub const layoutFlowchart = coords_mod.layout;
pub const LayoutOptions = coords_mod.LayoutOptions;
pub const validateSketch = validate_mod.validate;
pub const ValidationResult = validate_mod.ValidationResult;
pub const Violation = validate_mod.Violation;

// --- Raster pipeline re-exports --------------------------------------
pub const rasterize = rasterize_mod.rasterize;
pub const RasterReport = rasterize_mod.RasterReport;
pub const RasterizeError = rasterize_mod.RasterizeError;
pub const LabelDiagnostic = labels_mod.LabelDiagnostic;
pub const Lattice = lattice_types.Lattice;
pub const Cell = lattice_types.Cell;
pub const Occupant = lattice_types.Occupant;
pub const Neighbours = lattice_types.Neighbours;
pub const BorderRole = lattice_types.BorderRole;

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
    /// MERCAT_FORCE_RUNG=<natural|tight|wrap_labels|chain_wrap|
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
    /// MERCAT_DUMP_MOTIFS=1 (INERT): emit one `mercat-motifs:`-prefixed
    /// indented MotifTree per diagram to stderr. The decomposition is
    /// computed ONLY under the env var — a normal render never pays for it.
    dump_motifs: bool,
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
            .dump_motifs = envIsOne("MERCAT_DUMP_MOTIFS"),
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

    // SemGraph's arena was created via the outer caller path; here we
    // passed `aa` so its arena lives inside our outer arena and is freed
    // when `arena.deinit()` runs. Calling its deinit would double-free
    // (it would `destroy` an arena pointer that itself lives in our
    // arena). Skip explicit deinit — arena cleanup handles it.
    const graph = parse(aa, source) catch |err| {
        std.log.warn("mermaid_v2 parse failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 pipeline error: parse");
    };
    if (graph.skipped_lines > 0) {
        std.log.warn("mermaid_v2 parse: skipped {d} unparseable non-edge line(s); rendering the rest", .{graph.skipped_lines});
    }

    const branch_result = resolveJoinPermits(aa, graph) catch |err| {
        std.log.warn("mermaid_v2 branch plan failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 pipeline error: branch plan");
    };
    // `join_permits` lives for the whole render (this frame outlives every
    // layout pass); the ladder/select drivers take it as *const so
    // LayoutOptions.join_permits aliases THIS plan, never a stack copy.
    const join_permits = branch_result.plan;
    const join_permits_flat = !branch_result.report.join_permits_skipped_clustered;

    // MotifTree dump is INERT: nothing downstream reads the result yet
    // (see EnvOptions.dump_motifs).
    if (env.dump_motifs) motif_mod.dumpToStderr(aa, graph);

    // Every render enumerates all budget-ladder rung candidates
    // (`budget.enumerate`), plus up to 3 motif-PACKED candidates on TD/BT
    // graphs with a packable parallel motif (select.zig), and returns the
    // score's argmin (score.zig), not the ladder's first-accepting rung.
    // Cost: <=10 layout passes per render instead of the ladder's
    // short-circuit — acceptable at corpus scale (<=31 nodes), and the
    // TUI only re-renders on reflow (load/resize/reload), never per
    // frame. The env knobs steering this block (force_rung / score_off /
    // shadow_telemetry) are documented on EnvOptions above.
    const ladder_result: ladder_pkg.LadderResult = blk: {
        if (env.force_rung) |rung| {
            break :blk ladder_pkg.runForced(aa, graph, &join_permits, join_permits_flat, options.max_width, rung) catch |err| {
                std.log.warn("mermaid_v2/entry: forced-rung layout failed: {s}", .{@errorName(err)});
                return fallback(source, "v2 ladder error");
            };
        }
        if (env.score_off and !env.shadow_telemetry) {
            // Escape hatch without telemetry: the exact original path
            // (short-circuiting ladder, no enumeration).
            break :blk ladder_pkg.run(aa, graph, &join_permits, join_permits_flat, options.max_width) catch |err| {
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
        // guarded-by: select_test.zig "choose: merged selection anchors to raw natural and never fails the render"
        break :blk select_mod.choose(aa, graph, &join_permits, join_permits_flat, options.max_width, env.score_off, env.shadow_telemetry) catch |err| {
            std.log.warn("mermaid_v2/entry: ladder failed: {s}", .{@errorName(err)});
            return fallback(source, "v2 ladder error");
        };
    };
    const sketch_val = ladder_result.sketch;

    // Sketch validation runs in EVERY build mode: the structured per-kind
    // COUNTS must exist in release builds too (external diagnostics
    // read them via MERCAT_INTEGRITY below), while the per-violation LOG
    // lines stay Debug-only. Log-only + count-only: never affects output.
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

    const raster_report = rasterize(aa, sketch_val, options.subgraph_edges) catch |err| {
        std.log.warn("mermaid_v2 rasterize failed: {s}", .{@errorName(err)});
        return fallback(source, "v2 raster error");
    };

    if (env.integrity) emitIntegrityLine(integrity, raster_report, graph.skipped_lines);

    // Clip the painter to the winning budget — the honest terminal.
    // `budget.max_width` already lives in the IR; this is a legal
    // raster/paint read of a decision layout already made.
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
        // Clipped/emitted width — matches `painted` (A4).
        .width = @min(true_width, budget),
        .height = raster_report.lattice.height,
        .is_fallback = false,
        .fallback_reason = null,
        .width_overflow = if (clipped) .{ .true_width = true_width, .budget = budget } else null,
    };
}

fn resolveJoinPermits(allocator: std.mem.Allocator, graph: sem_graph.SemGraph) !permits_mod.BuildResult {
    const result = try permits_mod.build(allocator, graph, .joined);
    if (result.report.join_permits_skipped_clustered) return result;
    const validation = try permits_mod.validate(allocator, graph, result.plan);
    if (!validation.valid()) return error.InvalidJoinPermits;
    return result;
}

/// Emit one machine-readable integrity line per rendered diagram to
/// STDERR. The caller gates on `EnvOptions.integrity` (MERCAT_INTEGRITY=1).
/// External diagnostics tooling captures these lines; normal CLI/TUI
/// use never sets the variable. Stdout bytes are identical whether or
/// not the variable is set — this writes to stderr only and changes no
/// pipeline decision.
///
/// `r_phantom_arms` is informational (repaired masks, not shipped
/// defects) and is EXCLUDED from the per-render violation total.
fn emitIntegrityLine(
    v: validate_mod.Counts,
    raster_report: rasterize_mod.RasterReport,
    skipped_lines: u32,
) void {
    std.debug.print(
        "mercat-integrity: v_node_overlap={d} v_path_off_perimeter={d} v_path_through_interior={d} v_cluster={d} v_bbox={d} r_edge_cells_lost={d} r_labels_dropped={d} r_labels_displaced={d} r_phantom_arms={d} r_arms_repaired={d} x_legal_crossing={d} x_foreign_junction={d} x_arrowhead_transit={d} b_frame_bridge={d} b_border_fusion_refused={d} a_arrowhead_base={d} skipped_lines={d}\n",
        .{
            v.node_overlap,
            v.path_off_perimeter,
            v.path_through_interior,
            v.cluster_containment + v.cluster_port,
            v.bbox_overflow,
            raster_report.edge_cells_lost,
            raster_report.labels_dropped,
            raster_report.labels_displaced,
            raster_report.phantom_arms_cleared,
            raster_report.arms_repaired,
            raster_report.crossings.legal_crossing,
            raster_report.crossings.foreign_junction_violation,
            raster_report.crossings.arrowhead_transit_violation,
            raster_report.crossings.b_frame_bridge,
            raster_report.crossings.b_border_fusion_refused,
            raster_report.arrow_base.violations,
            skipped_lines,
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

    const result = try resolveJoinPermits(a, graph);
    try std.testing.expectEqual(ledger.JoinPolicy.joined, result.plan.policy);
    try std.testing.expect(!result.report.join_permits_skipped_clustered);
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

test "V-D-IR-07: clustered production path keeps the realized plan envelope empty" {
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

    const result = try resolveJoinPermits(a, graph);
    try std.testing.expectEqual(ledger.JoinPolicy.joined, result.plan.policy);
    try std.testing.expect(result.report.join_permits_skipped_clustered);
    try std.testing.expect(result.report.edgeid_scope_clustered_skipped);
    const laid_out = try ladder_pkg.run(a, graph, &result.plan, false, 120);
    try std.testing.expectEqual(@as(usize, 0), laid_out.sketch.joins.selected_joins.len);
    try std.testing.expectEqual(@as(usize, 0), laid_out.sketch.joins.memberships.len);
    try std.testing.expectEqual(@as(usize, 0), laid_out.sketch.joins.mesh_unions.len);
}

test {
    // Pull in layout-pipeline tests so `zig build` sees them when the
    // mermaid_v2 module is exercised. Each referenced file uses its own
    // `test {}` block to chain its sibling tests.
    _ = @import("layout/sugiyama.zig");
    _ = @import("layout/crossing.zig");
    _ = @import("layout/validate.zig");
    _ = @import("layout/mirror.zig");
    _ = @import("layout/chain_wrap.zig");
    _ = @import("layout.zig");
    _ = @import("raster.zig");
    _ = @import("paint.zig");
    _ = @import("budget.zig");
    _ = @import("score.zig");
    _ = @import("select.zig");
    _ = @import("audit.zig");
    _ = @import("motif.zig");
    _ = @import("recurse.zig");
    _ = @import("cluster/split.zig");
    _ = @import("cluster/stitch.zig");
    _ = @import("cluster/bridges.zig");
    _ = @import("base/ledger.zig");
    _ = @import("base/ledger_test.zig");
    _ = @import("ledger/permits.zig");
    _ = @import("ledger/permits_test.zig");
    _ = @import("ledger/realized.zig");
    _ = @import("ledger/invariants.zig");
    _ = @import("ledger/realized_test.zig");
    _ = @import("ledger/realized_test2.zig");
    _ = @import("ledger/realized_production_test.zig");
    _ = @import("ledger/disposition_test.zig");
    _ = @import("layout/ports.zig");
    _ = @import("layout/ports_test.zig");
    _ = @import("layout/ports_step7_test.zig");
    _ = @import("layout/port_plan_test.zig");
    _ = @import("layout/join_commit_test.zig");
    _ = @import("layout/route_clearance_test.zig");
    _ = @import("select_test.zig");
    _ = @import("ledger/reach_vector.zig");
    _ = @import("ledger/reach_vector_test.zig");
    _ = @import("ledger/reach_vector_test2.zig");
}
