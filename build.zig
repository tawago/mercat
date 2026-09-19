const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const unicode_check = b.addExecutable(.{
        .name = "unicode-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/unicode/check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const unicode_check_run = b.addRunArtifact(unicode_check);
    unicode_check_run.setCwd(b.path("."));
    const unicode_cache_dir = b.cache_root.join(b.allocator, &.{"unicode-17-generated"}) catch @panic("out of memory");
    unicode_check_run.addArg(unicode_cache_dir);
    const unicode_check_step = b.step("unicode-check", "Offline regenerate and byte-compare Unicode 17 tables");
    unicode_check_step.dependOn(&unicode_check_run.step);

    if (onlyStepRequested(b, "unicode-check")) return;

    const options = b.addOptions();
    const calibration_inputs = b.option([]const u8, "calibration-inputs", "Directory containing optional score-calibration inputs");
    options.addOption(?[]const u8, "calibration_inputs", calibration_inputs);
    const maybe_koino_dep = b.lazyDependency("koino", .{ .target = target, .optimize = optimize });
    const maybe_vaxis_dep = b.lazyDependency("vaxis", .{ .target = target, .optimize = optimize });
    if (maybe_koino_dep == null or maybe_vaxis_dep == null) return;
    const koino_dep = maybe_koino_dep.?;
    const vaxis_dep = maybe_vaxis_dep.?;
    options.addOption([]const u8, "version", "0.2.1");

    const text_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/text.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unicode_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/unicode.zig"),
        .target = target,
        .optimize = optimize,
    });

    const prim_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid_v2/base/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    prim_mod.addImport("unicode", unicode_mod);

    const mermaid_v2_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid_v2/entry.zig"),
        .target = target,
        .optimize = optimize,
    });
    mermaid_v2_mod.addImport("prim", prim_mod);
    mermaid_v2_mod.addImport("unicode", unicode_mod);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", options);
    root_module.addImport("koino", koino_dep.module("koino"));
    root_module.addImport("vaxis", vaxis_dep.module("vaxis"));
    root_module.addImport("prim", prim_mod);
    root_module.addImport("text", text_mod);
    root_module.addImport("unicode", unicode_mod);
    linkExportFont(b, root_module);

    const exe = b.addExecutable(.{
        .name = "mercat",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    options.addOption([]const u8, "mercat_exe_path", b.getInstallPath(.bin, "mercat"));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run mercat");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", options);
    test_module.addImport("koino", koino_dep.module("koino"));
    test_module.addImport("vaxis", vaxis_dep.module("vaxis"));
    test_module.addImport("prim", prim_mod);
    test_module.addImport("text", text_mod);
    test_module.addImport("unicode", unicode_mod);
    linkExportFont(b, test_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_run = b.addRunArtifact(unit_tests);
    test_run.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);

    const legacy_mermaid_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid/legacy_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    legacy_mermaid_test_module.addImport("prim", prim_mod);
    legacy_mermaid_test_module.addImport("text", text_mod);
    legacy_mermaid_test_module.addImport("unicode", unicode_mod);
    const legacy_mermaid_tests = b.addTest(.{ .root_module = legacy_mermaid_test_module });
    const legacy_mermaid_test_run = b.addRunArtifact(legacy_mermaid_tests);
    const legacy_mermaid_test_step = b.step("test-mermaid-legacy", "Run legacy Mermaid renderer tests");
    legacy_mermaid_test_step.dependOn(&legacy_mermaid_test_run.step);
    test_step.dependOn(&legacy_mermaid_test_run.step);

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

    test_step.dependOn(&prop_test_run.step);

    const v2_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid_v2/entry.zig"),
        .target = target,
        .optimize = optimize,
    });
    v2_test_module.addOptions("build_options", options);
    v2_test_module.addImport("prim", prim_mod);
    v2_test_module.addImport("unicode", unicode_mod);
    const v2_tests = b.addTest(.{ .root_module = v2_test_module });
    const v2_test_run = b.addRunArtifact(v2_tests);
    const v2_test_step = b.step("test-mermaid-v2", "Run mermaid_v2 unit tests");
    v2_test_step.dependOn(&v2_test_run.step);
    test_step.dependOn(&v2_test_run.step);

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

    const lint_test_module = b.createModule(.{
        .root_source_file = b.path("tools/lint_imports.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lint_tests = b.addTest(.{ .root_module = lint_test_module });
    const lint_tests_run = b.addRunArtifact(lint_tests);
    lint_tests_run.setCwd(b.path("."));
    test_step.dependOn(&lint_tests_run.step);

    const unicode_test_module = b.createModule(.{
        .root_source_file = b.path("src/lib/unicode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unicode_tests = b.addTest(.{ .root_module = unicode_test_module });
    const unicode_test_run = b.addRunArtifact(unicode_tests);
    unicode_test_run.setCwd(b.path("."));
    const unicode_test_step = b.step("test-unicode", "Run Unicode authority tests");
    unicode_test_step.dependOn(&unicode_test_run.step);
    test_step.dependOn(&unicode_test_run.step);

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
        internals_mod.addImport("text", text_mod);
        internals_mod.addImport("unicode", unicode_mod);

        const reconstruction_mod = b.createModule(.{
            .root_source_file = b.path("eval/reconstruction_api.zig"),
            .target = target,
            .optimize = optimize,
        });
        reconstruction_mod.addImport("internals", internals_mod);

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

        const decoder_score_install = b.addInstallArtifact(decoder_score_exe, .{});

        const decoder_score_cmd = b.addRunArtifact(decoder_score_exe);
        decoder_score_cmd.step.dependOn(&decoder_score_install.step);
        decoder_score_cmd.setCwd(b.path("."));
        if (b.args) |args| decoder_score_cmd.addArgs(args);

        const decoder_score_step = b.step("decoder-score", "Score one decoded/source mermaid pair");
        decoder_score_step.dependOn(&decoder_score_install.step);
        decoder_score_step.dependOn(&decoder_score_cmd.step);

        const reconstruction_tests = b.addTest(.{ .root_module = reconstruction_mod });
        const reconstruction_test_run = b.addRunArtifact(reconstruction_tests);

        const decoder_score_tests = b.addTest(.{ .root_module = decoder_score_module });
        const decoder_score_test_run = b.addRunArtifact(decoder_score_tests);

        const test_eval_step = b.step("test-eval", "Run private eval scorer tests (reconstruction + decoder-score)");
        test_eval_step.dependOn(&reconstruction_test_run.step);
        test_eval_step.dependOn(&decoder_score_test_run.step);

        const update_regressions = b.option(
            bool,
            "update-regressions",
            "Rewrite regression goldens (owner-approved changes only)",
        ) orelse false;
        const regression_dir = b.option(
            []const u8,
            "regression-dir",
            "Directory containing private byte-exact regression pins",
        );

        const regress_exe = b.addExecutable(.{
            .name = "regress",
            .root_module = b.createModule(.{
                .root_source_file = b.path("eval/regress.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        const regress_cmd = b.addRunArtifact(regress_exe);
        regress_cmd.step.dependOn(b.getInstallStep());
        regress_cmd.setCwd(b.path("."));
        regress_cmd.addArg(b.getInstallPath(.bin, "mercat"));
        if (regression_dir) |path| regress_cmd.addArg(path);
        if (update_regressions) regress_cmd.addArg("--update");

        const regress_step = b.step("regress", "Run byte-exact rendering regression pins");
        if (regression_dir != null) {
            regress_step.dependOn(&regress_cmd.step);
            test_step.dependOn(&regress_cmd.step);
        }
    }
}

fn onlyStepRequested(b: *std.Build, wanted: []const u8) bool {
    const args = std.process.argsAlloc(b.allocator) catch return false;
    if (args.len < 6) return false;

    var found: ?[]const u8 = null;
    var index: usize = 6;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) break;
        if (buildOptionTakesValue(arg)) {
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) continue;
        if (found != null) return false;
        found = arg;
    }
    return found != null and std.mem.eql(u8, found.?, wanted);
}

fn buildOptionTakesValue(arg: []const u8) bool {
    const options = [_][]const u8{
        "-p",                   "--prefix",    "--prefix-lib-dir", "--prefix-exe-dir",
        "--prefix-include-dir", "--sysroot",   "--maxrss",         "--search-prefix",
        "--libc",               "--color",     "--summary",        "--seed",
        "--debounce",           "--debug-log", "--libc-runtimes",  "--glibc-runtimes",
    };
    for (options) |option| if (std.mem.eql(u8, arg, option)) return true;
    return false;
}

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
