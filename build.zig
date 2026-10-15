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
    _ = unicode_check_run.addOutputDirectoryArg("unicode-17-generated");
    const unicode_check_step = b.step("unicode-check", "Offline regenerate and byte-compare Unicode 17 tables");
    unicode_check_step.dependOn(&unicode_check_run.step);

    const options = b.addOptions();
    const maybe_koino_dep = b.lazyDependency("koino", .{ .target = target, .optimize = optimize });
    const maybe_vaxis_dep = b.lazyDependency("vaxis", .{ .target = target, .optimize = optimize, .external_uucode = true });
    // koino and vaxis share one uucode instance; Zig rejects one source file in two modules.
    const maybe_uucode_dep = b.lazyDependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "east_asian_width",
            "grapheme_break",
            "general_category",
            "is_emoji_presentation",
            "simple_lowercase_mapping",
        }),
    });
    if (maybe_koino_dep == null or maybe_vaxis_dep == null or maybe_uucode_dep == null) return;
    const koino_dep = maybe_koino_dep.?;
    const vaxis_dep = maybe_vaxis_dep.?;
    const uucode_mod = maybe_uucode_dep.?.module("uucode");
    koino_dep.module("koino").addImport("uucode", uucode_mod);
    // PCRE's recursive matcher overflows the stack on long documents; koino's
    // build does not set NO_RECURSE, so set it on its pcre library here.
    (findLibrary(koino_dep.module("koino"), "pcre") orelse @panic("koino: no pcre library")).root_module.addCMacro("NO_RECURSE", "1");
    vaxis_dep.module("vaxis").addImport("uucode", uucode_mod);
    options.addOption([]const u8, "version", "0.3.2");

    const stb_translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/stb/stb_truetype.h"),
        .target = target,
        .optimize = optimize,
    });
    const stb_mod = stb_translate.createModule();

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
        .root_source_file = b.path("src/core/mermaid/flowchart/base/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    prim_mod.addImport("unicode", unicode_mod);

    const flowchart_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid/flowchart/entry.zig"),
        .target = target,
        .optimize = optimize,
    });
    flowchart_mod.addImport("prim", prim_mod);
    flowchart_mod.addImport("unicode", unicode_mod);

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
    linkExportFont(b, root_module, stb_mod);

    const exe = b.addExecutable(.{
        .name = "mercat",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const exe_options = b.addOptions();
    exe_options.addOptionPath("mercat_exe_path", exe.getEmittedBin());

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run mercat");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", options);
    test_module.addOptions("exe_options", exe_options);
    test_module.addImport("koino", koino_dep.module("koino"));
    test_module.addImport("vaxis", vaxis_dep.module("vaxis"));
    test_module.addImport("prim", prim_mod);
    test_module.addImport("text", text_mod);
    test_module.addImport("unicode", unicode_mod);
    linkExportFont(b, test_module, stb_mod);
    test_module.addAnonymousImport("kitchen_sink_md", .{
        .root_source_file = b.path("tests/fixtures/kitchen-sink.md"),
    });
    // The TUI key-table test checks that README.md documents every binding.
    test_module.addAnonymousImport("readme_md", .{
        .root_source_file = b.path("README.md"),
    });

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_run = b.addRunArtifact(unit_tests);
    test_run.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);

    // Opt-in: the markdown fuzz properties over their full fixed-seed corpus
    // (2500 iterations each, not the default run's few hundred).
    const fuzz_long_tests = b.addTest(.{ .root_module = test_module, .filters = &.{"property:"} });
    const fuzz_long_run = b.addRunArtifact(fuzz_long_tests);
    fuzz_long_run.setEnvironmentVariable("MERCAT_LONG_FUZZ", "1");
    const fuzz_long_step = b.step("test-fuzz-long", "Run the markdown fuzz properties at full length (not part of test)");
    fuzz_long_step.dependOn(&fuzz_long_run.step);

    // CLI contract tests: run the installed binary and check messages and exit codes.
    const cli_test_run = b.addSystemCommand(&.{ "bash", "tests/cli/run.sh" });
    cli_test_run.setCwd(b.path("."));
    cli_test_run.addArtifactArg(exe);
    cli_test_run.expectExitCode(0);
    cli_test_run.has_side_effects = true;
    const cli_test_step = b.step("test-cli", "Run CLI message/exit-code tests against the built binary");
    cli_test_step.dependOn(&cli_test_run.step);
    test_step.dependOn(&cli_test_run.step);

    const font_test_module = b.createModule(.{
        .root_source_file = b.path("src/export/font.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkExportFont(b, font_test_module, stb_mod);

    const font_tests = b.addTest(.{ .root_module = font_test_module });
    const font_test_run = b.addRunArtifact(font_tests);
    const font_test_step = b.step("test-export-font", "Run export font-service tests");
    font_test_step.dependOn(&font_test_run.step);
    test_step.dependOn(&font_test_run.step);

    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid/check.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_mod.addImport("unicode", unicode_mod);

    const mermaid_props_module = b.createModule(.{
        .root_source_file = b.path("tests/mermaid/all_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    mermaid_props_module.addImport("check", check_mod);
    mermaid_props_module.addImport("flowchart", flowchart_mod);
    const mermaid_props = b.addTest(.{ .root_module = mermaid_props_module });
    const mermaid_props_run = b.addRunArtifact(mermaid_props);
    const mermaid_props_step = b.step("test-mermaid-props", "Run readback and property tests on generated flowcharts");
    mermaid_props_step.dependOn(&mermaid_props_run.step);
    test_step.dependOn(&mermaid_props_run.step);

    const flowchart_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid/flowchart/entry.zig"),
        .target = target,
        .optimize = optimize,
    });
    flowchart_test_module.addImport("prim", prim_mod);
    flowchart_test_module.addImport("unicode", unicode_mod);
    const flowchart_tests = b.addTest(.{ .root_module = flowchart_test_module });
    const flowchart_test_run = b.addRunArtifact(flowchart_tests);
    const flowchart_test_step = b.step("test-flowchart", "Run flowchart engine unit tests");
    flowchart_test_step.dependOn(&flowchart_test_run.step);
    test_step.dependOn(&flowchart_test_run.step);

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

    const lint_step = b.step("lint", "Run flowchart engine import boundary lint");
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
    visual_samples_module.addImport("flowchart", flowchart_mod);

    const visual_samples_exe = b.addExecutable(.{
        .name = "visual-samples",
        .root_module = visual_samples_module,
    });

    const visual_samples_cmd = b.addRunArtifact(visual_samples_exe);
    visual_samples_cmd.setCwd(b.path("."));
    visual_samples_cmd.expectExitCode(0);

    const visual_samples_step = b.step("visual-samples", "Render curated mermaid samples to docs/visual-samples.html");
    visual_samples_step.dependOn(&visual_samples_cmd.step);

    b.dependOnFileMetadata(b.path("eval/regress.zig"));
    const has_eval = blk: {
        std.Io.Dir.cwd().access(b.graph.io, "eval/regress.zig", .{}) catch break :blk false;
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
        decoder_score_cmd.addPassthruArgs();

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
        regress_cmd.addArtifactArg(exe);
        if (regression_dir) |path| regress_cmd.addArg(path);
        if (update_regressions) regress_cmd.addArg("--update");

        const regress_step = b.step("regress", "Run byte-exact rendering regression pins");
        if (regression_dir != null) {
            regress_step.dependOn(&regress_cmd.step);
            test_step.dependOn(&regress_cmd.step);
        }
    }
}

fn findLibrary(module: *std.Build.Module, name: []const u8) ?*std.Build.Step.Compile {
    for (module.link_objects.items) |object| switch (object) {
        .other_step => |compile| if (std.mem.eql(u8, compile.name, name)) return compile,
        else => {},
    };
    for (module.import_table.values()) |imported| {
        if (findLibrary(imported, name)) |found| return found;
    }
    return null;
}

fn linkExportFont(b: *std.Build, module: *std.Build.Module, stb_mod: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/stb"));
    module.addCSourceFile(.{
        .file = b.path("src/export/font_stb.c"),
        .flags = &.{"-std=c11"},
    });
    module.link_libc = true;
    module.addImport("stb_truetype", stb_mod);
    module.addAnonymousImport("jetbrains_mono_ttf", .{
        .root_source_file = b.path("assets/fonts/JetBrainsMono-Regular.ttf"),
    });
}
