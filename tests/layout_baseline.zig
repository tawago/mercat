//! Week 3 gate (R1): every flowchart fixture produces a Sketch whose six
//! validators return .ok. Plan's abort threshold: >5/59 failures means the
//! Sketch IR is wrong and we redesign.
//!
//! Run via:  zig build test-layout-baseline
//!
//! On every run writes a TSV row per fixture to stderr:
//!   path \t parse_status \t layout_status \t validate_status \t violations
//!
//! Failing rows include the first 3 violation messages.

const std = @import("std");
const v2 = @import("mermaid_v2");

const FIXTURE_ROOT = "../mdv-internal-tests/test/fixtures/flowchart";

/// R1 abort threshold: >5/59 failures means the Sketch IR is wrong.
const min_pass: usize = 54;

const Tally = struct {
    parsed_and_validated: usize = 0,
    parse_failed: usize = 0,
    layout_failed: usize = 0,
    validate_failed: usize = 0,
    total: usize = 0,
    /// Tally of violations by Kind for the failure breakdown summary.
    violation_counts: [@typeInfo(v2.Violation.Kind).@"enum".fields.len]usize =
        [_]usize{0} ** @typeInfo(v2.Violation.Kind).@"enum".fields.len,
};

fn tallyViolation(tally: *Tally, kind: v2.Violation.Kind) void {
    tally.violation_counts[@intFromEnum(kind)] += 1;
}

fn runOneFixture(
    arena_alloc: std.mem.Allocator,
    cat_name: []const u8,
    file_name: []const u8,
    source: []const u8,
    tally: *Tally,
) void {
    // Step 1: parse.
    var graph = v2.parse(arena_alloc, source) catch |err| {
        std.debug.print(
            "[layout_baseline] {s}/{s}\tparse_err={s}\t-\t-\t-\n",
            .{ cat_name, file_name, @errorName(err) },
        );
        tally.parse_failed += 1;
        return;
    };
    // The SemGraph is arena-owned by parser; defer deinit to match ownership.
    defer graph.deinit(arena_alloc);

    // Step 2: layout. Catch errors AND panics-as-errors.
    const sketch = v2.layoutFlowchart(arena_alloc, graph, .{}) catch |err| {
        std.debug.print(
            "[layout_baseline] {s}/{s}\tok\tlayout_err={s}\t-\t-\n",
            .{ cat_name, file_name, @errorName(err) },
        );
        tally.layout_failed += 1;
        return;
    };

    // Step 3: validate.
    const result = v2.validateSketch(arena_alloc, sketch) catch |err| {
        // OOM in the validator itself is a hard test failure (caller asserts).
        std.debug.print(
            "[layout_baseline] {s}/{s}\tok\tok\tvalidate_err={s}\t-\n",
            .{ cat_name, file_name, @errorName(err) },
        );
        tally.validate_failed += 1;
        return;
    };

    switch (result) {
        .ok => {
            std.debug.print(
                "[layout_baseline] {s}/{s}\tok\tok\tok\t0\tnodes={d}\tedges={d}\n",
                .{ cat_name, file_name, sketch.nodes.len, sketch.edges.len },
            );
            tally.parsed_and_validated += 1;
        },
        .failed => |violations| {
            std.debug.print(
                "[layout_baseline] {s}/{s}\tok\tok\tFAILED\t{d}\n",
                .{ cat_name, file_name, violations.len },
            );
            var shown: usize = 0;
            for (violations) |viol| {
                tallyViolation(tally, viol.kind);
                if (shown < 3) {
                    std.debug.print(
                        "[layout_baseline]   - [{s}] {s}\n",
                        .{ @tagName(viol.kind), viol.message },
                    );
                    shown += 1;
                }
            }
            tally.validate_failed += 1;
        },
    }
}

fn printBreakdown(tally: Tally) void {
    std.debug.print("[layout_baseline] violation breakdown:\n", .{});
    const fields = @typeInfo(v2.Violation.Kind).@"enum".fields;
    inline for (fields, 0..) |f, i| {
        if (tally.violation_counts[i] > 0) {
            std.debug.print(
                "[layout_baseline]   {s}: {d}\n",
                .{ f.name, tally.violation_counts[i] },
            );
        }
    }
}

test "layout_baseline: every fixture produces a valid Sketch" {
    const alloc = std.testing.allocator;

    var root = std.fs.cwd().openDir(FIXTURE_ROOT, .{ .iterate = true }) catch |err| {
        std.debug.print(
            "[layout_baseline] skip: cannot open {s}: {s}\n",
            .{ FIXTURE_ROOT, @errorName(err) },
        );
        return;
    };
    defer root.close();

    var tally: Tally = .{};
    std.debug.print(
        "\n[layout_baseline] fixture\tparse\tlayout\tvalidate\tviolations\n",
        .{},
    );

    var cat_iter = root.iterate();
    while (try cat_iter.next()) |cat| {
        if (cat.kind != .directory) continue;
        var cat_dir = root.openDir(cat.name, .{ .iterate = true }) catch continue;
        defer cat_dir.close();

        var f_iter = cat_dir.iterate();
        while (try f_iter.next()) |f| {
            if (f.kind != .file) continue;
            if (!std.mem.endsWith(u8, f.name, ".mmd")) continue;
            tally.total += 1;

            // One arena per fixture: holds SemGraph + Sketch + violations.
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();

            const file = cat_dir.openFile(f.name, .{}) catch |err| {
                std.debug.print(
                    "[layout_baseline] {s}/{s}\topen_err={s}\t-\t-\t-\n",
                    .{ cat.name, f.name, @errorName(err) },
                );
                tally.parse_failed += 1;
                continue;
            };
            defer file.close();
            const source = file.readToEndAlloc(a, 1 << 20) catch |err| {
                std.debug.print(
                    "[layout_baseline] {s}/{s}\tread_err={s}\t-\t-\t-\n",
                    .{ cat.name, f.name, @errorName(err) },
                );
                tally.parse_failed += 1;
                continue;
            };

            runOneFixture(a, cat.name, f.name, source, &tally);
        }
    }

    std.debug.print(
        "[layout_baseline] passed {d}/{d} (threshold: {d}); parse_fail={d} layout_fail={d} validate_fail={d}\n",
        .{
            tally.parsed_and_validated,
            tally.total,
            min_pass,
            tally.parse_failed,
            tally.layout_failed,
            tally.validate_failed,
        },
    );
    printBreakdown(tally);

    if (tally.total == 0) return; // sibling missing — already skipped
    try std.testing.expect(tally.parsed_and_validated >= @min(min_pass, tally.total));
}
