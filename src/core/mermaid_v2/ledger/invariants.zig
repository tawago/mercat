const std = @import("std");
const pb = @import("../base/ledger.zig");
const sketch = @import("../sketch.zig");

/// @guarded-by: ledger/invariants.zig "the gap invariant counts a spacing the ledger did not ask for and a row no claim stands on"
pub fn gapRowsUnaccounted(gaps: []const pb.GapRows) u32 {
    var bad: u32 = 0;
    for (gaps) |g| {
        const extra = pb.gapSpacingNeeded(g.rows_used, g.base_used) -| g.base;
        if (g.reserved -| g.base != extra) {
            bad += 1;
            continue;
        }
        var r: u32 = 0;
        while (r < g.rows_used and r < 64) : (r += 1) {
            if (g.claimed & (@as(u64, 1) << @intCast(r)) == 0) {
                bad += 1;
                break;
            }
        }
    }
    return bad;
}

const Ink = union(enum) { edge: pb.EdgeId, rail: pb.RailKey };

fn runClaimed(gaps: []const pb.GapRows, at: i32, ink: Ink) bool {
    var covered = false;
    for (gaps) |g| {
        if (at < @min(g.near, g.far) or at > @max(g.near, g.far)) continue;
        covered = true;
        const toward_far: i32 = if (g.far >= g.near) 1 else -1;
        const row = (at - g.near) * toward_far - 2;
        for (g.claims) |c| {
            if (row < c.row or row >= c.row + @as(i32, @intCast(c.height))) continue;
            switch (ink) {
                .edge => |id| if (std.mem.indexOfScalar(pb.EdgeId, c.edges, id) != null) return true,
                .rail => |key| for (c.rails) |r| if (r.pivot == key.pivot and r.out == key.out) return true,
            }
        }
    }
    return !covered;
}

/// @guarded-by: ledger/invariants.zig "the painted-ink invariant counts a run on a row no claim of its edge stands on"
pub fn gapRowsUnclaimedInk(direction: sketch.Direction, edges: []const sketch.EdgePath, rails: []const sketch.Rail, gaps: []const pb.GapRows) u32 {
    const vertical = direction == .TD or direction == .BT;
    var bad: u32 = 0;
    for (edges) |e| {
        var i: usize = 1;
        while (i < e.polyline.len) : (i += 1) {
            const p = e.polyline[i - 1];
            const q = e.polyline[i];
            const along = if (vertical) p.y == q.y else p.x == q.x;
            const moves = if (vertical) p.x != q.x else p.y != q.y;
            if (!along or !moves) continue;
            if (!runClaimed(gaps, if (vertical) p.y else p.x, .{ .edge = e.id })) bad += 1;
        }
    }
    for (rails) |r| {
        const p = r.crossbar[0];
        const q = r.crossbar[1];
        if (if (vertical) p.x == q.x else p.y == q.y) continue;
        const key: pb.RailKey = .{ .pivot = r.pivot, .out = r.role != .fan_in_dropper };
        if (!runClaimed(gaps, if (vertical) p.y else p.x, .{ .rail = key })) bad += 1;
    }
    return bad;
}

test "the painted-ink invariant counts a run on a row no claim of its edge stands on" {
    const claims = [_]pb.GapClaim{
        .{ .row = 0, .height = 1, .edges = &.{1} },
        .{ .row = -1, .height = 1, .edges = &.{2} },
    };
    const gaps = [_]pb.GapRows{.{ .gap = 0, .base = 2, .reserved = 5, .free = 0, .rows_used = 1, .claimed = 0b1, .base_used = true, .near = 9, .far = 5, .claims = &claims }};
    const port: sketch.Port = .{ .node = 0, .side = .south, .offset = 0 };
    const on_row = [_]sketch.Point{ .{ .x = 0, .y = 4 }, .{ .x = 0, .y = 7 }, .{ .x = 6, .y = 7 }, .{ .x = 6, .y = 10 } };
    const on_base = [_]sketch.Point{ .{ .x = 0, .y = 4 }, .{ .x = 0, .y = 8 }, .{ .x = 6, .y = 8 }, .{ .x = 6, .y = 10 } };
    const foreign_row = [_]sketch.Point{ .{ .x = 0, .y = 4 }, .{ .x = 0, .y = 8 }, .{ .x = 6, .y = 8 }, .{ .x = 6, .y = 10 } };
    const arrival = [_]sketch.Point{ .{ .x = 0, .y = 4 }, .{ .x = 0, .y = 9 }, .{ .x = 6, .y = 9 }, .{ .x = 6, .y = 10 } };
    const outside = [_]sketch.Point{ .{ .x = 0, .y = 2 }, .{ .x = 6, .y = 2 } };
    const edges = [_]sketch.EdgePath{
        .{ .id = 1, .from = 0, .to = 1, .polyline = &on_row, .port_from = port, .port_to = port, .arrow_from = .none, .arrow_to = .none, .label = null, .kind = .solid },
        .{ .id = 2, .from = 0, .to = 1, .polyline = &on_base, .port_from = port, .port_to = port, .arrow_from = .none, .arrow_to = .none, .label = null, .kind = .solid },
        .{ .id = 1, .from = 0, .to = 1, .polyline = &foreign_row, .port_from = port, .port_to = port, .arrow_from = .none, .arrow_to = .none, .label = null, .kind = .solid },
        .{ .id = 2, .from = 0, .to = 1, .polyline = &arrival, .port_from = port, .port_to = port, .arrow_from = .none, .arrow_to = .none, .label = null, .kind = .solid },
        .{ .id = 3, .from = 0, .to = 1, .polyline = &outside, .port_from = port, .port_to = port, .arrow_from = .none, .arrow_to = .none, .label = null, .kind = .solid },
    };
    try std.testing.expectEqual(@as(u32, 0), gapRowsUnclaimedInk(.TD, edges[0..2], &.{}, &gaps));
    try std.testing.expectEqual(@as(u32, 2), gapRowsUnclaimedInk(.TD, edges[2..4], &.{}, &gaps));
    try std.testing.expectEqual(@as(u32, 0), gapRowsUnclaimedInk(.TD, edges[4..5], &.{}, &gaps));
}

test "the painted-ink invariant searches every record covering a line" {
    const first = [_]pb.GapClaim{.{ .row = 0, .height = 1, .edges = &.{7} }};
    const second = [_]pb.GapClaim{.{ .row = 0, .height = 1, .edges = &.{1} }};
    const gaps = [_]pb.GapRows{
        .{ .gap = 0, .base = 2, .reserved = 3, .free = 0, .rows_used = 1, .claimed = 0b1, .base_used = false, .near = 9, .far = 5, .claims = &first },
        .{ .gap = 0, .base = 2, .reserved = 3, .free = 0, .rows_used = 1, .claimed = 0b1, .base_used = false, .near = 9, .far = 5, .claims = &second },
    };
    const port: sketch.Port = .{ .node = 0, .side = .south, .offset = 0 };
    const on_row = [_]sketch.Point{ .{ .x = 0, .y = 4 }, .{ .x = 0, .y = 7 }, .{ .x = 6, .y = 7 }, .{ .x = 6, .y = 10 } };
    const edges = [_]sketch.EdgePath{
        .{ .id = 1, .from = 0, .to = 1, .polyline = &on_row, .port_from = port, .port_to = port, .arrow_from = .none, .arrow_to = .none, .label = null, .kind = .solid },
    };
    try std.testing.expectEqual(@as(u32, 0), gapRowsUnclaimedInk(.TD, &edges, &.{}, &gaps));
    try std.testing.expectEqual(@as(u32, 1), gapRowsUnclaimedInk(.TD, &edges, &.{}, gaps[0..1]));
}

test "the gap invariant counts a spacing the ledger did not ask for and a row no claim stands on" {
    const sound = [_]pb.GapRows{
        .{ .gap = 0, .base = 2, .reserved = 3, .free = 0, .rows_used = 1, .claimed = 0b1, .base_used = false },
        .{ .gap = 1, .base = 4, .reserved = 5, .free = 2, .rows_used = 3, .claimed = 0b111, .base_used = false },
        .{ .gap = 2, .base = 2, .reserved = 2, .free = 0, .rows_used = 0, .claimed = 0, .base_used = true },
        .{ .gap = 3, .base = 1, .reserved = 3, .free = 0, .rows_used = 1, .claimed = 0b1, .base_used = false },
        .{ .gap = 4, .base = 1, .reserved = 2, .free = 0, .rows_used = 0, .claimed = 0, .base_used = true },
    };
    try std.testing.expectEqual(@as(u32, 0), gapRowsUnaccounted(&sound));
    const loose_add = [_]pb.GapRows{.{ .gap = 0, .base = 2, .reserved = 4, .free = 0, .rows_used = 1, .claimed = 0b1, .base_used = false }};
    try std.testing.expectEqual(@as(u32, 1), gapRowsUnaccounted(&loose_add));
    const hole = [_]pb.GapRows{.{ .gap = 0, .base = 2, .reserved = 4, .free = 0, .rows_used = 2, .claimed = 0b10, .base_used = false }};
    try std.testing.expectEqual(@as(u32, 1), gapRowsUnaccounted(&hole));
}
