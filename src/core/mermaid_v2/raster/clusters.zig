//! Cluster border rasterizer.
//!
//! Walks each `ClusterFrame.rect` and writes perimeter cells into the
//! Lattice as `Occupant.cluster_border` with `BorderRole`/`Neighbours`
//! bits; interiors stay `.empty`. Rasterized depth-ascending so inner
//! cluster borders overwrite coincident outer borders.
//!
//! Imports: only `std`, `../sketch.zig`, `../lattice.zig` (lint-enforced).

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");

pub const RasterError = error{ OutOfMemory, OutOfBounds };

const log = std.log.scoped(.mermaid_v2_raster_clusters);

/// Rasterize every ClusterFrame in `s` into `lat` as cluster_border
/// cells along the perimeter of each cluster's rect. Returns the number
/// of cluster frames successfully rasterized (frames clipped for OOB are
/// not counted).
pub fn rasterizeClusters(
    allocator: std.mem.Allocator,
    lat: *lattice.Lattice,
    s: sketch.Sketch,
) RasterError!u32 {
    if (s.clusters.len == 0) return 0;

    // Copy cluster indices into a sortable buffer so we can sort by
    // depth ascending without mutating the borrowed slice.
    const order = try allocator.alloc(u32, s.clusters.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = @intCast(i);

    const Ctx = struct {
        frames: []const sketch.ClusterFrame,
        fn lessThan(self: @This(), a: u32, b: u32) bool {
            return self.frames[a].depth < self.frames[b].depth;
        }
    };
    std.mem.sort(u32, order, Ctx{ .frames = s.clusters }, Ctx.lessThan);

    var written: u32 = 0;
    for (order) |idx| {
        const frame = s.clusters[idx];
        // Synthetic packing frames are invisible by design (zero pad at stitch), regardless of the rect they carry. // guarded-by: clusters_test.zig "rasterizeClusters: a synthetic frame with a nonzero rect still paints nothing"
        if (frame.synthetic) continue;
        if (rasterizeOne(lat, frame)) {
            written += 1;
        }
    }
    return written;
}

/// Rasterize a single cluster frame. Returns true if the frame was
/// drawn (even partially-conflicted), false if it was rejected for OOB
/// or degenerate geometry.
fn rasterizeOne(lat: *lattice.Lattice, frame: sketch.ClusterFrame) bool {
    const r = frame.rect;
    if (r.w < 2 or r.h < 2) {
        log.warn("cluster {d}: degenerate rect w={d} h={d}, skipped", .{ frame.id, r.w, r.h });
        return false;
    }
    if (r.x < 0 or r.y < 0) {
        log.warn("cluster {d}: negative origin ({d},{d}), skipped", .{ frame.id, r.x, r.y });
        return false;
    }
    const x0_i = r.x;
    const y0_i = r.y;
    const x1_i = r.right() - 1;
    const y1_i = r.bottom() - 1;
    if (x1_i < 0 or y1_i < 0) return false;
    if (@as(i64, x1_i) >= @as(i64, lat.width) or @as(i64, y1_i) >= @as(i64, lat.height)) {
        log.warn(
            "cluster {d}: rect ({d},{d},{d}x{d}) exceeds lattice {d}x{d}, skipped",
            .{ frame.id, r.x, r.y, r.w, r.h, lat.width, lat.height },
        );
        return false;
    }
    const x0: u32 = @intCast(x0_i);
    const y0: u32 = @intCast(y0_i);
    const x1: u32 = @intCast(x1_i);
    const y1: u32 = @intCast(y1_i);

    tryWrite(lat, x0, y0, frame.id, .corner_nw, .{ .e = true, .s = true });
    tryWrite(lat, x1, y0, frame.id, .corner_ne, .{ .w = true, .s = true });
    tryWrite(lat, x1, y1, frame.id, .corner_se, .{ .w = true, .n = true });
    tryWrite(lat, x0, y1, frame.id, .corner_sw, .{ .e = true, .n = true });

    if (x1 > x0 + 1) {
        var x: u32 = x0 + 1;
        while (x < x1) : (x += 1) {
            tryWrite(lat, x, y0, frame.id, .edge_n, .{ .e = true, .w = true });
            tryWrite(lat, x, y1, frame.id, .edge_s, .{ .e = true, .w = true });
        }
    }

    if (y1 > y0 + 1) {
        var y: u32 = y0 + 1;
        while (y < y1) : (y += 1) {
            tryWrite(lat, x0, y, frame.id, .edge_w, .{ .n = true, .s = true });
            tryWrite(lat, x1, y, frame.id, .edge_e, .{ .n = true, .s = true });
        }
    }
    return true;
}

/// Attempt to write a single cluster border cell. Implements the
/// conflict policy documented at the top of the file.
fn tryWrite(
    lat: *lattice.Lattice,
    x: u32,
    y: u32,
    cluster_id: lattice.ClusterId,
    role: lattice.BorderRole,
    nb: lattice.Neighbours,
) void {
    const cell = lat.at(x, y);
    switch (cell.occupant) {
        .empty => {
            cell.* = .{
                .occupant = .{ .cluster_border = .{ .cluster = cluster_id, .role = role } },
                .neighbours = nb,
            };
        },
        .cluster_border => {
            // Sort order ensures outer arrives first; inner overwrites. guarded-by: clusters.zig "nested clusters: inner overwrites outer at coincident cells"
            cell.* = .{
                .occupant = .{ .cluster_border = .{ .cluster = cluster_id, .role = role } },
                .neighbours = nb,
            };
        },
        .node_border, .node_interior => {
            log.warn(
                "cluster {d} border at ({d},{d}) conflicts with node cell, skipped",
                .{ cluster_id, x, y },
            );
        },
        .edge_segment, .arrowhead => {
            log.warn(
                "cluster {d} border at ({d},{d}) conflicts with edge cell, skipped",
                .{ cluster_id, x, y },
            );
        },
        .label_char => {
            log.warn(
                "cluster {d} border at ({d},{d}) conflicts with label cell, skipped",
                .{ cluster_id, x, y },
            );
        },
    }
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn makeLattice(allocator: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try allocator.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn makeSketch(clusters: []const sketch.ClusterFrame) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = clusters,
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 0, .rung = 0 },
    };
}

fn expectClusterBorder(
    lat: lattice.Lattice,
    x: u32,
    y: u32,
    cluster_id: lattice.ClusterId,
    role: lattice.BorderRole,
) !void {
    const c = lat.atConst(x, y);
    switch (c.occupant) {
        .cluster_border => |cb| {
            try testing.expectEqual(cluster_id, cb.cluster);
            try testing.expectEqual(role, cb.role);
        },
        else => return error.NotClusterBorder,
    }
}

test "single cluster: 4 corners + 6 edge cells with correct roles" {
    const allocator = testing.allocator;
    var lat = try makeLattice(allocator, 10, 5);
    defer allocator.free(lat.cells);

    const frames = [_]sketch.ClusterFrame{
        .{
            .id = 7,
            .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 },
            .parent_id = null,
            .label = "",
            .depth = 0,
        },
    };
    const s = makeSketch(&frames);

    const n = try rasterizeClusters(allocator, &lat, s);
    try testing.expectEqual(@as(u32, 1), n);

    try expectClusterBorder(lat, 0, 0, 7, .corner_nw);
    try expectClusterBorder(lat, 4, 0, 7, .corner_ne);
    try expectClusterBorder(lat, 4, 2, 7, .corner_se);
    try expectClusterBorder(lat, 0, 2, 7, .corner_sw);

    try expectClusterBorder(lat, 1, 0, 7, .edge_n);
    try expectClusterBorder(lat, 2, 0, 7, .edge_n);
    try expectClusterBorder(lat, 3, 0, 7, .edge_n);
    try expectClusterBorder(lat, 1, 2, 7, .edge_s);
    try expectClusterBorder(lat, 2, 2, 7, .edge_s);
    try expectClusterBorder(lat, 3, 2, 7, .edge_s);

    // Left/right edges only exist when h > 2; here h=3 so y=1 is the middle row.
    try expectClusterBorder(lat, 0, 1, 7, .edge_w);
    try expectClusterBorder(lat, 4, 1, 7, .edge_e);

    try testing.expectEqual(@as(u4, 0b0110), lat.atConst(0, 0).neighbours.toMask()); // E|S
    try testing.expectEqual(@as(u4, 0b1100), lat.atConst(4, 0).neighbours.toMask()); // S|W
    try testing.expectEqual(@as(u4, 0b1010), lat.atConst(1, 0).neighbours.toMask()); // E|W
    try testing.expectEqual(@as(u4, 0b0101), lat.atConst(0, 1).neighbours.toMask()); // N|S
}

test "nested clusters: non-coincident inner and outer both rendered" {
    const allocator = testing.allocator;
    var lat = try makeLattice(allocator, 12, 12);
    defer allocator.free(lat.cells);

    const frames = [_]sketch.ClusterFrame{
        .{
            .id = 1,
            .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
            .parent_id = null,
            .label = "",
            .depth = 0,
        },
        .{
            .id = 2,
            .rect = .{ .x = 2, .y = 2, .w = 4, .h = 4 },
            .parent_id = 1,
            .label = "",
            .depth = 1,
        },
    };
    const s = makeSketch(&frames);
    const n = try rasterizeClusters(allocator, &lat, s);
    try testing.expectEqual(@as(u32, 2), n);

    try expectClusterBorder(lat, 0, 0, 1, .corner_nw);
    try expectClusterBorder(lat, 9, 9, 1, .corner_se);
    try expectClusterBorder(lat, 2, 2, 2, .corner_nw);
    try expectClusterBorder(lat, 5, 5, 2, .corner_se);
}

test "nested clusters: inner overwrites outer at coincident cells" {
    const allocator = testing.allocator;
    var lat = try makeLattice(allocator, 10, 10);
    defer allocator.free(lat.cells);

    const frames = [_]sketch.ClusterFrame{
        .{
            .id = 10,
            .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
            .parent_id = null,
            .label = "",
            .depth = 0,
        },
        .{
            .id = 20,
            .rect = .{ .x = 0, .y = 0, .w = 5, .h = 5 },
            .parent_id = 10,
            .label = "",
            .depth = 1,
        },
    };
    const s = makeSketch(&frames);
    _ = try rasterizeClusters(allocator, &lat, s);

    // (0,0) is shared: inner (id 20) must win.
    try expectClusterBorder(lat, 0, 0, 20, .corner_nw);
    // (1,0) is on both top edges: inner wins.
    try expectClusterBorder(lat, 1, 0, 20, .edge_n);
    // (6,0) is only on the outer top edge.
    try expectClusterBorder(lat, 6, 0, 10, .edge_n);
}

test "cluster does not fill interior" {
    const allocator = testing.allocator;
    var lat = try makeLattice(allocator, 10, 10);
    defer allocator.free(lat.cells);

    const frames = [_]sketch.ClusterFrame{
        .{
            .id = 3,
            .rect = .{ .x = 1, .y = 1, .w = 7, .h = 7 },
            .parent_id = null,
            .label = "",
            .depth = 0,
        },
    };
    const s = makeSketch(&frames);
    _ = try rasterizeClusters(allocator, &lat, s);

    switch (lat.atConst(4, 4).occupant) {
        .empty => {},
        else => return error.InteriorNotEmpty,
    }
    switch (lat.atConst(2, 2).occupant) {
        .empty => {},
        else => return error.InteriorNotEmpty,
    }
    switch (lat.atConst(6, 6).occupant) {
        .empty => {},
        else => return error.InteriorNotEmpty,
    }
}

test "OOB cluster is skipped" {
    const allocator = testing.allocator;
    var lat = try makeLattice(allocator, 5, 5);
    defer allocator.free(lat.cells);

    const frames = [_]sketch.ClusterFrame{
        .{
            .id = 99,
            .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
            .parent_id = null,
            .label = "",
            .depth = 0,
        },
    };
    const s = makeSketch(&frames);
    const n = try rasterizeClusters(allocator, &lat, s);
    try testing.expectEqual(@as(u32, 0), n);

    for (lat.cells) |c| {
        switch (c.occupant) {
            .empty => {},
            else => return error.UnexpectedNonEmpty,
        }
    }
}

test {
    _ = @import("clusters_test.zig");
}
