//! Week 4 gate: every fixture rasterizes into a Lattice that satisfies
//! two structural invariants.
//!
//!   I1. Every `edge_segment` (or `arrowhead`) cell has
//!       popcount(neighbours) >= 2. (An edge cell with fewer than two
//!       set neighbour bits would be a dangling pixel — bug in the
//!       edge rasterizer's neighbour-bit accounting.)
//!
//!   I2. For every node referenced by `node_interior` cells, the union
//!       of that node's interior cells is reachable via 4-connected
//!       steps without ever leaving the set of cells whose occupant is
//!       either `node_interior(node)`, `node_border(node)`, or a
//!       `label_char` cell sitting on what would be that node's
//!       interior. Concretely: starting from each interior seed,
//!       flood-fill horizontally and vertically — every reached cell
//!       must satisfy the predicate. Failure means the border has a
//!       gap and the node would "leak".
//!
//! min_pass: 54 — same threshold as R1 (parse + layout + validate).
//! Failures here surface bugs in the rasterizers — they should NOT be
//! fixed here; record them in the report.
//!
//! Run via:  zig build test-lattice-baseline

const std = @import("std");
const v2 = @import("mermaid_v2");

const FIXTURE_ROOT = "../mdv-internal-tests/test/fixtures/flowchart";
const min_pass: usize = 54;

const Tally = struct {
    passed: usize = 0,
    parse_fail: usize = 0,
    layout_fail: usize = 0,
    raster_fail: usize = 0,
    i1_fail: usize = 0,
    i2_fail: usize = 0,
    total: usize = 0,
};

fn popcount4(n: v2.Neighbours) u32 {
    return @popCount(n.toMask());
}

/// Returns null if invariant I1 holds; otherwise a short reason string
/// (owned by `allocator`).
fn checkI1(
    allocator: std.mem.Allocator,
    lat: v2.Lattice,
) !?[]const u8 {
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const c = lat.atConst(x, y).*;
            const is_edge = switch (c.occupant) {
                .edge_segment, .arrowhead => true,
                else => false,
            };
            if (!is_edge) continue;
            const pop = popcount4(c.neighbours);
            if (pop < 2) {
                return try std.fmt.allocPrint(
                    allocator,
                    "edge cell at ({d},{d}) has popcount={d}",
                    .{ x, y, pop },
                );
            }
        }
    }
    return null;
}

const NodeIdU = u32;

/// 4-connected flood: starting from each `node_interior(node)` cell,
/// BFS through interior + same-node-border + label_char cells. If a
/// step ever encounters an `empty`, foreign-node, edge, or cluster cell
/// reachable from interior via interior-only adjacency, the border has
/// a leak.
fn checkI2(allocator: std.mem.Allocator, lat: v2.Lattice) !?[]const u8 {
    // Visited bitmap, one byte per cell.
    const total: usize = @as(usize, lat.width) * @as(usize, lat.height);
    if (total == 0) return null;
    const visited = try allocator.alloc(u8, total);
    defer allocator.free(visited);
    @memset(visited, 0);

    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const idx = @as(usize, y) * @as(usize, lat.width) + @as(usize, x);
            if (visited[idx] != 0) continue;
            const c = lat.atConst(x, y).*;
            const node_id: NodeIdU = switch (c.occupant) {
                .node_interior => |n| n,
                else => continue,
            };

            // BFS from this seed.
            var queue: std.ArrayList(u32) = .empty;
            defer queue.deinit(allocator);
            try queue.append(allocator, x);
            try queue.append(allocator, y);
            visited[idx] = 1;

            while (queue.items.len > 0) {
                // Pop one (x,y) pair from the end.
                const cy = queue.items[queue.items.len - 1];
                const cx = queue.items[queue.items.len - 2];
                queue.items.len -= 2;

                // Try 4 neighbours.
                const steps = [_][2]i32{
                    .{ -1, 0 },
                    .{ 1, 0 },
                    .{ 0, -1 },
                    .{ 0, 1 },
                };
                for (steps) |st| {
                    const nx_i: i32 = @as(i32, @intCast(cx)) + st[0];
                    const ny_i: i32 = @as(i32, @intCast(cy)) + st[1];
                    if (nx_i < 0 or ny_i < 0) continue;
                    if (nx_i >= @as(i32, @intCast(lat.width))) continue;
                    if (ny_i >= @as(i32, @intCast(lat.height))) continue;
                    const nx: u32 = @intCast(nx_i);
                    const ny: u32 = @intCast(ny_i);
                    const nidx = @as(usize, ny) * @as(usize, lat.width) + @as(usize, nx);
                    if (visited[nidx] != 0) continue;
                    const nc = lat.atConst(nx, ny).*;
                    switch (nc.occupant) {
                        .node_interior => |nn| {
                            if (nn != node_id) {
                                return try std.fmt.allocPrint(
                                    allocator,
                                    "leak: interior of node {d} at ({d},{d}) touches interior of node {d} at ({d},{d})",
                                    .{ node_id, cx, cy, nn, nx, ny },
                                );
                            }
                            visited[nidx] = 1;
                            try queue.append(allocator, nx);
                            try queue.append(allocator, ny);
                        },
                        .node_border => |b| {
                            if (b.node != node_id) {
                                return try std.fmt.allocPrint(
                                    allocator,
                                    "leak: interior of node {d} at ({d},{d}) touches border of node {d} at ({d},{d})",
                                    .{ node_id, cx, cy, b.node, nx, ny },
                                );
                            }
                            // Same-node border: stop flood here (don't enqueue).
                            visited[nidx] = 1;
                        },
                        .label_char => {
                            // Labels live inside node interiors; treat as
                            // interior for flood purposes.
                            visited[nidx] = 1;
                            try queue.append(allocator, nx);
                            try queue.append(allocator, ny);
                        },
                        .empty, .edge_segment, .arrowhead, .cluster_border => {
                            return try std.fmt.allocPrint(
                                allocator,
                                "leak: interior of node {d} at ({d},{d}) reaches non-border cell at ({d},{d}) [{s}]",
                                .{ node_id, cx, cy, nx, ny, @tagName(nc.occupant) },
                            );
                        },
                    }
                }
            }
        }
    }
    return null;
}

fn runOneFixture(
    arena_alloc: std.mem.Allocator,
    cat_name: []const u8,
    file_name: []const u8,
    source: []const u8,
    tally: *Tally,
) void {
    var graph = v2.parse(arena_alloc, source) catch |err| {
        std.debug.print(
            "[lattice_baseline] {s}/{s}\tparse_err={s}\t-\t-\t-\t-\n",
            .{ cat_name, file_name, @errorName(err) },
        );
        tally.parse_fail += 1;
        return;
    };
    defer graph.deinit(arena_alloc);

    const sketch = v2.layoutFlowchart(arena_alloc, graph, .{}) catch |err| {
        std.debug.print(
            "[lattice_baseline] {s}/{s}\tok\tlayout_err={s}\t-\t-\t-\n",
            .{ cat_name, file_name, @errorName(err) },
        );
        tally.layout_fail += 1;
        return;
    };

    const report = v2.rasterize(arena_alloc, sketch, .bridge) catch |err| {
        std.debug.print(
            "[lattice_baseline] {s}/{s}\tok\tok\traster_err={s}\t-\t-\n",
            .{ cat_name, file_name, @errorName(err) },
        );
        tally.raster_fail += 1;
        return;
    };

    const i1_reason = checkI1(arena_alloc, report.lattice) catch |err| {
        std.debug.print(
            "[lattice_baseline] {s}/{s}\tok\tok\tok\tI1_err={s}\t-\n",
            .{ cat_name, file_name, @errorName(err) },
        );
        tally.i1_fail += 1;
        return;
    };
    if (i1_reason) |r| {
        std.debug.print(
            "[lattice_baseline] {s}/{s}\tok\tok\tok\tI1_FAIL\t-\n",
            .{ cat_name, file_name },
        );
        std.debug.print("[lattice_baseline]   - {s}\n", .{r});
        tally.i1_fail += 1;
        return;
    }

    const i2_reason = checkI2(arena_alloc, report.lattice) catch |err| {
        std.debug.print(
            "[lattice_baseline] {s}/{s}\tok\tok\tok\tok\tI2_err={s}\n",
            .{ cat_name, file_name, @errorName(err) },
        );
        tally.i2_fail += 1;
        return;
    };
    if (i2_reason) |r| {
        std.debug.print(
            "[lattice_baseline] {s}/{s}\tok\tok\tok\tok\tI2_FAIL\n",
            .{ cat_name, file_name },
        );
        std.debug.print("[lattice_baseline]   - {s}\n", .{r});
        tally.i2_fail += 1;
        return;
    }

    std.debug.print(
        "[lattice_baseline] {s}/{s}\tok\tok\tok\tok\tok\tw={d} h={d} n={d} e={d} c={d} L={d}\n",
        .{
            cat_name,
            file_name,
            report.lattice.width,
            report.lattice.height,
            report.nodes_written,
            report.edges_written,
            report.clusters_written,
            report.labels_placed,
        },
    );
    tally.passed += 1;
}

test "lattice_baseline: every fixture rasterizes into a valid Lattice" {
    const alloc = std.testing.allocator;

    var root = std.fs.cwd().openDir(FIXTURE_ROOT, .{ .iterate = true }) catch |err| {
        std.debug.print(
            "[lattice_baseline] skip: cannot open {s}: {s}\n",
            .{ FIXTURE_ROOT, @errorName(err) },
        );
        return;
    };
    defer root.close();

    var tally: Tally = .{};
    std.debug.print(
        "\n[lattice_baseline] fixture\tparse\tlayout\traster\tI1\tI2\n",
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

            const file = cat_dir.openFile(f.name, .{}) catch |err| {
                std.debug.print(
                    "[lattice_baseline] {s}/{s}\topen_err={s}\t-\t-\t-\t-\n",
                    .{ cat.name, f.name, @errorName(err) },
                );
                tally.parse_fail += 1;
                continue;
            };
            defer file.close();
            const source = file.readToEndAlloc(a, 1 << 20) catch |err| {
                std.debug.print(
                    "[lattice_baseline] {s}/{s}\tread_err={s}\t-\t-\t-\t-\n",
                    .{ cat.name, f.name, @errorName(err) },
                );
                tally.parse_fail += 1;
                continue;
            };

            runOneFixture(a, cat.name, f.name, source, &tally);
        }
    }

    std.debug.print(
        "[lattice_baseline] passed {d}/{d} (threshold: {d}); parse_fail={d} layout_fail={d} raster_fail={d} I1_fail={d} I2_fail={d}\n",
        .{
            tally.passed,
            tally.total,
            min_pass,
            tally.parse_fail,
            tally.layout_fail,
            tally.raster_fail,
            tally.i1_fail,
            tally.i2_fail,
        },
    );

    if (tally.total == 0) return;
    try std.testing.expect(tally.passed >= @min(min_pass, tally.total));
}
