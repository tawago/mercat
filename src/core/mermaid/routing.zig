const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

const Graph = types.Graph;
const Point = types.Point;
const Rect = types.Rect;
const Direction = types.Direction;

const min_bend_segment_len: i32 = 2;

pub const NodeBounds = struct {
    id: []const u8,
    rect: Rect,

    pub fn intersectsSegment(self: NodeBounds, p1: Point, p2: Point) bool {
        if (p1.x == p2.x) {
            const x = p1.x;
            const top = @min(p1.y, p2.y);
            const bottom = @max(p1.y, p2.y);
            return x >= self.rect.x and
                x < self.rect.right() and
                bottom >= self.rect.y and
                top < self.rect.bottom();
        }

        if (p1.y == p2.y) {
            const y = p1.y;
            const left = @min(p1.x, p2.x);
            const right = @max(p1.x, p2.x);
            return y >= self.rect.y and
                y < self.rect.bottom() and
                right >= self.rect.x and
                left < self.rect.right();
        }

        return false;
    }
};

pub const EdgeRouter = struct {
    allocator: Allocator,
    bounds: std.ArrayList(NodeBounds),
    min_x: i32,
    max_x: i32,
    min_y: i32,
    max_y: i32,

    pub fn init(allocator: Allocator, graph: *const Graph) !EdgeRouter {
        var router = EdgeRouter{
            .allocator = allocator,
            .bounds = .empty,
            .min_x = std.math.maxInt(i32),
            .max_x = std.math.minInt(i32),
            .min_y = std.math.maxInt(i32),
            .max_y = std.math.minInt(i32),
        };
        errdefer router.deinit();

        for (graph.node_order.items) |id| {
            const node = graph.getNode(id) orelse continue;
            const x = node.x orelse continue;
            const y = node.y orelse continue;
            const rect = Rect{ .x = x, .y = y, .width = node.width, .height = node.height };
            try router.bounds.append(allocator, .{ .id = id, .rect = rect });
            router.min_x = @min(router.min_x, rect.x);
            router.max_x = @max(router.max_x, rect.right());
            router.min_y = @min(router.min_y, rect.y);
            router.max_y = @max(router.max_y, rect.bottom());
        }

        if (router.bounds.items.len == 0) {
            router.min_x = 0;
            router.max_x = 0;
            router.min_y = 0;
            router.max_y = 0;
        }

        return router;
    }

    pub fn deinit(self: *EdgeRouter) void {
        self.bounds.deinit(self.allocator);
    }

    pub fn buildPath(
        self: *const EdgeRouter,
        allocator: Allocator,
        path: *std.ArrayList(Point),
        start: Point,
        end: Point,
        direction: Direction,
        from_id: []const u8,
        to_id: []const u8,
    ) !void {
        try appendSimplePath(allocator, path, start, end, direction);
        if (pathHasMinBendSpacing(path.items) and !self.checkCollision(path.items, from_id, to_id)) return;

        path.clearRetainingCapacity();
        if (direction.isHorizontal()) {
            try self.buildHorizontalDetour(allocator, path, start, end, from_id, to_id, direction);
        } else {
            try self.buildVerticalDetour(allocator, path, start, end, from_id, to_id, direction);
        }
    }

    fn buildVerticalDetour(
        self: *const EdgeRouter,
        allocator: Allocator,
        path: *std.ArrayList(Point),
        start: Point,
        end: Point,
        from_id: []const u8,
        to_id: []const u8,
        direction: Direction,
    ) !void {
        var candidates: [16]i32 = undefined;
        var count: usize = 0;

        candidates[count] = start.x - 2;
        count += 1;
        candidates[count] = start.x + 2;
        count += 1;
        candidates[count] = end.x - 2;
        count += 1;
        candidates[count] = end.x + 2;
        count += 1;
        candidates[count] = self.min_x - 2;
        count += 1;
        candidates[count] = self.max_x + 1;
        count += 1;

        for (self.bounds.items) |bound| {
            if (std.mem.eql(u8, bound.id, from_id) or std.mem.eql(u8, bound.id, to_id)) continue;
            if (count + 2 > candidates.len) break;
            candidates[count] = bound.rect.x - 1;
            count += 1;
            candidates[count] = bound.rect.right();
            count += 1;
        }

        sortCandidates(candidates[0..count], @divFloor(start.x + end.x, 2));

        for (candidates[0..count]) |route_x| {
            if (route_x == start.x and route_x == end.x) continue;
            try path.append(allocator, start);
            if (route_x != start.x) try path.append(allocator, .{ .x = route_x, .y = start.y });
            if (start.y != end.y) try path.append(allocator, .{ .x = route_x, .y = end.y });
            try path.append(allocator, end);
            if (pathHasMinBendSpacing(path.items) and !self.checkCollision(path.items, from_id, to_id)) return;
            path.clearRetainingCapacity();
        }

        try appendSimplePath(allocator, path, start, end, direction);
    }

    fn buildHorizontalDetour(
        self: *const EdgeRouter,
        allocator: Allocator,
        path: *std.ArrayList(Point),
        start: Point,
        end: Point,
        from_id: []const u8,
        to_id: []const u8,
        direction: Direction,
    ) !void {
        var candidates: [16]i32 = undefined;
        var count: usize = 0;

        candidates[count] = start.y - 2;
        count += 1;
        candidates[count] = start.y + 2;
        count += 1;
        candidates[count] = end.y - 2;
        count += 1;
        candidates[count] = end.y + 2;
        count += 1;
        candidates[count] = self.min_y - 2;
        count += 1;
        candidates[count] = self.max_y + 1;
        count += 1;

        for (self.bounds.items) |bound| {
            if (std.mem.eql(u8, bound.id, from_id) or std.mem.eql(u8, bound.id, to_id)) continue;
            if (count + 2 > candidates.len) break;
            candidates[count] = bound.rect.y - 1;
            count += 1;
            candidates[count] = bound.rect.bottom();
            count += 1;
        }

        sortCandidates(candidates[0..count], @divFloor(start.y + end.y, 2));

        for (candidates[0..count]) |route_y| {
            if (route_y == start.y and route_y == end.y) continue;
            try path.append(allocator, start);
            if (route_y != start.y) try path.append(allocator, .{ .x = start.x, .y = route_y });
            if (start.x != end.x) try path.append(allocator, .{ .x = end.x, .y = route_y });
            try path.append(allocator, end);
            if (pathHasMinBendSpacing(path.items) and !self.checkCollision(path.items, from_id, to_id)) return;
            path.clearRetainingCapacity();
        }

        try appendSimplePath(allocator, path, start, end, direction);
    }

    fn checkCollision(self: *const EdgeRouter, path: []const Point, from_id: []const u8, to_id: []const u8) bool {
        if (path.len < 2) return false;

        for (self.bounds.items) |bound| {
            if (std.mem.eql(u8, bound.id, from_id) or std.mem.eql(u8, bound.id, to_id)) continue;
            for (path[0 .. path.len - 1], path[1..]) |p1, p2| {
                if (bound.intersectsSegment(p1, p2)) return true;
            }
        }

        return false;
    }
};

fn appendSimplePath(allocator: Allocator, path: *std.ArrayList(Point), start: Point, end: Point, direction: Direction) !void {
    try path.append(allocator, start);
    if (direction.isHorizontal()) {
        if (start.y != end.y) try path.append(allocator, .{ .x = start.x, .y = end.y });
    } else {
        if (start.x != end.x) try path.append(allocator, .{ .x = end.x, .y = start.y });
    }
    try path.append(allocator, end);
}

fn sortCandidates(values: []i32, preferred: i32) void {
    std.mem.sort(i32, values, preferred, struct {
        fn lessThan(ctx: i32, a: i32, b: i32) bool {
            const da = @abs(a - ctx);
            const db = @abs(b - ctx);
            if (da == db) return a < b;
            return da < db;
        }
    }.lessThan);
}

fn pathHasMinBendSpacing(path: []const Point) bool {
    if (path.len < 3) return true;

    for (1..path.len - 1) |i| {
        const prev = path[i - 1];
        const curr = path[i];
        const next = path[i + 1];
        if (segmentLen(prev, curr) < min_bend_segment_len or segmentLen(curr, next) < min_bend_segment_len) {
            return false;
        }
    }

    return true;
}

fn segmentLen(a: Point, b: Point) i32 {
    const dx: i32 = @intCast(@abs(a.x - b.x));
    const dy: i32 = @intCast(@abs(a.y - b.y));
    return dx + dy;
}

test "node bounds detects orthogonal segment intersection" {
    const testing = std.testing;
    const bound = NodeBounds{ .id = "A", .rect = .{ .x = 4, .y = 2, .width = 6, .height = 3 } };

    try testing.expect(bound.intersectsSegment(.{ .x = 0, .y = 3 }, .{ .x = 10, .y = 3 }));
    try testing.expect(bound.intersectsSegment(.{ .x = 5, .y = 0 }, .{ .x = 5, .y = 10 }));
    try testing.expect(!bound.intersectsSegment(.{ .x = 0, .y = 1 }, .{ .x = 10, .y = 1 }));
}

test "bent paths require a full segment on both sides of the corner" {
    const testing = std.testing;

    try testing.expect(pathHasMinBendSpacing(&.{
        .{ .x = 5, .y = 4 },
        .{ .x = 5, .y = 6 },
        .{ .x = 7, .y = 6 },
    }));

    try testing.expect(!pathHasMinBendSpacing(&.{
        .{ .x = 5, .y = 4 },
        .{ .x = 5, .y = 6 },
        .{ .x = 6, .y = 6 },
    }));
}
