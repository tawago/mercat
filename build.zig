const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    const internal_tests_dir = b.option([]const u8, "internal-tests-dir", "Path to the internal test checkout");
    const koino_dep = b.dependency("koino", .{ .target = target, .optimize = optimize });
    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    options.addOption([]const u8, "version", "0.1.2");
    const has_internal_tests = blk: {
        std.fs.cwd().access(pathString(b, internal_tests_dir, "src/test/snapshot.zig"), .{}) catch break :blk false;
        std.fs.cwd().access(pathString(b, internal_tests_dir, "src/test/mermaid_cases.zig"), .{}) catch break :blk false;
        std.fs.cwd().access(pathString(b, internal_tests_dir, "test/snapshot_test.zig"), .{}) catch break :blk false;
        std.fs.cwd().access(pathString(b, internal_tests_dir, "src/tools/update_snapshots.zig"), .{}) catch break :blk false;
        std.fs.cwd().access(pathString(b, internal_tests_dir, "src/tools/find_thresholds.zig"), .{}) catch break :blk false;
        break :blk true;
    };
    const internal_root = buildPath(b, internal_tests_dir, ".");

    // =====================================================
    // Shared Modules (for reuse across targets)
    // =====================================================
    const mermaid_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mermaid/render.zig"),
        .target = target,
        .optimize = optimize,
    });

    const snapshot_mod = if (has_internal_tests)
        b.createModule(.{
            .root_source_file = buildPath(b, internal_tests_dir, "src/test/snapshot.zig"),
            .target = target,
            .optimize = optimize,
        })
    else
        null;

    const mermaid_cases_mod = if (has_internal_tests)
        b.createModule(.{
            .root_source_file = buildPath(b, internal_tests_dir, "src/test/mermaid_cases.zig"),
            .target = target,
            .optimize = optimize,
        })
    else
        null;

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

    const exe = b.addExecutable(.{
        .name = "mdv",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run mdv");
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

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_run = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);

    // =====================================================
    // Snapshot Tests
    // =====================================================
    if (has_internal_tests) {
        const snapshot_test_module = b.createModule(.{
            .root_source_file = buildPath(b, internal_tests_dir, "test/snapshot_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        snapshot_test_module.addImport("mermaid", mermaid_mod);
        snapshot_test_module.addImport("snapshot", snapshot_mod.?);
        snapshot_test_module.addImport("mermaid_cases", mermaid_cases_mod.?);

        const snapshot_tests = b.addTest(.{
            .root_module = snapshot_test_module,
        });

        const snapshot_test_run = b.addRunArtifact(snapshot_tests);
        snapshot_test_run.setCwd(internal_root);
        const snapshot_step = b.step("test-snapshot", "Run internal snapshot tests");
        snapshot_step.dependOn(&snapshot_test_run.step);

        // =====================================================
        // Update Snapshots Tool
        // =====================================================
        const update_module = b.createModule(.{
            .root_source_file = buildPath(b, internal_tests_dir, "src/tools/update_snapshots.zig"),
            .target = target,
            .optimize = optimize,
        });
        update_module.addImport("mermaid", mermaid_mod);
        update_module.addImport("snapshot", snapshot_mod.?);
        update_module.addImport("mermaid_cases", mermaid_cases_mod.?);

        const update_exe = b.addExecutable(.{
            .name = "update_snapshots",
            .root_module = update_module,
        });
        b.installArtifact(update_exe);

        const update_cmd = b.addRunArtifact(update_exe);
        update_cmd.step.dependOn(b.getInstallStep());
        update_cmd.setCwd(internal_root);

        const update_step = b.step("update-snapshot", "Regenerate internal golden files");
        update_step.dependOn(&update_cmd.step);

        // =====================================================
        // Find Thresholds Tool
        // =====================================================
        const threshold_module = b.createModule(.{
            .root_source_file = buildPath(b, internal_tests_dir, "src/tools/find_thresholds.zig"),
            .target = target,
            .optimize = optimize,
        });
        threshold_module.addImport("mermaid", mermaid_mod);
        threshold_module.addImport("mermaid_cases", mermaid_cases_mod.?);

        const threshold_exe = b.addExecutable(.{
            .name = "find_thresholds",
            .root_module = threshold_module,
        });
        b.installArtifact(threshold_exe);

        const threshold_cmd = b.addRunArtifact(threshold_exe);
        threshold_cmd.step.dependOn(b.getInstallStep());
        threshold_cmd.setCwd(internal_root);

        const threshold_step = b.step("find-thresholds", "Find width thresholds for diagrams");
        threshold_step.dependOn(&threshold_cmd.step);

        // =====================================================
        // Combined Test Step
        // =====================================================
        const test_all_step = b.step("test-all", "Run unit and internal snapshot tests");
        test_all_step.dependOn(&test_run.step);
        test_all_step.dependOn(&snapshot_test_run.step);
    } else {
        const test_all_step = b.step("test-all", "Run public unit tests");
        test_all_step.dependOn(&test_run.step);
    }
}

fn pathString(b: *std.Build, base: ?[]const u8, suffix: []const u8) []const u8 {
    if (base) |dir| return b.fmt("{s}/{s}", .{ dir, suffix });
    return suffix;
}

fn buildPath(b: *std.Build, base: ?[]const u8, suffix: []const u8) std.Build.LazyPath {
    if (base) |dir| return .{ .cwd_relative = b.fmt("{s}/{s}", .{ dir, suffix }) };
    return b.path(suffix);
}
