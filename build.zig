const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    const koino_dep = b.dependency("koino", .{ .target = target, .optimize = optimize });
    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    options.addOption([]const u8, "version", "0.2.0");

    // =====================================================
    // Shared Modules (for reuse across targets)
    // =====================================================
    const prim_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid_v2/base/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mermaid_v2_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid_v2/entry.zig"),
        .target = target,
        .optimize = optimize,
    });
    mermaid_v2_mod.addImport("prim", prim_mod);

    // =====================================================
    // Main Executable
    // =====================================================
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", options);
    root_module.addImport("koino", koino_dep.module("koino"));
    root_module.addImport("vaxis", vaxis_dep.module("vaxis"));
    root_module.addImport("prim", prim_mod);
    // Native export font service (src/export/font.zig): embedded JetBrains Mono
    // + vendored stb_truetype. See linkExportFont below.
    linkExportFont(b, root_module);

    const exe = b.addExecutable(.{
        .name = "mercat",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    // Absolute path to the installed mercat binary, exposed to the test graph so
    // the export verification suite (src/export/export_test.zig) can spawn it in
    // separate processes (§8.2 determinism, §8.3 CLI). `zig build test` is made
    // to depend on the install step below so the binary exists when tests run.
    options.addOption([]const u8, "mercat_exe_path", b.getInstallPath(.bin, "mercat"));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run mercat");
    run_step.dependOn(&run_cmd.step);

    // =====================================================
    // Unit Tests (existing)
    // =====================================================
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", options);
    test_module.addImport("koino", koino_dep.module("koino"));
    test_module.addImport("vaxis", vaxis_dep.module("vaxis"));
    test_module.addImport("prim", prim_mod);
    linkExportFont(b, test_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_run = b.addRunArtifact(unit_tests);
    // The export verification suite spawns the installed mercat binary, so build +
    // install it before running the unit tests.
    test_run.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);

    // =====================================================
    // Export Font Tests (standalone root at src/export/font.zig)
    // =====================================================
    // font.zig is not reachable from the main.zig import graph yet (the PNG
    // backend is wired in a later stage), so its unit tests get their own test
    // root. This is also the reference "standalone export test executable"
    // carrying the stb_truetype C integration.
    const font_test_module = b.createModule(.{
        .root_source_file = b.path("src/export/font.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkExportFont(b, font_test_module);

    const font_tests = b.addTest(.{ .root_module = font_test_module });
    const font_test_run = b.addRunArtifact(font_tests);
    const font_test_step = b.step("test-export-font", "Run export font-service tests");
    font_test_step.dependOn(&font_test_run.step);
    test_step.dependOn(&font_test_run.step);

    // =====================================================
    // Property Tests
    // =====================================================
    const sem_graph_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid_v2/sem_graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    sem_graph_mod.addImport("prim", prim_mod);

    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid_v2/parse.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_mod.addImport("prim", prim_mod);

    const prop_test_module = b.createModule(.{
        .root_source_file = b.path("tests/property/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_test_module.addImport("sem_graph", sem_graph_mod);
    prop_test_module.addImport("parser", parser_mod);
    prop_test_module.addImport("mermaid_v2", mermaid_v2_mod);

    const prop_tests = b.addTest(.{
        .root_module = prop_test_module,
    });

    const prop_test_run = b.addRunArtifact(prop_tests);
    const prop_test_step = b.step("test-property", "Run property-based tests");
    prop_test_step.dependOn(&prop_test_run.step);

    // Existing `test` step also runs property tests.
    test_step.dependOn(&prop_test_run.step);

    // mermaid_v2 layout/sketch tests — rooted at entry.zig so the file
    // tree's relative imports resolve.
    const v2_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid_v2/entry.zig"),
        .target = target,
        .optimize = optimize,
    });
    v2_test_module.addImport("prim", prim_mod);
    const v2_tests = b.addTest(.{ .root_module = v2_test_module });
    const v2_test_run = b.addRunArtifact(v2_tests);
    const v2_test_step = b.step("test-mermaid-v2", "Run mermaid_v2 unit tests");
    v2_test_step.dependOn(&v2_test_run.step);
    test_step.dependOn(&v2_test_run.step);

    // parse_baseline.zig — fixture sweep against the parser. Its own module
    // root so cross-directory @imports are not needed.
    const parse_baseline_module = b.createModule(.{
        .root_source_file = b.path("tests/parse_baseline.zig"),
        .target = target,
        .optimize = optimize,
    });
    parse_baseline_module.addImport("parser", parser_mod);
    parse_baseline_module.addImport("sem_graph", sem_graph_mod);

    const parse_baseline_tests = b.addTest(.{ .root_module = parse_baseline_module });
    const parse_baseline_run = b.addRunArtifact(parse_baseline_tests);
    const parse_baseline_step = b.step("test-baseline", "Run flowchart fixture parse baseline");
    parse_baseline_step.dependOn(&parse_baseline_run.step);
    test_step.dependOn(&parse_baseline_run.step);

    // layout_baseline.zig — week 3 R1 risk gate. Runs parse -> layout ->
    // validate on every fixture and asserts >=54/59 produce a Sketch
    // whose six validators all return .ok. Reaches the v2 surface via
    // the umbrella `mermaid_v2` module rooted at entry.zig — see the
    // entry.zig re-exports for the exposed API.
    const layout_baseline_module = b.createModule(.{
        .root_source_file = b.path("tests/layout_baseline.zig"),
        .target = target,
        .optimize = optimize,
    });
    layout_baseline_module.addImport("mermaid_v2", mermaid_v2_mod);

    const layout_baseline_tests = b.addTest(.{ .root_module = layout_baseline_module });
    const layout_baseline_run = b.addRunArtifact(layout_baseline_tests);
    const layout_baseline_step = b.step("test-layout-baseline", "Run layout fixture baseline (R1 gate)");
    layout_baseline_step.dependOn(&layout_baseline_run.step);
    test_step.dependOn(&layout_baseline_run.step);

    // lattice_baseline.zig — week 4 gate. Runs parse -> layout -> rasterize
    // on every fixture and asserts >=54/59 produce a Lattice that satisfies
    // structural invariants I1 (edge cells have >=2 neighbour bits) and I2
    // (node interiors don't leak through their border).
    const lattice_baseline_module = b.createModule(.{
        .root_source_file = b.path("tests/lattice_baseline.zig"),
        .target = target,
        .optimize = optimize,
    });
    lattice_baseline_module.addImport("mermaid_v2", mermaid_v2_mod);

    const lattice_baseline_tests = b.addTest(.{ .root_module = lattice_baseline_module });
    const lattice_baseline_run = b.addRunArtifact(lattice_baseline_tests);
    const lattice_baseline_step = b.step("test-lattice-baseline", "Run lattice fixture baseline (week 4 gate)");
    lattice_baseline_step.dependOn(&lattice_baseline_run.step);
    test_step.dependOn(&lattice_baseline_run.step);

    // paint_baseline.zig — week 5 gate. Runs the full v2 pipeline
    // (parse → layout → rasterize → paint) on every fixture and asserts
    // the painted output is non-empty, newline-terminated, and not a
    // fallback. Also requires >=10 fixtures to match their sibling .txt
    // exactly.
    const paint_baseline_module = b.createModule(.{
        .root_source_file = b.path("tests/paint_baseline.zig"),
        .target = target,
        .optimize = optimize,
    });
    paint_baseline_module.addImport("mermaid_v2", mermaid_v2_mod);

    const paint_baseline_tests = b.addTest(.{ .root_module = paint_baseline_module });
    const paint_baseline_run = b.addRunArtifact(paint_baseline_tests);
    const paint_baseline_step = b.step("test-paint-baseline", "Run paint fixture baseline (week 5 gate)");
    paint_baseline_step.dependOn(&paint_baseline_run.step);
    test_step.dependOn(&paint_baseline_run.step);

    // =====================================================
    // Import Boundary Lint (mermaid_v2)
    // =====================================================
    const lint_module = b.createModule(.{
        .root_source_file = b.path("tools/lint_imports.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lint_exe = b.addExecutable(.{
        .name = "lint-imports",
        .root_module = lint_module,
    });

    const lint_cmd = b.addRunArtifact(lint_exe);
    lint_cmd.setCwd(b.path("."));

    const lint_step = b.step("lint", "Run mermaid_v2 import boundary lint");
    lint_step.dependOn(&lint_cmd.step);
    test_step.dependOn(&lint_cmd.step);

    // =====================================================
    // Visual Samples Harness (mermaid_v2)
    // =====================================================
    const visual_samples_module = b.createModule(.{
        .root_source_file = b.path("tools/visual_samples.zig"),
        .target = target,
        .optimize = optimize,
    });
    visual_samples_module.addImport("mermaid_v2", mermaid_v2_mod);

    const visual_samples_exe = b.addExecutable(.{
        .name = "visual-samples",
        .root_module = visual_samples_module,
    });

    const visual_samples_cmd = b.addRunArtifact(visual_samples_exe);
    visual_samples_cmd.setCwd(b.path("."));
    visual_samples_cmd.expectExitCode(0);

    const visual_samples_step = b.step("visual-samples", "Render curated mermaid samples to docs/visual-samples.html");
    visual_samples_step.dependOn(&visual_samples_cmd.step);

    // =====================================================
    // Private eval scorer (out-of-tree `eval/`, gitignored)
    // =====================================================
    // Private maintainer evaluation tooling lives under the gitignored
    // top-level `eval/` directory so public clones build clean without it. Everything
    // below is wired ONLY when `eval/` exists on disk (an existence check, so a
    // clone lacking `eval/` still builds and `zig build test` still passes).
    //
    // The scorer reaches renderer internals (SemGraph, parse, mermaid types)
    // through exactly ONE facade module — `internals`, rooted at
    // `src/core/internals_api.zig`. It MUST be a single module so `sem_graph`
    // and `parse` compile once and share type identity; two separate modules
    // would compile two copies of `SemGraph` and break type identity.
    const has_eval = blk: {
        std.fs.cwd().access("eval", .{}) catch break :blk false;
        break :blk true;
    };

    if (has_eval) {
        const internals_mod = b.createModule(.{
            .root_source_file = b.path("src/core/internals_api.zig"),
            .target = target,
            .optimize = optimize,
        });
        internals_mod.addImport("prim", prim_mod);

        const reconstruction_mod = b.createModule(.{
            .root_source_file = b.path("eval/reconstruction_api.zig"),
            .target = target,
            .optimize = optimize,
        });
        reconstruction_mod.addImport("internals", internals_mod);

        // --- decoder-score tool ---
        const decoder_score_module = b.createModule(.{
            .root_source_file = b.path("eval/decoder_score.zig"),
            .target = target,
            .optimize = optimize,
        });
        decoder_score_module.addImport("reconstruction", reconstruction_mod);

        const decoder_score_exe = b.addExecutable(.{
            .name = "decoder-score",
            .root_module = decoder_score_module,
        });

        // Install the freshly built tool so `zig-out/bin/decoder-score` always
        // reflects current source and no stale binary lingers behind the named
        // run step.
        const decoder_score_install = b.addInstallArtifact(decoder_score_exe, .{});

        const decoder_score_cmd = b.addRunArtifact(decoder_score_exe);
        decoder_score_cmd.step.dependOn(&decoder_score_install.step);
        decoder_score_cmd.setCwd(b.path("."));
        if (b.args) |args| decoder_score_cmd.addArgs(args);

        const decoder_score_step = b.step("decoder-score", "Score one decoded/source mermaid pair");
        decoder_score_step.dependOn(&decoder_score_install.step);
        decoder_score_step.dependOn(&decoder_score_cmd.step);

        // --- eval test step (NOT folded into `zig build test`) ---
        // Reconstruction suite (matcher soundness, GED bounds, score records,
        // JSON, fixtures) rooted at the eval facade, plus the decoder-score
        // tool's own unit tests.
        const reconstruction_tests = b.addTest(.{ .root_module = reconstruction_mod });
        const reconstruction_test_run = b.addRunArtifact(reconstruction_tests);

        const decoder_score_tests = b.addTest(.{ .root_module = decoder_score_module });
        const decoder_score_test_run = b.addRunArtifact(decoder_score_tests);

        const test_eval_step = b.step("test-eval", "Run private eval scorer tests (reconstruction + decoder-score)");
        test_eval_step.dependOn(&reconstruction_test_run.step);
        test_eval_step.dependOn(&decoder_score_test_run.step);
    }
}

/// Wire the native-export font integration into a module that compiles
/// `src/export/font.zig`: the vendored stb_truetype
/// implementation translation unit, its include directory, libc, and the
/// embedded JetBrains Mono TTF asset. The module already carries the root's
/// optimize mode, satisfying "same optimization mode as the root artifact".
fn linkExportFont(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/stb"));
    module.addCSourceFile(.{
        .file = b.path("src/export/font_stb.c"),
        .flags = &.{"-std=c11"},
    });
    module.link_libc = true;
    module.addAnonymousImport("jetbrains_mono_ttf", .{
        .root_source_file = b.path("assets/fonts/JetBrainsMono-Regular.ttf"),
    });
}
