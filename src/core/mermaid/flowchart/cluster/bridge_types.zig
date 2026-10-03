const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");

const Pt = sketch.Point;

pub const Crossing = struct {
    id: sketch.EdgeId,
    from: sg.NodeId,
    to: sg.NodeId,
    kind: sketch.EdgeKind,
    arrow_from: sketch.ArrowKind,
    arrow_to: sketch.ArrowKind,
    label: ?[]const u8,
    origin: sg.EdgeId = sg.SENTINEL,
};

pub const RailEnd = enum { start, end };

pub const Sides = struct { exit: sketch.Dir4, entry: sketch.Dir4 };

pub fn clampBetween(lo: i32, hi: i32, want: i32) i32 {
    if (hi - lo < 2) return lo + 1;
    if (want <= lo) return lo + 1;
    if (want >= hi) return hi - 1;
    return want;
}

pub const Elbow = struct {
    points: [4]Pt = undefined,
    len: usize = 0,

    pub fn slice(self: *const Elbow) []const Pt {
        return self.points[0..self.len];
    }

    pub fn dupe(self: Elbow, arena: std.mem.Allocator) error{OutOfMemory}![]Pt {
        return arena.dupe(Pt, self.points[0..self.len]);
    }

    fn push(self: *Elbow, p: Pt) void {
        self.points[self.len] = p;
        self.len += 1;
    }
};

pub const Pending = struct {
    cross: Crossing,
    gf: sketch.NodeId,
    gt: sketch.NodeId,
    from_rect: sketch.Rect,
    to_rect: sketch.Rect,
    to_box: sketch.Rect,
    sides: Sides,
    start: Pt,
    end: Pt,
    off_from: u32,
    off_to: u32,
    from_frame: ?sketch.ClusterId,
    to_frame: ?sketch.ClusterId,
    pref: ?i32,
    jog: ?i32 = null,
    rail_end: RailEnd = .start,

    pub fn vertical(p: Pending) bool {
        return p.sides.exit == .north or p.sides.exit == .south;
    }

    pub fn bounds(p: Pending) [2]i32 {
        return switch (p.sides.exit) {
            .south => .{ p.start.y, p.end.y },
            .north => .{ p.end.y, p.start.y },
            .east => .{ p.start.x, p.end.x },
            .west => .{ p.end.x, p.start.x },
        };
    }

    pub fn clampedJog(p: Pending) ?i32 {
        const j = p.jog orelse return null;
        const b = p.bounds();
        return clampBetween(b[0], b[1], j);
    }

    pub fn resetJog(p: *Pending) void {
        p.pref = switch (p.sides.exit) {
            .south => if (p.start.x == p.end.x) null else @min(p.to_box.y - 1, p.end.y - 2),
            .north => if (p.start.x == p.end.x) null else @max(p.to_box.bottom(), p.end.y + 2),
            .east => if (p.start.y == p.end.y) null else @min(p.to_box.x - 1, p.end.x - 2),
            .west => if (p.start.y == p.end.y) null else @max(p.to_box.right(), p.end.x + 2),
        };
        p.jog = null;
    }

    pub fn sameAnchor(a: Pending, b: Pending) bool {
        if (a.to_frame) |frame| return b.to_frame == frame;
        return b.to_frame == null and a.gt == b.gt;
    }

    pub fn elbow(p: Pending) Elbow {
        var out: Elbow = .{};
        out.push(p.start);
        if (p.clampedJog()) |jc| {
            if (p.vertical()) {
                out.push(.{ .x = p.start.x, .y = jc });
                out.push(.{ .x = p.end.x, .y = jc });
            } else {
                out.push(.{ .x = jc, .y = p.start.y });
                out.push(.{ .x = jc, .y = p.end.y });
            }
        }
        out.push(p.end);
        return out;
    }
};

test {
    _ = @import("bridge_types_test.zig");
}
