const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const geo = @import("geometry.zig");
const crossings = @import("crossings.zig");

pub const InkClass = enum { none, own, foreign_edge, foreign_solid };

pub const InkDistances = struct {
    own: ?u32 = null,
    foreign_edge: ?u32 = null,
};

pub const Owner = struct {
    edge_id: u32,
    polyline: []const sketch.Point,
    seg_a: sketch.Point,
    seg_b: sketch.Point,

    fn onOwnPath(self: Owner, x: i32, y: i32) bool {
        if (geo.onSegment(self.seg_a, self.seg_b, x, y)) return true;
        if (self.polyline.len < 2) return false;
        for (self.polyline[0 .. self.polyline.len - 1], 0..) |p, i| {
            if (geo.onSegment(p, self.polyline[i + 1], x, y)) return true;
        }
        return false;
    }
};

pub fn classifyAt(lat: *const lattice.Lattice, owner: Owner, x: i32, y: i32) InkClass {
    const cell = geo.cellAt(lat, x, y) orelse return .none;
    return switch (cell.occupant) {
        .empty, .label_char, .label_cont => .none,
        .edge_segment => |seg| edgeInk(owner, seg.edge, x, y),
        .arrowhead => |ah| edgeInk(owner, ah.edge, x, y),
        .node_border, .node_interior, .cluster_border => .foreign_solid,
    };
}

fn edgeInk(owner: Owner, cell_edge: u32, x: i32, y: i32) InkClass {
    if (cell_edge == owner.edge_id) return .own;
    if (owner.onOwnPath(x, y)) return .own;
    return .foreign_edge;
}

fn isLabelCell(lat: *const lattice.Lattice, x: i32, y: i32) bool {
    const cell = geo.cellAt(lat, x, y) orelse return false;
    return switch (cell.occupant) {
        .label_char, .label_cont => true,
        else => false,
    };
}

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

pub fn spanIsolated(
    lat: *const lattice.Lattice,
    owner: Owner,
    start_x: i32,
    row: i32,
    cell_count: u32,
    allow_solid: bool,
) bool {
    const cc: i32 = @intCast(cell_count);
    var y: i32 = row - 1;
    while (y <= row + 1) : (y += 1) {
        var x: i32 = start_x - 1;
        while (x <= start_x + cc) : (x += 1) {
            if (y == row and x >= start_x and x < start_x + cc) continue;
            switch (classifyAt(lat, owner, x, y)) {
                .foreign_edge => return false,
                .foreign_solid => if (!allow_solid) return false,
                .none, .own => {},
            }
        }
    }
    if (isLabelCell(lat, start_x - 1, row) or isLabelCell(lat, start_x - 2, row)) return false;
    if (isLabelCell(lat, start_x + cc, row) or isLabelCell(lat, start_x + cc + 1, row)) return false;
    return true;
}

pub fn inkDistances(
    lat: *const lattice.Lattice,
    owner: Owner,
    start_x: i32,
    row: i32,
    cell_count: u32,
    radius: u32,
) InkDistances {
    var res: InkDistances = .{};
    const cc: i32 = @intCast(cell_count);
    var d: u32 = 1;
    while (d <= radius) : (d += 1) {
        if (res.own != null and res.foreign_edge != null) break;
        const di: i32 = @intCast(d);
        const x0 = start_x - di;
        const x1 = start_x + cc - 1 + di;
        const y0 = row - di;
        const y1 = row + di;
        var x = x0;
        while (x <= x1) : (x += 1) {
            note(&res, lat, owner, x, y0, d);
            note(&res, lat, owner, x, y1, d);
        }
        var y = y0 + 1;
        while (y < y1) : (y += 1) {
            note(&res, lat, owner, x0, y, d);
            note(&res, lat, owner, x1, y, d);
        }
    }
    return res;
}

fn note(res: *InkDistances, lat: *const lattice.Lattice, owner: Owner, x: i32, y: i32, d: u32) void {
    switch (classifyAt(lat, owner, x, y)) {
        .own => {
            if (res.own == null) res.own = d;
        },
        .foreign_edge => {
            if (res.foreign_edge == null) res.foreign_edge = d;
        },
        .none, .foreign_solid => {},
    }
}

test {
    _ = @import("labels_ink_test.zig");
}
