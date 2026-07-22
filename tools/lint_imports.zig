//! Import-boundary, file-size, and no-fallback linter for src/core/mermaid_v2/.
//!
//! Run via `zig build lint`. Walks the root directory recursively, reads every
//! `.zig` file, and checks:
//!   1. ≤ 500 newlines per file.
//!   2. No path component equals "fallback".
//!   3. Per-file `@import("...")` rules (see `checkImport` below).
//!   4. Every `guarded-by: <file> "<test>"` pointer resolves to a real test
//!      declaration somewhere in the tree (anchors the comment-promotion
//!      convention so a renamed/deleted test breaks the build, not silently).
//!
//! Exits 0 on success, 1 on any violation, 2 on I/O / missing-root errors.

const std = @import("std");

pub const LintReport = struct {
    violations: []const []const u8,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *LintReport) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// Walk `root` recursively and produce a report of every lint violation.
pub fn lint(allocator: std.mem.Allocator, root: []const u8) !LintReport {
    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    const a = arena_ptr.allocator();

    var violations: std.ArrayList([]const u8) = .empty;

    // Check 4 accumulators, cross-checked after the walk. Every slice below
    // points into arena-owned storage (file contents are never freed mid-walk),
    // so they stay valid until the report is deinit'd.
    var test_decls: std.ArrayList(TestDecl) = .empty;
    var gb_refs: std.ArrayList(GbRef) = .empty;
    var seen_files: std.ArrayList([]const u8) = .empty;

    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
        const msg = try std.fmt.allocPrint(a, "error: cannot open root '{s}': {s}", .{ root, @errorName(err) });
        try violations.append(a, msg);
        return LintReport{ .violations = try violations.toOwnedSlice(a), .arena = arena_ptr };
    };
    defer dir.close();

    var walker = try dir.walk(a);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        // Check 2: no "fallback" component.
        var it = std.mem.tokenizeScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |comp| {
            if (std.mem.eql(u8, comp, "fallback")) {
                const msg = try std.fmt.allocPrint(a, "{s}: forbidden 'fallback/' path component", .{entry.path});
                try violations.append(a, msg);
                break;
            }
        }

        // Read the file.
        const file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();
        const contents = try file.readToEndAlloc(a, 8 * 1024 * 1024);

        // Check 1: 500-line cap (count newlines).
        var newlines: usize = 0;
        for (contents) |c| {
            if (c == '\n') newlines += 1;
        }
        if (newlines > 500) {
            const msg = try std.fmt.allocPrint(a, "{s}: {d} newlines exceeds 500-line cap", .{ entry.path, newlines });
            try violations.append(a, msg);
        }

        // Check 3: import boundaries.
        try scanImports(a, &violations, entry.path, contents);

        // Check 4: collect test declarations and guarded-by pointers.
        const base_owned = try a.dupe(u8, entry.basename);
        try seen_files.append(a, base_owned);
        try collectTests(a, &test_decls, base_owned, contents);
        try collectGuardedBy(a, &gb_refs, try a.dupe(u8, entry.path), contents);
    }

    try verifyGuardedBy(a, &violations, seen_files.items, test_decls.items, gb_refs.items);

    return LintReport{ .violations = try violations.toOwnedSlice(a), .arena = arena_ptr };
}

fn scanImports(
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

/// A `test "..."` declaration, keyed by the file basename it lives in.
const TestDecl = struct { file: []const u8, name: []const u8 };

/// A `guarded-by: <file> "<name>"` pointer plus the file it was found in.
const GbRef = struct { src: []const u8, file: []const u8, name: []const u8 };

/// guarded-by targets that live outside the scanned tree (their existence is
/// checked elsewhere): a pointer at a lint rule itself, not at a test.
const gb_external = [_][]const u8{"lint_imports.zig"};

/// Record every container-scope `test "..."` name in `contents` under `file_base`.
fn collectTests(
    a: std.mem.Allocator,
    list: *std.ArrayList(TestDecl),
    file_base: []const u8,
    contents: []const u8,
) !void {
    const needle = "test \"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, contents, i, needle)) |start| {
        i = start + needle.len;
        // Require `test "` to be the first token on its line (indent allowed),
        // so `// test "x"` in a comment or `foo test "` in prose is not counted.
        var p = start;
        while (p > 0 and (contents[p - 1] == ' ' or contents[p - 1] == '\t')) p -= 1;
        if (p != 0 and contents[p - 1] != '\n') continue;
        const name_start = start + needle.len; // just past the opening quote
        const q_close = std.mem.indexOfScalarPos(u8, contents, name_start, '"') orelse break;
        try list.append(a, .{ .file = file_base, .name = contents[name_start..q_close] });
        i = q_close + 1;
    }
}

/// Record every `guarded-by: <file> "<name>"` pointer in `contents`. The file
/// is reduced to its basename, so a ref may spell a zone-relative path.
fn collectGuardedBy(
    a: std.mem.Allocator,
    list: *std.ArrayList(GbRef),
    src: []const u8,
    contents: []const u8,
) !void {
    const needle = "guarded-by: ";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, contents, i, needle)) |start| {
        const after = start + needle.len;
        const line_end = std.mem.indexOfScalarPos(u8, contents, after, '\n') orelse contents.len;
        i = line_end;
        const q1 = std.mem.indexOfScalarPos(u8, contents, after, '"') orelse continue;
        if (q1 >= line_end) continue;
        const q2 = std.mem.indexOfScalarPos(u8, contents, q1 + 1, '"') orelse continue;
        if (q2 >= line_end) continue;
        var file_tok = std.mem.trim(u8, contents[after..q1], " \t");
        if (std.mem.lastIndexOfScalar(u8, file_tok, '/')) |s| file_tok = file_tok[s + 1 ..];
        try list.append(a, .{ .src = src, .file = file_tok, .name = contents[q1 + 1 .. q2] });
    }
}

/// Flag guarded-by pointers whose target file or test name cannot be found.
/// Test matching is by basename, so the two `clusters_test.zig` siblings both
/// satisfy a ref that names either — good enough to catch renames/deletions.
fn verifyGuardedBy(
    a: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    seen_files: []const []const u8,
    tests: []const TestDecl,
    refs: []const GbRef,
) !void {
    outer: for (refs) |ref| {
        for (gb_external) |ext| if (std.mem.eql(u8, ref.file, ext)) continue :outer;

        var file_seen = false;
        for (seen_files) |sf| {
            if (std.mem.eql(u8, sf, ref.file)) {
                file_seen = true;
                break;
            }
        }
        if (!file_seen) {
            try violations.append(a, try std.fmt.allocPrint(
                a,
                "{s}: guarded-by target file \"{s}\" not found",
                .{ ref.src, ref.file },
            ));
            continue;
        }

        var test_found = false;
        for (tests) |t| {
            if (std.mem.eql(u8, t.file, ref.file) and std.mem.eql(u8, t.name, ref.name)) {
                test_found = true;
                break;
            }
        }
        if (!test_found) {
            try violations.append(a, try std.fmt.allocPrint(
                a,
                "{s}: guarded-by test \"{s}\" not found in {s}",
                .{ ref.src, ref.name, ref.file },
            ));
        }
    }
}

/// One allowed-import pattern for a table-driven per-file allowlist.
/// The zone patterns replicate the `tgt_is_*` booleans in `checkImport`.
const Rule = union(enum) {
    /// endsWith "sem_graph.zig" (direct or parent-relative).
    sem_graph,
    /// endsWith "sketch.zig".
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
            .sketch => std.mem.endsWith(u8, target, "sketch.zig"),
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
///   base/*          the no-deps tier (types.zig / lanes.zig / ledger.zig):
///                   std + base siblings only; importable from every zone.
///                   Enforced by the base/ dir rule + the in_base_dir zone
///                   block in `checkImport`, not by a `file_allowlists` row.
///   ledger/permits.zig  semantic permission discovery (D-IR item 3):
///                   base/ledger + sem_graph.
///   ledger/realized.zig candidate-local realized-join planner (D-IR item 8):
///                   JoinPermits + candidate Sketch only.
///   ledger/invariants.zig  the realized-join output validator
///                   (split sibling of realized.zig for the 500-line cap).
///   ledger/reach_vector.zig  pre-raster D-REACH vector reachability
///                   oracle (P2v Step 6, report-only; D-IR item 9):
///                   candidate Sketch + joins only, plus its two split
///                   siblings (reach_geometry decomposition, reach_report
///                   table types).
///   select_test.zig  select.zig's test sibling (Step 4 cap-watch
///                   mitigation, plan N3): drives the pub select surface
///                   over parsed graphs and pins Step 6 report-only
///                   inertness against ledger/reach_vector.
///   budget.zig      the ladder driver (+ its split-out test sibling).
///   recurse.zig     cut-layout-stitch recursion: layout/ + cluster/ pairing.
///   score.zig       pure candidate score; layout/validate.zig is the ONE
///                   layout file it may reach (NOT the layout zone).
///   score_geom.zig  pure geometric T2 measurements over a Sketch.
///   score_test.zig  drives the pub score surface over hand-built Sketches.
///   score_calibration_test.zig  isolated boundary-crossing tests for the
///                   fitted RUNG_SCALE/switch-scale/W_* constants (split out
///                   of score_test.zig to keep both under the 500-line cap).
///   select.zig      candidate construction + live selection (Phase 3b/4a).
///   audit.zig       per-candidate raster audit (Phase 4a).
///   budget_test.zig graph-level ladder tests + the labeled-set calibration
///                   test (parse → select → audit → score = the live path).
///   recurse_test.zig integration tests for the cut-layout-stitch recursion
///                   that need both cluster/ and layout/ zone privileges
///                   (split out to keep recurse.zig under the 500-line cap).
const file_allowlists = [_]struct {
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
        .name = "ledger/realized.zig",
        .allowed = &.{ .sketch, .{ .exact = "mesh_legal.zig" } },
        .reason = "realized may only import std, prim, base/ledger, sketch, or mesh_legal",
    },
    .{
        .name = "ledger/mesh_legal.zig",
        .allowed = &.{},
        .reason = "mesh_legal may only import std, prim, or base/ledger",
    },
    .{
        .name = "ledger/realized_test.zig",
        .allowed = &.{ .sketch, .sem_graph, .parse_zone, .{ .exact = "realized.zig" }, .{ .exact = "permits.zig" }, .{ .exact = "../select.zig" } },
        .reason = "realized_test may only import std, prim, base/ledger, sketch, sem_graph, parse, realized, permits, or select",
    },
    .{
        .name = "ledger/realized_test2.zig",
        .allowed = &.{ .sketch, .sem_graph, .parse_zone, .{ .exact = "realized.zig" }, .{ .exact = "invariants.zig" }, .{ .exact = "permits.zig" }, .{ .exact = "../select.zig" } },
        .reason = "realized_test2 may only import std, prim, base/ledger, sketch, sem_graph, parse, realized, invariants, permits, or select",
    },
    .{
        // P2v Step 8 integration test file: drives the CI filter + terminal
        // candidate through real reach geometry (fusing/complete unions),
        // disposeUnsafe, and end-to-end render. A dedicated test file with a
        // broad allowlist (test rows may be extended) rather than spreading
        // across siblings that would each need new production-adjacent rows.
        .name = "ledger/disposition_test.zig",
        .allowed = &.{ .sem_graph, .sketch, .budget, .parse_zone, .raster_zone, .{ .exact = "permits.zig" }, .{ .exact = "realized.zig" }, .{ .exact = "invariants.zig" }, .{ .exact = "reach_vector.zig" }, .{ .exact = "reach_vector_test.zig" }, .{ .exact = "../select.zig" }, .{ .exact = "../paint.zig" } },
        .reason = "disposition_test may only import std, prim, base/ledger, sem_graph, sketch, budget, parse, permits, realized, invariants, reach_vector, reach_vector_test, select, raster, or paint",
    },
    .{
        .name = "ledger/realized_production_test.zig",
        .allowed = &.{ .parse_zone, .{ .exact = "permits.zig" }, .{ .exact = "reach_vector.zig" }, .{ .exact = "../select.zig" }, .{ .exact = "../raster.zig" }, .{ .exact = "../paint.zig" } },
        .reason = "realized_production_test may only import std, prim, base/ledger, parse, permits, reach_vector, select, raster, or paint",
    },
    .{
        .name = "ledger/invariants.zig",
        .allowed = &.{ .sketch, .{ .exact = "realized.zig" } },
        .reason = "invariants may only import std, prim, base/ledger, sketch, or realized",
    },
    .{
        .name = "ledger/reach_vector.zig",
        .allowed = &.{ .sketch, .{ .exact = "reach_geometry.zig" }, .{ .exact = "reach_report.zig" } },
        .reason = "reach_vector may only import std, prim, base/ledger, sketch, or its geom/report split siblings",
    },
    .{
        .name = "ledger/reach_geometry.zig",
        .allowed = &.{.sketch},
        .reason = "reach_geometry may only import std, prim, base/ledger, or sketch",
    },
    .{
        .name = "ledger/reach_report.zig",
        .allowed = &.{ .sketch, .{ .exact = "reach_geometry.zig" } },
        .reason = "reach_report may only import std, prim, base/ledger, sketch, or reach_geometry",
    },
    .{
        .name = "ledger/reach_vector_test.zig",
        .allowed = &.{ .sketch, .sem_graph, .parse_zone, .{ .exact = "reach_vector.zig" }, .{ .exact = "realized.zig" }, .{ .exact = "permits.zig" } },
        .reason = "reach_vector_test may only import std, prim, base/ledger, sketch, sem_graph, parse, reach_vector, realized, or permits",
    },
    .{
        .name = "ledger/reach_vector_test2.zig",
        .allowed = &.{ .sketch, .sem_graph, .parse_zone, .{ .exact = "reach_vector.zig" }, .{ .exact = "realized.zig" }, .{ .exact = "permits.zig" }, .{ .exact = "reach_vector_test.zig" } },
        .reason = "reach_vector_test2 may only import std, prim, base/ledger, sketch, sem_graph, parse, reach_vector, realized, permits, or reach_vector_test",
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
        .allowed = &.{ .recurse, .sem_graph, .sketch, .layout_zone, .cluster_zone },
        .reason = "recurse_test may only import std, prim, recurse, sem_graph, sketch, layout, or cluster",
    },
    .{
        .name = "score.zig",
        .allowed = &.{ .sem_graph, .sketch, .{ .exact = "layout/validate.zig" }, .{ .exact = "score_geom.zig" }, .{ .exact = "score_test.zig" }, .{ .exact = "score_calibration_test.zig" } },
        .reason = "score may only import std, prim, sem_graph, sketch, layout/validate.zig, score_geom, score_test, or score_calibration_test",
    },
    .{
        .name = "score_geom.zig",
        .allowed = &.{.sketch},
        .reason = "score_geom may only import std, prim, or sketch",
    },
    .{
        .name = "score_test.zig",
        .allowed = &.{ .sketch, .{ .exact = "score.zig" } },
        .reason = "score_test may only import std, prim, sketch, or score",
    },
    .{
        .name = "score_calibration_test.zig",
        .allowed = &.{ .sketch, .{ .exact = "score.zig" } },
        .reason = "score_calibration_test may only import std, prim, sketch, or score",
    },
    .{
        .name = "select.zig",
        .allowed = &.{ .sem_graph, .sketch, .budget, .parse_zone, .{ .exact = "score.zig" }, .{ .exact = "motif.zig" }, .{ .exact = "audit.zig" }, .{ .exact = "ledger/realized.zig" }, .{ .exact = "ledger/invariants.zig" }, .{ .exact = "ledger/reach_vector.zig" }, .{ .exact = "select_filter.zig" } },
        .reason = "select may only import std, prim, base/ledger, sem_graph, sketch, budget, score, motif, audit, ledger/realized, ledger/invariants, ledger/reach_vector, select_filter, or parse",
    },
    .{
        // P2v Step 8 cap-forced split of select.zig (plan's "Lint: None" line
        // could not hold once the filter + terminal candidate + `excluded`
        // surface pushed select.zig over the 500-line cap). Strict subset of
        // select.zig's imports: no score/audit/motif/sketch/invariants.
        .name = "select_filter.zig",
        .allowed = &.{ .sem_graph, .budget, .{ .exact = "ledger/realized.zig" }, .{ .exact = "ledger/reach_vector.zig" } },
        .reason = "select_filter may only import std, prim, base/ledger, sem_graph, budget, ledger/realized, or ledger/reach_vector",
    },
    .{
        .name = "select_test.zig",
        .allowed = &.{ .budget, .parse_zone, .{ .exact = "select.zig" }, .{ .exact = "ledger/permits.zig" }, .{ .exact = "ledger/reach_vector.zig" } },
        .reason = "select_test may only import std, prim, base/ledger, budget, parse, select, ledger/permits, or ledger/reach_vector",
    },
    .{
        .name = "audit.zig",
        .allowed = &.{ .sketch, .raster_zone, .{ .exact = "score.zig" } },
        .reason = "audit may only import std, prim, sketch, raster, or score",
    },
    .{
        .name = "budget_test.zig",
        .allowed = &.{ .budget, .sem_graph, .sketch, .parse_zone, .{ .exact = "score.zig" }, .{ .exact = "select.zig" }, .{ .exact = "audit.zig" } },
        .reason = "budget_test may only import std, prim, budget, sem_graph, sketch, parse, score, select, or audit",
    },
    .{
        .name = "layout/join_commit_test.zig",
        .allowed = &.{ .parse_zone, .{ .exact = "../ledger/permits.zig" }, .{ .exact = "../ledger/realized.zig" }, .{ .exact = "../select.zig" } },
        .reason = "join_commit_test may only import std, prim, base/ledger, parse, permits, realized, or select",
    },
    .{
        .name = "raster/busbars_test.zig",
        .allowed = &.{ .sketch, .{ .exact = "../lattice.zig" }, .{ .exact = "busbars.zig" }, .{ .exact = "nodes.zig" }, .{ .exact = "../raster.zig" } },
        .reason = "busbars_test may only import std, prim, sketch, lattice, raster siblings, or raster",
    },
};

/// Returns null if the import is allowed for this file, else a reason string.
///
/// Per-zone ALLOWLIST. Each zone may import:
///   everywhere:  "std", "prim"  (named module, resolves to base/types.zig),
///                and anything under "base/" (the no-deps tier: types.zig,
///                lanes.zig, ledger.zig — importable from every zone)
///   base/*:      std + base siblings only (no-deps tier)
///   sem_graph.zig / sketch.zig / lattice.zig:   + each other (they are IR root files)
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
fn checkImport(rel_path: []const u8, target: []const u8) ?[]const u8 {
    const sep = std.fs.path.sep;

    // "std" and "prim" (named module) are always allowed. The "prim" named
    // module now resolves to base/types.zig (see build.zig); the name is kept.
    if (std.mem.eql(u8, target, "std")) return null;
    if (std.mem.eql(u8, target, "prim")) return null;

    // Anything under base/ (types.zig / lanes.zig / ledger.zig) is importable
    // from every zone — the no-deps tier — mirroring the retired per-file
    // universal exemptions the base-tier modules used to carry. Matches
    // "base/types.zig", "../base/lanes.zig", "base/ledger.zig", etc. base/
    // files' OWN rule (std + base siblings only) is the in_base_dir zone block
    // below.
    if (std.mem.indexOf(u8, target, "base/") != null) return null;

    // entry.zig — composition root, may import anything.
    if (std.mem.eql(u8, rel_path, "entry.zig")) return null;

    // Root-level single-file zones: table-driven (see `file_allowlists`).
    for (file_allowlists) |fa| {
        if (!std.mem.eql(u8, rel_path, fa.name)) continue;
        for (fa.allowed) |rule| {
            if (rule.allows(target)) return null;
        }
        return fa.reason;
    }

    // Determine the zone of the file being checked.
    const in_parse_dir = std.mem.startsWith(u8, rel_path, "parse" ++ &[_]u8{sep});
    const in_layout_dir = std.mem.startsWith(u8, rel_path, "layout" ++ &[_]u8{sep});
    const in_cluster_dir = std.mem.startsWith(u8, rel_path, "cluster" ++ &[_]u8{sep});
    const in_raster_dir = std.mem.startsWith(u8, rel_path, "raster" ++ &[_]u8{sep});
    const in_paint_dir = std.mem.startsWith(u8, rel_path, "paint" ++ &[_]u8{sep});
    const in_motif_dir = std.mem.startsWith(u8, rel_path, "motif" ++ &[_]u8{sep});

    const is_parse_zone = std.mem.eql(u8, rel_path, "parse.zig") or in_parse_dir;
    const is_layout_zone = std.mem.eql(u8, rel_path, "layout.zig") or in_layout_dir;
    // The cluster zone is folder-only (no `cluster.zig` root file): pure
    // cut/glue helpers that read SemGraph and edit Sketch, same level as
    // layout/. Only the driver (budget.zig) may import it.
    const is_cluster_zone = in_cluster_dir;
    const is_raster_zone = std.mem.eql(u8, rel_path, "raster.zig") or in_raster_dir;
    const is_paint_zone = std.mem.eql(u8, rel_path, "paint.zig") or in_paint_dir;
    const is_sem_graph = std.mem.eql(u8, rel_path, "sem_graph.zig");
    const is_sketch = std.mem.eql(u8, rel_path, "sketch.zig");
    const is_lattice = std.mem.eql(u8, rel_path, "lattice.zig");
    const in_base_dir = std.mem.startsWith(u8, rel_path, "base" ++ &[_]u8{sep});

    // base/ files (the no-deps tier): std (above), the "prim" named module
    // (above), any base/ target (above), and base/ siblings by bare basename.
    if (in_base_dir) {
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null;
        return "base/ files may import only std and base/ siblings";
    }

    // Helper: does `target` resolve to one of the named root IR files?
    // Handles both direct ("sem_graph.zig") and parent-relative ("../sem_graph.zig") forms.
    // (The single-file zones above match the same patterns via `Rule.allows`.)
    const tgt_is_sem_graph = Rule.allows(.sem_graph, target);
    const tgt_is_sketch = Rule.allows(.sketch, target);
    const tgt_is_lattice = std.mem.endsWith(u8, target, "lattice.zig");

    // sem_graph.zig, sketch.zig, lattice.zig: std + prim only (these are IR leaf files).
    if (is_sem_graph or is_sketch or is_lattice) {
        // Only std, prim allowed (already checked above).
        return "IR root file (sem_graph/sketch/lattice) may only import std and prim";
    }

    // parse zone: std, prim, sem_graph, and internal parse/* siblings.
    if (is_parse_zone) {
        if (tgt_is_sem_graph) return null;
        // Internal parse siblings (from parse.zig: "parse/lexer.zig", "parse/parse_test.zig";
        // from parse/: bare names like "lexer.zig", "../parse.zig").
        if (std.mem.startsWith(u8, target, "parse/")) return null; // parse root → subdir
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null; // sibling basename
        if (std.mem.eql(u8, target, "../parse.zig")) return null; // subfile → parse root
        return "parse zone may only import std, prim, sem_graph, or parse-internal files";
    }

    // layout zone: std, prim, sem_graph, sketch, and internal layout/* siblings.
    if (is_layout_zone) {
        if (tgt_is_sem_graph) return null;
        if (tgt_is_sketch) return null;
        // Internal layout siblings.
        if (std.mem.startsWith(u8, target, "layout/")) return null; // layout root → subdir
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null; // sibling basename
        if (std.mem.eql(u8, target, "../layout.zig")) return null; // layout/layout_test.zig → layout.zig
        return "layout zone may only import std, prim, sem_graph, sketch, or layout-internal files";
    }

    // cluster zone: pure data cut/glue. std, prim, sem_graph, sketch, and
    // internal cluster/* siblings ONLY. Physically cannot reach right/up
    // (layout, budget, raster, paint all rejected) — the driver does the
    // running, cluster/ only transforms data.
    if (is_cluster_zone) {
        if (tgt_is_sem_graph) return null;
        if (tgt_is_sketch) return null;
        // Sibling basename imports inside cluster/.
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null;
        return "cluster zone may only import std, prim, sem_graph, sketch, or cluster-internal files";
    }

    // motif zone: the pure-data MotifTree (IR 1.5) decomposition (Phase 3a
    // of the integrity-gated-search work). IR-leaf rule:
    // std, prim, sem_graph, and motif-internal files ONLY — it may
    // NOT reach layout/ (its cycle removal is a local reimplementation) nor
    // cluster/ (membership semantics are mirrored, not imported).
    if (std.mem.eql(u8, rel_path, "motif.zig") or in_motif_dir) {
        if (tgt_is_sem_graph) return null;
        if (std.mem.startsWith(u8, target, "motif/")) return null; // motif root → subdir
        if (in_motif_dir and !std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null; // sibling basename
        if (std.mem.eql(u8, target, "../motif.zig")) return null; // subfile → motif root
        return "motif zone may only import std, prim, sem_graph, or motif-internal files";
    }

    // raster zone: std, prim, sketch, lattice, and internal raster/* siblings.
    if (is_raster_zone) {
        if (tgt_is_sketch) return null;
        if (tgt_is_lattice) return null;
        // Internal raster siblings.
        if (std.mem.startsWith(u8, target, "raster/")) return null; // raster root → subdir
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null; // sibling basename
        return "raster zone may only import std, prim, sketch, lattice, or raster-internal files";
    }

    // paint zone: std, prim, lattice, and internal paint/* siblings.
    if (is_paint_zone) {
        if (tgt_is_lattice) return null;
        // Internal paint siblings.
        if (std.mem.startsWith(u8, target, "paint/")) return null; // paint root → subdir
        if (!std.mem.startsWith(u8, target, "..") and std.mem.endsWith(u8, target, ".zig")) return null; // sibling basename
        return "paint zone may only import std, prim, lattice, or paint-internal files";
    }

    // Defensive: any file in an unrecognised folder reaches here. It must
    // NOT be silently exempt from every rule (that would make a new zone
    // like cluster/ unrestricted if its allowlist branch were forgotten).
    // The known zones above all return before this point.
    return "file is in no known zone (add a zone allowlist in checkImport)";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const root: []const u8 = if (args.len >= 2) args[1] else "src/core/mermaid_v2";

    // Probe root before walking to give a clean exit-2 error.
    {
        var probe = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
            std.debug.print("lint: cannot open root '{s}': {s}\n", .{ root, @errorName(err) });
            std.process.exit(2);
        };
        probe.close();
    }

    var report = try lint(allocator, root);
    defer report.deinit();

    if (report.violations.len == 0) {
        std.process.exit(0);
    }

    for (report.violations) |v| std.debug.print("{s}\n", .{v});
    std.process.exit(1);
}

test "lint flags bad fixtures" {
    const allocator = std.testing.allocator;
    var report = try lint(allocator, "tools/lint_fixtures/bad");
    defer report.deinit();

    var saw_big = false;
    var saw_fallback = false;
    for (report.violations) |v| {
        if (std.mem.indexOf(u8, v, "big_file.zig") != null) saw_big = true;
        if (std.mem.indexOf(u8, v, "dummy.zig") != null and std.mem.indexOf(u8, v, "fallback") != null) saw_fallback = true;
    }
    try std.testing.expect(report.violations.len >= 2);
    try std.testing.expect(saw_big);
    try std.testing.expect(saw_fallback);
}
