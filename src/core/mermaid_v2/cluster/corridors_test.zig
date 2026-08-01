const std = @import("std");
const sketch = @import("../sketch.zig");
const corridors = @import("corridors.zig");

const testing = std.testing;

test "two edges into one port are one corridor and keep one column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frames = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 12, .h = 8 }, .parent_id = null, .label = "S", .depth = 0 },
    };
    const reqs = [_]corridors.Req{
        .{ .frame = 1, .side = .north, .want = 6, .lo = 4, .hi = 8, .group = corridors.groupKey(3, .north) },
        .{ .frame = 1, .side = .north, .want = 6, .lo = 4, .hi = 8, .group = corridors.groupKey(3, .north) },
    };
    const got = try corridors.resolve(a, &reqs, &frames, &.{});
    try testing.expectEqual(@as(i32, 6), got[0]);
    try testing.expectEqual(@as(i32, 6), got[1]);
}

test "two corridors demanding one border column: the later one shifts sideways" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frames = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 12, .h = 8 }, .parent_id = null, .label = "S", .depth = 0 },
    };
    const reqs = [_]corridors.Req{
        .{ .frame = 1, .side = .north, .want = 6, .lo = 4, .hi = 8, .group = corridors.groupKey(3, .north) },
        .{ .frame = 1, .side = .north, .want = 6, .lo = 4, .hi = 8, .group = corridors.groupKey(4, .north) },
        .{ .frame = 1, .side = .north, .want = 6, .lo = 4, .hi = 8, .group = corridors.groupKey(5, .north) },
    };
    const got = try corridors.resolve(a, &reqs, &frames, &.{});
    try testing.expectEqual(@as(i32, 6), got[0]);
    try testing.expectEqual(@as(i32, 7), got[1]);
    try testing.expectEqual(@as(i32, 5), got[2]);
}

test "a corridor demanding a frame corner is moved off it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frames = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 12, .h = 8 }, .parent_id = null, .label = "S", .depth = 0 },
    };
    // The frame's north side runs x = 0..11; 0 and 11 are its corners.
    const reqs = [_]corridors.Req{
        .{ .frame = 1, .side = .north, .want = 11, .lo = 8, .hi = 12, .group = corridors.groupKey(3, .north) },
        .{ .frame = 1, .side = .west, .want = 0, .lo = 0, .hi = 4, .group = corridors.groupKey(4, .west) },
    };
    const got = try corridors.resolve(a, &reqs, &frames, &.{});
    try testing.expectEqual(@as(i32, 12), got[0]);
    try testing.expectEqual(@as(i32, 1), got[1]);
    try testing.expect(!corridors.onCorner(frames[0].rect, .north, got[0]));
    try testing.expect(!corridors.onCorner(frames[0].rect, .west, got[1]));
}

test "a corridor with no legal column in its own face keeps its column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frames = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 12, .h = 8 }, .parent_id = null, .label = "S", .depth = 0 },
    };
    // A 2-wide node has no interior face cell at all: faceRange is empty.
    const rng = corridors.faceRange(.{ .x = 5, .y = 0, .w = 2, .h = 3 }, .north);
    try testing.expect(rng.hi < rng.lo);
    const reqs = [_]corridors.Req{
        .{ .frame = 1, .side = .north, .want = 6, .lo = 4, .hi = 8, .group = corridors.groupKey(3, .north) },
        .{ .frame = 1, .side = .north, .want = 6, .lo = rng.lo, .hi = rng.hi, .group = corridors.groupKey(4, .north) },
    };
    const got = try corridors.resolve(a, &reqs, &frames, &.{});
    try testing.expectEqual(@as(i32, 6), got[0]);
    try testing.expectEqual(@as(i32, 6), got[1]);
}

test "portOffset inverts the centred sideOffset on both face orientations" {
    const r: sketch.Rect = .{ .x = 5, .y = 3, .w = 6, .h = 4 };
    try testing.expectEqual(@as(u32, 2), corridors.portOffset(r, .north, 7));
    try testing.expectEqual(@as(u32, 2), corridors.portOffset(r, .west, 5));
    // A crossing left where it was reproduces the centred offset exactly,
    // which is why an undisturbed bridge is byte-identical.
    const c = corridors.sideOffset(r, .north);
    try testing.expectEqual(c, corridors.portOffset(r, .north, r.x + @as(i32, @intCast(c))));
}

test "two bridges entering one frame at one column: the later port slides along its face" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two targets stacked in one column inside S, so both centred north
    // ports name the same border column.
    const frames = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 0, .y = 10, .w = 14, .h = 12 }, .parent_id = null, .label = "S", .depth = 0 },
    };
    const t1: sketch.Rect = .{ .x = 4, .y = 12, .w = 6, .h = 3 };
    const t2: sketch.Rect = .{ .x = 4, .y = 17, .w = 6, .h = 3 };
    const src: sketch.Rect = .{ .x = 4, .y = 0, .w = 6, .h = 3 };
    const pairs = [_]corridors.Pair{
        .{
            .from = .{ .node = 0, .rect = src, .side = .south, .frame = null },
            .to = .{ .node = 1, .rect = t1, .side = .north, .frame = 1 },
        },
        .{
            .from = .{ .node = 0, .rect = src, .side = .south, .frame = null },
            .to = .{ .node = 2, .rect = t2, .side = .north, .frame = 1 },
        },
    };
    const got = try corridors.discipline(a, &pairs, &frames, &.{});
    try testing.expectEqual(@as(i32, 7), got[0].to_coord);
    try testing.expectEqual(@as(u32, 3), got[0].to_off);
    try testing.expect(got[1].to_coord != got[0].to_coord);
    try testing.expectEqual(@as(i32, 8), got[1].to_coord);
    try testing.expectEqual(@as(u32, 4), got[1].to_off);
    // A top-level source raises no demand: its port stays centred.
    try testing.expectEqual(@as(u32, 3), got[0].from_off);
    try testing.expectEqual(@as(u32, 3), got[1].from_off);
}

fn place(id: sketch.NodeId, rect: sketch.Rect, cluster: ?sketch.ClusterId) sketch.NodePlacement {
    return .{ .id = id, .rect = rect, .shape = .rect, .lines = &.{}, .cluster_id = cluster };
}

test "a slide that would drive the approach run through a node box is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Same geometry as "two bridges entering one frame at one column", where
    // with no placements to consult the second port slides to column 8. Here
    // t1 sits between S's north border and t2, so EVERY column of t2's face
    // would drag the approach run through t1 — a swallowed stroke plus a
    // fabricated second foot on t1's bottom border. The merge is kept instead.
    const frames = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 0, .y = 10, .w = 14, .h = 12 }, .parent_id = null, .label = "S", .depth = 0 },
    };
    const t1: sketch.Rect = .{ .x = 4, .y = 12, .w = 6, .h = 3 };
    const t2: sketch.Rect = .{ .x = 4, .y = 17, .w = 6, .h = 3 };
    const src: sketch.Rect = .{ .x = 4, .y = 0, .w = 6, .h = 3 };
    const placements = [_]sketch.NodePlacement{
        place(0, src, null), place(1, t1, 1), place(2, t2, 1),
    };
    const pairs = [_]corridors.Pair{
        .{
            .from = .{ .node = 0, .rect = src, .side = .south, .frame = null },
            .to = .{ .node = 1, .rect = t1, .side = .north, .frame = 1 },
        },
        .{
            .from = .{ .node = 0, .rect = src, .side = .south, .frame = null },
            .to = .{ .node = 2, .rect = t2, .side = .north, .frame = 1 },
        },
    };
    const got = try corridors.discipline(a, &pairs, &frames, &placements);
    try testing.expectEqual(@as(i32, 7), got[0].to_coord);
    try testing.expectEqual(@as(i32, 7), got[1].to_coord);
    try testing.expectEqual(@as(u32, 3), got[1].to_off);

    // Drop the blocker and the same demand slides again: the refusal is the
    // node term talking, not the search having run out of face.
    const open = [_]sketch.NodePlacement{ place(0, src, null), place(2, t2, 1) };
    const got2 = try corridors.discipline(a, &pairs, &frames, &open);
    try testing.expectEqual(@as(i32, 8), got2[1].to_coord);
}

test "the node-clearance run is read along the face's own axis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A west face is entered by a HORIZONTAL run, so the blocker has to be
    // read as a row span. n1 sits between S's west border and n2, and the
    // two share a centred port ROW, so the second demand is the one that
    // would have to move.
    const frames = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 10, .y = 0, .w = 14, .h = 14 }, .parent_id = null, .label = "S", .depth = 0 },
    };
    const n1: sketch.Rect = .{ .x = 12, .y = 2, .w = 4, .h = 6 };
    const n2: sketch.Rect = .{ .x = 18, .y = 2, .w = 4, .h = 6 };
    const src: sketch.Rect = .{ .x = 0, .y = 2, .w = 4, .h = 6 };
    const pairs = [_]corridors.Pair{
        .{
            .from = .{ .node = 0, .rect = src, .side = .east, .frame = null },
            .to = .{ .node = 1, .rect = n1, .side = .west, .frame = 1 },
        },
        .{
            .from = .{ .node = 0, .rect = src, .side = .east, .frame = null },
            .to = .{ .node = 2, .rect = n2, .side = .west, .frame = 1 },
        },
    };
    // With n1 absent from the obstacle list the far demand slides one row.
    const open = [_]sketch.NodePlacement{ place(0, src, null), place(2, n2, 1) };
    const got = try corridors.discipline(a, &pairs, &frames, &open);
    try testing.expect(got[0].to_coord != got[1].to_coord);

    // With n1 present it blocks every row of n2's face, so the merge stands.
    const blocked = [_]sketch.NodePlacement{ place(0, src, null), place(1, n1, 1), place(2, n2, 1) };
    const got2 = try corridors.discipline(a, &pairs, &frames, &blocked);
    try testing.expectEqual(got2[0].to_coord, got2[1].to_coord);
}

test "both endpoints inside one drawn frame cross no border and never slide" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frames = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 14, .h = 12 }, .parent_id = null, .label = "S", .depth = 0 },
    };
    const r1: sketch.Rect = .{ .x = 4, .y = 2, .w = 6, .h = 3 };
    const r2: sketch.Rect = .{ .x = 4, .y = 7, .w = 6, .h = 3 };
    const pairs = [_]corridors.Pair{
        .{
            .from = .{ .node = 1, .rect = r1, .side = .south, .frame = 1 },
            .to = .{ .node = 2, .rect = r2, .side = .north, .frame = 1 },
        },
        .{
            .from = .{ .node = 2, .rect = r2, .side = .north, .frame = 1 },
            .to = .{ .node = 1, .rect = r1, .side = .south, .frame = 1 },
        },
    };
    const got = try corridors.discipline(a, &pairs, &frames, &.{});
    for (got) |g| {
        try testing.expectEqual(@as(i32, 7), g.from_coord);
        try testing.expectEqual(@as(i32, 7), g.to_coord);
    }
}

test "drawnFrame walks through synthetic packing frames to the drawn one" {
    const frames = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 14, .h = 12 }, .parent_id = null, .label = "S", .depth = 0 },
        .{ .id = 2, .rect = .{ .x = 2, .y = 2, .w = 8, .h = 6 }, .parent_id = 1, .label = "", .depth = 1, .synthetic = true },
    };
    const inner: sketch.NodePlacement = .{
        .id = 5,
        .rect = .{ .x = 3, .y = 3, .w = 4, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = 2,
    };
    try testing.expectEqual(@as(?sketch.ClusterId, 1), corridors.drawnFrame(&frames, inner));
    const top: sketch.NodePlacement = .{
        .id = 6,
        .rect = .{ .x = 20, .y = 0, .w = 4, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
    try testing.expectEqual(@as(?sketch.ClusterId, null), corridors.drawnFrame(&frames, top));
}
