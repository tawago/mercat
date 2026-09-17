//! Check 3: per-file `@import("...")` boundary rules for
//! src/core/mermaid_v2/ — the zone allowlist that keeps each pipeline stage
//! reaching only the stages below it.
//!
//! Split out of the tools/lint_imports.zig root (which keeps the walk, the
//! line cap, the fallback-path check, and `main`). Every violation message
//! here is unchanged by the split.

const std = @import("std");

pub fn scanImports(
    a: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    rel_path: []const u8,
    contents: []const u8,
) !void {
    const needle = "@import(\"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, contents, i, needle)) |start| {
        const open = start + needle.len;
        const end = std.mem.indexOfScalarPos(u8, contents, open, '"') orelse break;
        const target = contents[open..end];
        i = end + 1;
        if (checkImport(rel_path, target)) |reason| {
            const msg = try std.fmt.allocPrint(a, "{s}: forbidden import \"{s}\": {s}", .{ rel_path, target, reason });
            try violations.append(a, msg);
        }
    }
}

/// One allowed-import pattern for a table-driven per-file allowlist.
/// The zone patterns replicate the `tgt_is_*` booleans in `checkImport`.
pub const Rule = union(enum) {
    /// endsWith "sem_graph.zig" (direct or parent-relative).
    sem_graph,
    /// endsWith "sketch.zig", "sketch_ports.zig" OR "sketch_bundles.zig":
    /// both siblings are extensions of the Sketch IR root (a pure derivation
    /// over `EdgePath` polylines; a pure stamping of bundle identity over the
    /// finished bundle list), so they are granted exactly where `sketch.zig`
    /// is granted and nowhere else.
    sketch,
    /// endsWith "budget.zig".
    budget,
    /// endsWith "recurse.zig".
    recurse,
    /// The layout zone: layout.zig or anything under layout/.
    layout_zone,
    /// The parse zone: parse.zig or anything under parse/.
    parse_zone,
    /// The cluster zone (folder-only).
    cluster_zone,
    /// The raster zone: raster.zig or anything under raster/.
    raster_zone,
    /// Exact target string.
    exact: []const u8,

    fn allows(rule: Rule, target: []const u8) bool {
        return switch (rule) {
            .sem_graph => std.mem.endsWith(u8, target, "sem_graph.zig"),
            .sketch => std.mem.endsWith(u8, target, "sketch.zig") or
                std.mem.endsWith(u8, target, "sketch_ports.zig") or
                std.mem.endsWith(u8, target, "sketch_bundles.zig"),
            .budget => std.mem.endsWith(u8, target, "budget.zig"),
            .recurse => std.mem.endsWith(u8, target, "recurse.zig"),
            .layout_zone => std.mem.endsWith(u8, target, "layout.zig") or
                std.mem.startsWith(u8, target, "layout/") or
                (std.mem.startsWith(u8, target, "../layout") and !std.mem.startsWith(u8, target, "../lattice")),
            .parse_zone => std.mem.endsWith(u8, target, "parse.zig") or
                std.mem.startsWith(u8, target, "parse/") or
                std.mem.startsWith(u8, target, "../parse.zig"),
            .cluster_zone => std.mem.startsWith(u8, target, "cluster/") or
                std.mem.startsWith(u8, target, "../cluster/"),
            .raster_zone => std.mem.endsWith(u8, target, "raster.zig") or
                std.mem.startsWith(u8, target, "raster/") or
                std.mem.startsWith(u8, target, "../raster"),
            .exact => |name| std.mem.eql(u8, target, name),
        };
    }
};

/// Table-driven allowlists for the root-level single-file zones (files whose
/// rules are keyed on an exact rel_path rather than a directory). Rationale
/// for each list lives with the file's own header docs:
///
///   base/*          the no-deps tier (types.zig / lanes.zig / ledger.zig /
///                   diagnostics.zig):
///                   std + base siblings only; importable from every zone.
///                   types.zig alone may also import "unicode" (the width
///                   authority). Enforced by the base/ dir rule + the
///                   in_base_dir zone block in `checkImport`, not by a
///                   `file_allowlists` row.
///   raster/aux.zig  the lattice side-table builder: lattice (plus its own
///                   test sibling) only — one step tighter than the raster
///                   zone, which would also grant sketch.zig, so the bundle
///                   can only record what was rasterized, never what the
///                   layout intended.
///   ledger/permits.zig  semantic permission discovery (D-IR item 3):
///                   base/ledger + sem_graph.
///   ledger/invariants.zig  the report-only gap-row invariants over the
///                   Sketch's gap records.
///   select_test.zig  select.zig's test sibling (Step 4 cap-watch
///                   mitigation, plan N3): drives the pub select surface
///                   over parsed graphs.
///   budget.zig      the ladder driver (+ its split-out test sibling).
///   recurse.zig     cut-layout-stitch recursion: layout/ + cluster/ pairing.
///   score.zig       pure candidate score; layout/validate.zig is the ONE
///                   layout file it may reach (NOT the layout zone).
///   score_geom.zig  pure geometric T2 measurements over a Sketch.
///   score_test.zig  drives the pub score and score_geom surfaces over hand-built Sketches.
///   select.zig      candidate construction + live selection (Phase 3b/4a).
///   audit.zig       per-candidate raster audit (Phase 4a).
///   budget_test.zig graph-level ladder tests + the labeled-set calibration
///                   test (parse → select → audit → score = the live path).
///   recurse_test.zig integration tests for the cut-layout-stitch recursion
///                   that need both cluster/ and layout/ zone privileges
///                   (split out to keep recurse.zig under the 500-line cap).
///   junction_licence_test.zig  root-level pin for the junction licence
///                   read from the raster alone: the lattice's ink state
///                   and side table, the licence lookup, and the sketch's
///                   bundles. Needs parse, select and raster for a real
///                   render.
///   cluster_corridor_test.zig  root-level cross-instrument pin for the
///                   per-column crossing discipline (cluster/corridors.zig):
///                   the law is decided in the cluster zone but is ABOUT the
///                   `.intrusion` records the raster files, and the cluster
///                   zone may not import raster, so the two meet only here.
///                   Also imports cluster/corridors for its face/approach
///                   primitives, so the pin can re-derive whether a merge
///                   was FORCED from geometry rather than restate the policy.
///   decoration_cell_test.zig  root-level pin that the decoration-cell
///                   tallies (tip_not_port, arm_into_head) fire on a real
///                   render of the seed that shows the sideways head: the
///                   producer and the raster meet only through select.
///   route_once_test.zig  root-level pin that a route visits each cell
///                   once: no one-armed stroke cell on a real render of the
///                   seed that shipped a doubled-back fan polyline.
///   grapheme_width_test.zig  root-level pin that a painted node box
///                   closes at one column on every row when a label holds
///                   an emoji, a combining mark, a ZWJ family or a flag:
///                   drives the public entry point and re-measures the
///                   painted text with the width authority from outside.
pub const file_allowlists = [_]struct {
    name: []const u8,
    allowed: []const Rule,
    reason: []const u8,
}{
    .{
        .name = "ledger/permits.zig",
        .allowed = &.{.sem_graph},
        .reason = "permits may only import std, prim, base/ledger, or sem_graph",
    },
    .{
        .name = "ledger/permits_test.zig",
        .allowed = &.{ .sem_graph, .parse_zone, .{ .exact = "permits.zig" } },
        .reason = "permits_test may only import std, prim, base/ledger, sem_graph, parse, or permits",
    },
    .{
        .name = "ledger/realized_production_test.zig",
        .allowed = &.{ .parse_zone, .{ .exact = "permits.zig" }, .{ .exact = "../select.zig" }, .{ .exact = "../raster.zig" }, .{ .exact = "../paint.zig" } },
        .reason = "realized_production_test may only import std, prim, base/ledger, parse, permits, select, raster, or paint",
    },
    .{
        .name = "ledger/invariants.zig",
        .allowed = &.{.sketch},
        .reason = "invariants may only import std, prim, base/ledger, or sketch",
    },
    .{
        .name = "budget.zig",
        .allowed = &.{ .sem_graph, .sketch, .layout_zone, .parse_zone, .cluster_zone, .recurse, .{ .exact = "budget_test.zig" }, .{ .exact = "budget_types.zig" } },
        .reason = "budget may only import std, prim, sem_graph, sketch, layout, parse, recurse, cluster, budget_test, or budget_types",
    },
    .{
        .name = "recurse.zig",
        .allowed = &.{ .sem_graph, .sketch, .layout_zone, .cluster_zone, .{ .exact = "recurse_test.zig" }, .{ .exact = "recurse_test2.zig" } },
        .reason = "recurse may only import std, prim, sem_graph, sketch, layout, cluster, or its recurse_test siblings",
    },
    .{
        .name = "recurse_test.zig",
        .allowed = &.{ .recurse, .sem_graph, .sketch, .layout_zone, .cluster_zone },
        .reason = "recurse_test may only import std, prim, recurse, sem_graph, sketch, layout, or cluster",
    },
    .{
        .name = "recurse_test2.zig",
        .allowed = &.{ .recurse, .sem_graph, .sketch, .layout_zone, .cluster_zone, .raster_zone, .{ .exact = "lattice.zig" }, .{ .exact = "recurse_test.zig" } },
        .reason = "recurse_test2 may only import std, prim, recurse, sem_graph, sketch, layout, cluster, raster, lattice, or recurse_test",
    },
    .{
        .name = "score.zig",
        .allowed = &.{ .sem_graph, .sketch, .{ .exact = "layout/validate.zig" }, .{ .exact = "score_geom.zig" }, .{ .exact = "score_test.zig" } },
        .reason = "score may only import std, prim, sem_graph, sketch, layout/validate.zig, score_geom, or score_test",
    },
    .{
        .name = "score_geom.zig",
        .allowed = &.{.sketch},
        .reason = "score_geom may only import std, prim, or sketch",
    },
    .{
        .name = "score_test.zig",
        .allowed = &.{ .sketch, .{ .exact = "score.zig" }, .{ .exact = "score_geom.zig" } },
        .reason = "score_test may only import std, prim, sketch, score, or score_geom",
    },
    .{
        .name = "sketch_ports.zig",
        .allowed = &.{ .sketch, .{ .exact = "sketch_ports_test.zig" } },
        .reason = "sketch_ports may only import std, prim, base/ledger, sketch, or sketch_ports_test",
    },
    .{
        .name = "sketch_ports_test.zig",
        .allowed = &.{ .sketch, .{ .exact = "sketch_bundles.zig" } },
        .reason = "sketch_ports_test may only import std, prim, base/ledger, sketch, sketch_ports, or sketch_bundles",
    },
    .{
        .name = "sketch_bundles.zig",
        .allowed = &.{ .sketch, .{ .exact = "sketch_bundles_test.zig" } },
        .reason = "sketch_bundles may only import std, prim, base/ledger, sketch, or sketch_bundles_test",
    },
    .{
        .name = "sketch_bundles_test.zig",
        .allowed = &.{ .sketch, .parse_zone, .{ .exact = "select.zig" }, .{ .exact = "ledger/permits.zig" } },
        .reason = "sketch_bundles_test may only import std, prim, base/ledger, sketch, sketch_bundles, parse, select, or ledger/permits",
    },
    .{
        .name = "budget_types.zig",
        .allowed = &.{ .sem_graph, .sketch, .budget },
        .reason = "budget_types may only import std, prim, sem_graph, sketch, or budget",
    },
    .{
        .name = "select.zig",
        .allowed = &.{ .sem_graph, .sketch, .budget, .parse_zone, .{ .exact = "score.zig" }, .{ .exact = "motif.zig" }, .{ .exact = "audit.zig" } },
        .reason = "select may only import std, prim, base/ledger, sem_graph, sketch, budget, score, motif, audit, or parse",
    },
    .{
        .name = "select_test.zig",
        .allowed = &.{ .sem_graph, .sketch, .budget, .parse_zone, .{ .exact = "select.zig" }, .{ .exact = "ledger/permits.zig" }, .{ .exact = "audit.zig" }, .{ .exact = "raster.zig" }, .{ .exact = "score.zig" } },
        .reason = "select_test may only import std, prim, base/ledger, sem_graph, sketch, budget, parse, select, ledger/permits, audit, raster, or score",
    },
    .{
        .name = "audit.zig",
        .allowed = &.{ .sketch, .raster_zone, .{ .exact = "score.zig" } },
        .reason = "audit may only import std, prim, sketch, raster, or score",
    },
    .{
        .name = "budget_test.zig",
        .allowed = &.{ .budget, .sem_graph, .sketch, .parse_zone, .{ .exact = "build_options" }, .{ .exact = "score.zig" }, .{ .exact = "select.zig" }, .{ .exact = "audit.zig" } },
        .reason = "budget_test may only import std, prim, build_options, budget, sem_graph, sketch, parse, score, select, or audit",
    },
    .{
        .name = "layout/bundle_commit_test.zig",
        .allowed = &.{ .parse_zone, .{ .exact = "../ledger/permits.zig" }, .{ .exact = "../select.zig" }, .{ .exact = "bundle_commit.zig" } },
        .reason = "bundle_commit_test may only import std, prim, base/ledger, parse, permits, select, or bundle_commit",
    },
    .{
        .name = "layout/port_plan_test.zig",
        .allowed = &.{ .sem_graph, .sketch, .layout_zone, .raster_zone, .{ .exact = "../paint.zig" }, .{ .exact = "../ledger/permits.zig" }, .{ .exact = "ports.zig" }, .{ .exact = "port_plan.zig" }, .{ .exact = "sugiyama.zig" } },
        .reason = "port_plan_test may import the focused layout, raster, paint, and permit surfaces",
    },
    .{
        .name = "layout/fan_provenance_test.zig",
        .allowed = &.{ .sem_graph, .sketch, .layout_zone, .raster_zone, .{ .exact = "../paint.zig" }, .{ .exact = "../select.zig" }, .{ .exact = "fan.zig" }, .{ .exact = "fan_provenance.zig" } },
        .reason = "fan_provenance_test may import layout inputs plus select, raster, and paint for preservation and byte-neutrality pins",
    },
    .{
        .name = "raster/aux.zig",
        .allowed = &.{ .{ .exact = "../lattice.zig" }, .{ .exact = "aux_test.zig" } },
        .reason = "raster/aux may only import std, prim, lattice, or its own test sibling: the side-table builder must stay Sketch-blind, or a record could describe what layout INTENDED instead of what the raster DID",
    },
    .{
        .name = "raster/aux_test.zig",
        .allowed = &.{
            .sketch,                        .raster_zone,
            .{ .exact = "../lattice.zig" }, .{ .exact = "aux.zig" },
            .{ .exact = "edges.zig" },      .{ .exact = "edges_write.zig" },
            .{ .exact = "edges_port.zig" }, .{ .exact = "fan_roles.zig" },
            .{ .exact = "reconcile.zig" },  .{ .exact = "arrow_base.zig" },
            .{ .exact = "crossings.zig" },
        },
        .reason = "aux_test may only import std, prim, sketch, lattice, raster, or the raster siblings whose edge walk, post-walk passes and refusal decisions it pins",
    },
    .{
        .name = "raster/rails_test.zig",
        .allowed = &.{ .sketch, .{ .exact = "../lattice.zig" }, .{ .exact = "rails.zig" }, .{ .exact = "nodes.zig" }, .{ .exact = "../raster.zig" }, .{ .exact = "rails_test2.zig" } },
        .reason = "rails_test may only import std, prim, sketch, lattice, raster siblings, raster, or rails_test2",
    },
    .{
        .name = "raster/rails_test2.zig",
        .allowed = &.{ .sketch, .{ .exact = "../lattice.zig" }, .{ .exact = "../raster.zig" }, .{ .exact = "rails_test.zig" } },
        .reason = "rails_test2 may only import std, prim, sketch, lattice, raster, or rails_test",
    },
    .{
        .name = "onrun_paint_test.zig",
        .allowed = &.{
            .sketch,
            .raster_zone,
            .{ .exact = "lattice.zig" },
            .{ .exact = "paint.zig" },
        },
        .reason = "onrun_paint_test may only import std, prim, base/*, sketch, raster, lattice, or paint",
    },
    .{
        .name = "junction_licence_test.zig",
        .allowed = &.{
            .sem_graph,                         .sketch,
            .parse_zone,                        .raster_zone,
            .{ .exact = "lattice.zig" },        .{ .exact = "select.zig" },
            .{ .exact = "ledger/permits.zig" },
        },
        .reason = "junction_licence_test may only import std, prim, base/*, sem_graph, sketch, parse, raster, lattice, select, or ledger/permits",
    },
    .{
        .name = "cluster_corridor_test.zig",
        .allowed = &.{
            .sketch,                               .parse_zone,
            .raster_zone,                          .{ .exact = "lattice.zig" },
            .{ .exact = "select.zig" },            .{ .exact = "ledger/permits.zig" },
            .{ .exact = "cluster/corridors.zig" },
        },
        .reason = "cluster_corridor_test may only import std, prim, base/*, sketch, parse, raster, lattice, select, ledger/permits, or cluster/corridors",
    },
    .{
        .name = "decoration_cell_test.zig",
        .allowed = &.{
            .parse_zone,                .raster_zone,
            .{ .exact = "select.zig" }, .{ .exact = "ledger/permits.zig" },
        },
        .reason = "decoration_cell_test may only import std, prim, base/*, parse, raster, select, or ledger/permits",
    },
    .{
        .name = "route_once_test.zig",
        .allowed = &.{
            .parse_zone,                .raster_zone,
            .{ .exact = "select.zig" }, .{ .exact = "ledger/permits.zig" },
        },
        .reason = "route_once_test may only import std, prim, base/*, parse, raster, select, or ledger/permits",
    },
    .{
        .name = "grapheme_width_test.zig",
        .allowed = &.{.{ .exact = "entry.zig" }},
        .reason = "grapheme_width_test may only import std, unicode, base/*, or entry",
    },
};

const base_reason = "base/ files may import only std and base/ siblings; types.zig alone may import unicode";

/// Returns null if the import is allowed for this file, else a reason string.
///
/// Per-zone ALLOWLIST. Each zone may import:
///   everywhere:  "std", "prim"  (named module, resolves to base/types.zig),
///                "unicode" (the width authority, lib/unicode.zig; base/
///                excepted — see below), and anything under "base/" (the
///                no-deps tier: types.zig, lanes.zig, ledger.zig,
///                diagnostics.zig — importable from every zone)
///   base/*:      std + base siblings only (no-deps tier); base/types.zig
///                alone may also import "unicode", so the width primitives
///                every zone measures with have one authority and no copy
///   sem_graph.zig / sketch.zig / lattice.zig:   + base/* (they are IR root files)
///   parse.zig + parse/*:   + sem_graph.zig
///   layout.zig + layout/*: + sem_graph.zig, sketch.zig
///   budget.zig:            + sem_graph.zig, sketch.zig, layout.zig, parse.zig
///   raster.zig + raster/*: + sketch.zig, lattice.zig
///   paint.zig + paint/*:   + lattice.zig
///   entry.zig:             anything
///
/// Sibling/internal imports within a zone (relative paths that stay inside
/// the zone, i.e. no ".." crossing to a different zone, or subdir imports
/// from the zone root file) are always allowed.
///
/// *_test.zig files follow their location's zone rules.
pub fn checkImport(rel_path: []const u8, target: []const u8) ?[]const u8 {
    const sep = std.fs.path.sep;

    if (std.mem.eql(u8, target, "std")) return null;
    if (std.mem.eql(u8, target, "prim")) return null;

    const in_base_dir = std.mem.startsWith(u8, rel_path, "base" ++ &[_]u8{sep});

    // "unicode" (lib/unicode.zig, the width authority) is open to every zone
    // but base/: the no-deps tier stays sealed except for types.zig, which
    // is where the width primitives every zone measures with live. A second
    // base/ file reaching the authority would be a second place for width
    // policy to drift.
    if (std.mem.eql(u8, target, "unicode")) {
        if (in_base_dir and !std.mem.eql(u8, rel_path, "base" ++ &[_]u8{sep} ++ "types.zig")) return base_reason;
        return null;
    }

    if (std.mem.indexOf(u8, target, "base/") != null) return null;

    if ((std.mem.eql(u8, rel_path, "layout/fan.zig") or std.mem.eql(u8, rel_path, "layout/bundle_commit.zig")) and
        std.mem.eql(u8, target, "../ledger/permits.zig")) return null;

    if (std.mem.eql(u8, rel_path, "entry.zig")) return null;

    for (file_allowlists) |fa| {
        if (!std.mem.eql(u8, rel_path, fa.name)) continue;
        for (fa.allowed) |rule| {
            if (rule.allows(target)) return null;
        }
        return fa.reason;
    }

    const in_parse_dir = std.mem.startsWith(u8, rel_path, "parse" ++ &[_]u8{sep});
    const in_layout_dir = std.mem.startsWith(u8, rel_path, "layout" ++ &[_]u8{sep});
    const in_cluster_dir = std.mem.startsWith(u8, rel_path, "cluster" ++ &[_]u8{sep});
    const in_raster_dir = std.mem.startsWith(u8, rel_path, "raster" ++ &[_]u8{sep});
    const in_paint_dir = std.mem.startsWith(u8, rel_path, "paint" ++ &[_]u8{sep});
    const in_motif_dir = std.mem.startsWith(u8, rel_path, "motif" ++ &[_]u8{sep});

    const is_parse_zone = std.mem.eql(u8, rel_path, "parse.zig") or in_parse_dir;
    const is_layout_zone = std.mem.eql(u8, rel_path, "layout.zig") or in_layout_dir;
    const is_cluster_zone = in_cluster_dir;
    const is_raster_zone = std.mem.eql(u8, rel_path, "raster.zig") or in_raster_dir;
    const is_paint_zone = std.mem.eql(u8, rel_path, "paint.zig") or in_paint_dir;
    const is_sem_graph = std.mem.eql(u8, rel_path, "sem_graph.zig");
    const is_sketch = std.mem.eql(u8, rel_path, "sketch.zig");
    const is_lattice = std.mem.eql(u8, rel_path, "lattice.zig");
    if (in_base_dir) {
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null;
        return base_reason;
    }

    const tgt_is_sem_graph = Rule.allows(.sem_graph, target);
    const tgt_is_sketch = Rule.allows(.sketch, target);
    const tgt_is_lattice = std.mem.endsWith(u8, target, "lattice.zig");

    if (is_sem_graph or is_sketch or is_lattice) {
        return "IR root file (sem_graph/sketch/lattice) may only import std and prim";
    }

    if (is_parse_zone) {
        if (tgt_is_sem_graph) return null;
        if (std.mem.startsWith(u8, target, "parse/")) return null;
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null;
        if (std.mem.eql(u8, target, "../parse.zig")) return null;
        return "parse zone may only import std, prim, sem_graph, or parse-internal files";
    }

    if (is_layout_zone) {
        if (tgt_is_sem_graph) return null;
        if (tgt_is_sketch) return null;
        if (std.mem.startsWith(u8, target, "layout/")) return null;
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null;
        if (std.mem.eql(u8, target, "../layout.zig")) return null;
        return "layout zone may only import std, prim, sem_graph, sketch, or layout-internal files";
    }

    if (is_cluster_zone) {
        if (tgt_is_sem_graph) return null;
        if (tgt_is_sketch) return null;
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null;
        return "cluster zone may only import std, prim, sem_graph, sketch, or cluster-internal files";
    }

    if (std.mem.eql(u8, rel_path, "motif.zig") or in_motif_dir) {
        if (tgt_is_sem_graph) return null;
        if (std.mem.startsWith(u8, target, "motif/")) return null;
        if (in_motif_dir and !std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null;
        if (std.mem.eql(u8, target, "../motif.zig")) return null;
        return "motif zone may only import std, prim, sem_graph, or motif-internal files";
    }

    if (is_raster_zone) {
        if (tgt_is_sketch) return null;
        if (tgt_is_lattice) return null;
        if (std.mem.startsWith(u8, target, "raster/")) return null;
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null;
        return "raster zone may only import std, prim, sketch, lattice, or raster-internal files";
    }

    if (is_paint_zone) {
        if (tgt_is_lattice) return null;
        if (std.mem.startsWith(u8, target, "paint/")) return null;
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null;
        return "paint zone may only import std, prim, lattice, or paint-internal files";
    }

    return "file is in no known zone (add a zone allowlist in checkImport)";
}

test "the width authority is open to every zone but sealed off base/ except types.zig" {
    try std.testing.expectEqual(@as(?[]const u8, null), checkImport("base/types.zig", "unicode"));
    try std.testing.expectEqual(@as(?[]const u8, null), checkImport("raster/labels_write.zig", "unicode"));
    try std.testing.expectEqual(@as(?[]const u8, null), checkImport("grapheme_width_test.zig", "unicode"));
    try std.testing.expectEqualStrings(base_reason, checkImport("base/lanes.zig", "unicode").?);
    try std.testing.expectEqualStrings(base_reason, checkImport("base/types_test.zig", "unicode").?);
    try std.testing.expectEqualStrings(base_reason, checkImport("base/types.zig", "../lattice.zig").?);
    try std.testing.expectEqual(@as(?[]const u8, null), checkImport("base/types.zig", "types_test.zig"));
}
