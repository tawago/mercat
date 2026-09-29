const std = @import("std");

pub const LaneClaim = struct {
    lo: u32,
    hi: u32,
    base: i32,
};

pub const Assignment = struct {
    lane_of: []u32,
    lane_pos: []i32,

    pub fn posOf(self: Assignment, i: usize) i32 {
        return self.lane_pos[self.lane_of[i]];
    }

    pub fn deinit(self: *Assignment, a: std.mem.Allocator) void {
        a.free(self.lane_of);
        a.free(self.lane_pos);
    }
};

fn overlapsAny(claims: []const LaneClaim, members: []const u32, c: LaneClaim) bool {
    for (members) |mi| {
        const m = claims[mi];
        if (!(c.hi < m.lo or c.lo > m.hi)) return true;
    }
    return false;
}

pub fn assign(
    a: std.mem.Allocator,
    claims: []const LaneClaim,
    stack_gap: i32,
) error{OutOfMemory}!Assignment {
    const lane_of = try a.alloc(u32, claims.len);
    errdefer a.free(lane_of);

    const Lane = struct {
        members: std.ArrayListUnmanaged(u32),
        max_base: i32,
    };
    var lanes_buf: std.ArrayListUnmanaged(Lane) = .empty;
    defer {
        for (lanes_buf.items) |*ln| ln.members.deinit(a);
        lanes_buf.deinit(a);
    }

    for (claims, 0..) |c, i| {
        var chosen: ?usize = null;
        for (lanes_buf.items, 0..) |ln, li| {
            if (!overlapsAny(claims, ln.members.items, c)) {
                chosen = li;
                break;
            }
        }
        const li = chosen orelse blk: {
            try lanes_buf.append(a, .{ .members = .empty, .max_base = std.math.minInt(i32) });
            break :blk lanes_buf.items.len - 1;
        };
        var ln = &lanes_buf.items[li];
        try ln.members.append(a, @intCast(i));
        if (c.base > ln.max_base) ln.max_base = c.base;
        lane_of[i] = @intCast(li);
    }

    const lane_pos = try a.alloc(i32, lanes_buf.items.len);
    errdefer a.free(lane_pos);
    var prev_pos: i32 = std.math.minInt(i32);
    for (lanes_buf.items, 0..) |ln, li| {
        var pos = ln.max_base;
        if (prev_pos != std.math.minInt(i32) and pos <= prev_pos) {
            pos = prev_pos + stack_gap;
        }
        prev_pos = pos;
        lane_pos[li] = pos;
    }

    return .{ .lane_of = lane_of, .lane_pos = lane_pos };
}
