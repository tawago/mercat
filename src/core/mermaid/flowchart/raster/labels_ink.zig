const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const geo = @import("geometry.zig");
const crossings = @import("crossings.zig");

pub const Axis = enum { vertical, horizontal };

pub fn along(m: lattice.Neighbours, axis: Axis) bool {
    return crossings.isStraightPair(m) and m.e == (axis == .horizontal);
}

pub const Host = struct {
    edge: lattice.EdgeId,
    ends: [2]lattice.NodeId,
    axis: Axis,
    lo: sketch.Point,
    hi: sketch.Point,

    fn onLine(self: Host, x: i32, y: i32) bool {
        return switch (self.axis) {
            .vertical => x == self.lo.x,
            .horizontal => y == self.lo.y,
        };
    }

    fn endsAt(self: Host, node: lattice.NodeId) bool {
        return node == self.ends[0] or node == self.ends[1];
    }

    fn length(self: Host) i32 {
        return (self.hi.x - self.lo.x) + (self.hi.y - self.lo.y);
    }
};

pub fn hosts(
    allocator: std.mem.Allocator,
    edge: lattice.EdgeId,
    ends: [2]lattice.NodeId,
    polyline: []const sketch.Point,
) error{OutOfMemory}![]Host {
    var out: std.ArrayList(Host) = .empty;
    errdefer out.deinit(allocator);
    if (polyline.len >= 2) {
        for (polyline[0 .. polyline.len - 1], polyline[1..]) |p, q| {
            if (p.x == q.x and p.y == q.y) continue;
            if (p.x != q.x and p.y != q.y) continue;
            try out.append(allocator, .{
                .edge = edge,
                .ends = ends,
                .axis = if (p.x == q.x) .vertical else .horizontal,
                .lo = .{ .x = @min(p.x, q.x), .y = @min(p.y, q.y) },
                .hi = .{ .x = @max(p.x, q.x), .y = @max(p.y, q.y) },
            });
        }
    }
    std.sort.insertion(Host, out.items, {}, longerFirst);
    return out.toOwnedSlice(allocator);
}

fn longerFirst(_: void, a: Host, b: Host) bool {
    return a.length() > b.length();
}

pub const MiddleOut = struct {
    lo: i32,
    hi: i32,
    mid: i32,
    d: i32 = 0,
    upper: bool = false,

    pub fn init(lo: i32, hi: i32) MiddleOut {
        return .{ .lo = lo, .hi = hi, .mid = @divTrunc(lo + hi, 2) };
    }

    pub fn next(self: *MiddleOut) ?i32 {
        while (self.mid - self.d >= self.lo or self.mid + self.d <= self.hi) {
            if (!self.upper) {
                self.upper = true;
                if (self.mid - self.d >= self.lo) return self.mid - self.d;
            } else {
                self.upper = false;
                const t = self.mid + self.d;
                self.d += 1;
                if (t - 1 >= self.mid and t <= self.hi) return t;
            }
        }
        return null;
    }
};

pub const Relation = enum { none, private, piercing, joined, rail_interior, foreign_run, own_box, foreign_box, frame, decoration, label };

pub fn relationAt(lat: *const lattice.Lattice, h: Host, x: i32, y: i32) Relation {
    const cell = geo.cellAt(lat, x, y) orelse return .none;
    return switch (cell.occupant) {
        .empty => .none,
        .label_char, .label_cont => .label,
        .arrowhead => .decoration,
        .cluster_border => .frame,
        .node_border => |b| if (h.endsAt(b.node)) .own_box else .foreign_box,
        .node_interior => |n| if (h.endsAt(n)) .own_box else .foreign_box,
        .edge_segment => |seg| if (seg.edge == h.edge) switch (seg.cohabit) {
            .crossed => .piercing,
            .joined => .joined,
            .alone => if (seg.role == .fan_out_rail or seg.role == .fan_in_rail) .rail_interior else .private,
        } else if (h.onLine(x, y) and crossings.isStraightPair(cell.neighbours) and !along(cell.neighbours, h.axis))
            .piercing
        else
            .foreign_run,
    };
}

test {
    _ = @import("labels_ink_test.zig");
}
