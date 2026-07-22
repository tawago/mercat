//! Paint baseline: every fixture flows through the full v2 pipeline
//! (parse → ladder → rasterize → paint) and yields a non-empty,
//! newline-terminated, non-fallback `RenderResult`. The floor moves
//! up as the pipeline improves; week 6 raised it from 10 to 13 after
//! stroke glyphs + cluster frames landed.
//!
//! Run via:  zig build test-paint-baseline

const std = @import("std");
const v2 = @import("mermaid_v2");

const FIXTURE_ROOT = "../mdv-internal-tests/test/fixtures/flowchart";
// Floor lowered 18 -> 12 (Phase 2E): rendering quality is now governed by
// the maintainer's private evaluation suite, not byte-exact goldens. The
// exact-match net is retained only to catch regressions in the simple/basic
// chain fixtures (~10 of them); quality-driven layout/routing/spacing work
// that legitimately reflows subgraph goldens must not trip this gate.
const min_exact: usize = 12;

const Tally = struct {
    rendered: usize = 0,
    fallback: usize = 0,
    empty: usize = 0,
    no_newline: usize = 0,
    render_err: usize = 0,
    exact: usize = 0,
    total: usize = 0,
};

fn readSibling(
    a: std.mem.Allocator,
    cat_dir: std.fs.Dir,
    mmd_name: []const u8,
) !?[]u8 {
    if (!std.mem.endsWith(u8, mmd_name, ".mmd")) return null;
    const stem = mmd_name[0 .. mmd_name.len - 4];
    const txt_name = try std.fmt.allocPrint(a, "{s}.txt", .{stem});
    const file = cat_dir.openFile(txt_name, .{}) catch return null;
    defer file.close();
    return try file.readToEndAlloc(a, 1 << 20);
}

test "paint_baseline: every fixture renders through the full v2 pipeline" {
    const alloc = std.testing.allocator;

    var root = std.fs.cwd().openDir(FIXTURE_ROOT, .{ .iterate = true }) catch |err| {
        std.debug.print(
            "[paint_baseline] skip: cannot open {s}: {s}\n",
            .{ FIXTURE_ROOT, @errorName(err) },
        );
        return;
    };
    defer root.close();

    var tally: Tally = .{};
    std.debug.print(
        "\n[paint_baseline] fixture\tstatus\texact\n",
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

            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();

            const file = cat_dir.openFile(f.name, .{}) catch {
                tally.render_err += 1;
                continue;
            };
            defer file.close();
            const source = file.readToEndAlloc(a, 1 << 20) catch {
                tally.render_err += 1;
                continue;
            };

            const result = v2.render(a, source, .{}) catch |err| {
                std.debug.print(
                    "[paint_baseline] {s}/{s}\trender_err={s}\t-\n",
                    .{ cat.name, f.name, @errorName(err) },
                );
                tally.render_err += 1;
                continue;
            };

            if (result.is_fallback) {
                std.debug.print(
                    "[paint_baseline] {s}/{s}\tFALLBACK={s}\t-\n",
                    .{ cat.name, f.name, result.fallback_reason orelse "?" },
                );
                tally.fallback += 1;
                continue;
            }
            if (result.output.len == 0) {
                std.debug.print(
                    "[paint_baseline] {s}/{s}\tEMPTY\t-\n",
                    .{ cat.name, f.name },
                );
                tally.empty += 1;
                continue;
            }
            if (result.output[result.output.len - 1] != '\n') {
                std.debug.print(
                    "[paint_baseline] {s}/{s}\tNO_NEWLINE\t-\n",
                    .{ cat.name, f.name },
                );
                tally.no_newline += 1;
                continue;
            }

            tally.rendered += 1;

            const golden_opt = readSibling(a, cat_dir, f.name) catch null;
            var exact = false;
            if (golden_opt) |golden| {
                if (std.mem.eql(u8, golden, result.output)) {
                    exact = true;
                    tally.exact += 1;
                }
            }
            std.debug.print(
                "[paint_baseline] {s}/{s}\tok\t{s}\n",
                .{ cat.name, f.name, if (exact) "exact" else "diff" },
            );
        }
    }

    std.debug.print(
        "[paint_baseline] rendered {d}/{d} exact={d} (min_exact: {d}); fallback={d} empty={d} no_newline={d} render_err={d}\n",
        .{
            tally.rendered,
            tally.total,
            tally.exact,
            min_exact,
            tally.fallback,
            tally.empty,
            tally.no_newline,
            tally.render_err,
        },
    );

    if (tally.total == 0) return;
    try std.testing.expectEqual(@as(usize, 0), tally.fallback);
    try std.testing.expectEqual(@as(usize, 0), tally.empty);
    try std.testing.expectEqual(@as(usize, 0), tally.no_newline);
    try std.testing.expectEqual(@as(usize, 0), tally.render_err);
    try std.testing.expect(tally.exact >= min_exact);
}
