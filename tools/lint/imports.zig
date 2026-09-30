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

pub const Rule = union(enum) {
    sem_graph,
    sketch,
    budget,
    recurse,
    layout_zone,
    parse_zone,
    cluster_zone,
    raster_zone,
    exact: []const u8,

    fn allows(rule: Rule, target: []const u8) bool {
        return switch (rule) {
            .sem_graph => std.mem.endsWith(u8, target, "sem_graph.zig"),
            .sketch => std.mem.endsWith(u8, target, "sketch.zig") or
                std.mem.endsWith(u8, target, "sketch_ports.zig") or
                std.mem.endsWith(u8, target, "sketch_bundles.zig") or
                std.mem.endsWith(u8, target, "sketch_clearance.zig"),
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
        .name = "realized_production_test.zig",
        .allowed = &.{ .parse_zone, .{ .exact = "ledger/permits.zig" }, .{ .exact = "select.zig" }, .{ .exact = "raster.zig" }, .{ .exact = "paint.zig" } },
        .reason = "realized_production_test may only import std, prim, base/ledger, parse, permits, select, raster, or paint",
    },
    .{
        .name = "render_evidence_test.zig",
        .allowed = &.{ .sem_graph, .sketch, .layout_zone, .raster_zone, .{ .exact = "ledger/permits.zig" }, .{ .exact = "paint.zig" }, .{ .exact = "select.zig" } },
        .reason = "render_evidence_test may only import std, prim, base/*, sem_graph, sketch, layout, permits, raster, paint, or select",
    },
    .{
        .name = "budget.zig",
        .allowed = &.{ .sem_graph, .sketch, .layout_zone, .parse_zone, .cluster_zone, .recurse, .{ .exact = "budget_test.zig" } },
        .reason = "budget may only import std, prim, sem_graph, sketch, layout, parse, recurse, cluster, or budget_test",
    },
    .{
        .name = "recurse.zig",
        .allowed = &.{ .sem_graph, .sketch, .layout_zone, .cluster_zone, .{ .exact = "recurse_test.zig" } },
        .reason = "recurse may only import std, prim, sem_graph, sketch, layout, cluster, or recurse_test",
    },
    .{
        .name = "recurse_test.zig",
        .allowed = &.{ .recurse, .sem_graph, .sketch, .layout_zone, .cluster_zone, .raster_zone },
        .reason = "recurse_test may only import std, prim, base/*, recurse, sem_graph, sketch, layout, cluster, or raster",
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
        .name = "sketch_clearance.zig",
        .allowed = &.{ .sketch, .{ .exact = "sketch_clearance_test.zig" } },
        .reason = "sketch_clearance may only import std, prim, sketch, or sketch_clearance_test",
    },
    .{
        .name = "sketch_clearance_test.zig",
        .allowed = &.{ .sketch, .{ .exact = "sketch_clearance.zig" } },
        .reason = "sketch_clearance_test may only import std, prim, sketch, or sketch_clearance",
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
        .name = "select.zig",
        .allowed = &.{ .sem_graph, .sketch, .budget, .parse_zone, .raster_zone, .{ .exact = "score.zig" }, .{ .exact = "motif.zig" }, .{ .exact = "ledger/permits.zig" } },
        .reason = "select may only import std, prim, base/ledger, sem_graph, sketch, budget, score, motif, raster, ledger/permits, or parse",
    },
    .{
        .name = "select_test.zig",
        .allowed = &.{ .sem_graph, .sketch, .budget, .parse_zone, .{ .exact = "select.zig" }, .{ .exact = "ledger/permits.zig" }, .{ .exact = "raster.zig" }, .{ .exact = "score.zig" } },
        .reason = "select_test may only import std, prim, base/ledger, sem_graph, sketch, budget, parse, select, ledger/permits, raster, or score",
    },
    .{
        .name = "budget_test.zig",
        .allowed = &.{ .budget, .sem_graph, .sketch, .parse_zone, .{ .exact = "build_options" }, .{ .exact = "score.zig" }, .{ .exact = "select.zig" } },
        .reason = "budget_test may only import std, prim, build_options, budget, sem_graph, sketch, parse, score, or select",
    },
    .{
        .name = "layout/bundle_commit_test.zig",
        .allowed = &.{ .parse_zone, .{ .exact = "../ledger/permits.zig" }, .{ .exact = "bundle_commit.zig" } },
        .reason = "bundle_commit_test may only import std, prim, base/ledger, parse, permits, or bundle_commit",
    },
    .{
        .name = "layout/port_plan_test.zig",
        .allowed = &.{ .sem_graph, .sketch, .layout_zone, .{ .exact = "../ledger/permits.zig" }, .{ .exact = "ports.zig" }, .{ .exact = "port_plan.zig" } },
        .reason = "port_plan_test may import the focused layout and permit surfaces",
    },
    .{
        .name = "raster/rails_test.zig",
        .allowed = &.{ .sketch, .{ .exact = "../lattice.zig" }, .{ .exact = "rails.zig" }, .{ .exact = "nodes.zig" }, .{ .exact = "../raster.zig" } },
        .reason = "rails_test may only import std, prim, sketch, lattice, raster siblings, or raster",
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
        .name = "entry_test.zig",
        .allowed = &.{ .parse_zone, .raster_zone, .budget, .{ .exact = "entry.zig" }, .{ .exact = "select.zig" } },
        .reason = "entry_test may only import std, prim, base/*, parse, raster, budget, select, or entry",
    },
    .{
        .name = "candidates.zig",
        .allowed = &.{
            .sem_graph,
            .budget,
            .raster_zone,
            .{ .exact = "select.zig" },
            .{ .exact = "paint.zig" },
        },
        .reason = "candidates may only import std, prim, base/*, sem_graph, budget, select, raster, or paint",
    },
    .{
        .name = "candidates_test.zig",
        .allowed = &.{ .parse_zone, .{ .exact = "entry.zig" }, .{ .exact = "candidates.zig" } },
        .reason = "candidates_test may only import std, prim, parse, entry, or candidates",
    },
    .{
        .name = "grapheme_width_test.zig",
        .allowed = &.{.{ .exact = "entry.zig" }},
        .reason = "grapheme_width_test may only import std, unicode, base/*, or entry",
    },
};

const base_reason = "base/ files may import only std and base/ siblings; types.zig alone may import unicode";

pub fn checkImport(rel_path: []const u8, target: []const u8) ?[]const u8 {
    const sep = std.fs.path.sep;

    if (std.mem.eql(u8, target, "std")) return null;
    if (std.mem.eql(u8, target, "prim")) return null;

    const in_base_dir = std.mem.startsWith(u8, rel_path, "base" ++ &[_]u8{sep});

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
