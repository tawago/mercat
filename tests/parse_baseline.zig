//! Week 2 gate: every internal flowchart fixture parses without error.
//!
//! Walks `../mdv-internal-tests/test/fixtures/flowchart/**/*.mmd` (relative
//! to the repo root, which is the cwd when `zig build test` runs) and
//! invokes the mermaid_v2 parser on each. The test passes when at least
//! `min_pass` fixtures parse without error; the threshold is the rolling
//! contract for week-2 maturity and bumps up in later weeks (target 59/59
//! by week 7).
//!
//! On every run the test writes a tab-separated audit row per fixture to
//! stderr (path, node count, edge count, cluster count, status). Humans
//! diff this against past runs to catch silent regressions in node/edge
//! counts that don't manifest as parse errors.

const std = @import("std");
const parser = @import("parser");

const FIXTURE_ROOT = "../mdv-internal-tests/test/fixtures/flowchart";

/// Rolling pass-count floor. Bump as parser maturity grows.
///   week 2: 59 — full coverage achieved early; lock in the win.
const min_pass: usize = 59;

const Tally = struct {
    parsed: usize = 0,
    failed: usize = 0,
    total: usize = 0,
};

test "parse_baseline: all flowchart fixtures parse" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var root = std.fs.cwd().openDir(FIXTURE_ROOT, .{ .iterate = true }) catch |err| {
        std.debug.print("[baseline] skip: cannot open {s}: {s}\n", .{ FIXTURE_ROOT, @errorName(err) });
        return; // Internal-tests sibling not present; week-2 gate is best-effort.
    };
    defer root.close();

    var tally: Tally = .{};
    std.debug.print("\n[baseline] fixture\tnodes\tedges\tclusters\tstatus\n", .{});

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

            const file = try cat_dir.openFile(f.name, .{});
            defer file.close();
            const source = try file.readToEndAlloc(a, 1 << 20);

            const result = parser.parse(a, source);
            if (result) |graph_const| {
                var graph = graph_const;
                defer graph.deinit(a);
                std.debug.print("[baseline] {s}/{s}\t{d}\t{d}\t{d}\tok\n", .{
                    cat.name, f.name, graph.nodes.len, graph.edges.len, graph.clusters.len,
                });
                tally.parsed += 1;
            } else |err| {
                std.debug.print("[baseline] {s}/{s}\t-\t-\t-\t{s}\n", .{
                    cat.name, f.name, @errorName(err),
                });
                tally.failed += 1;
            }
        }
    }

    std.debug.print("[baseline] parsed {d}/{d} (threshold: {d})\n", .{ tally.parsed, tally.total, min_pass });
    if (tally.total == 0) return; // sibling missing — already skipped above
    try std.testing.expect(tally.parsed >= @min(min_pass, tally.total));
}
