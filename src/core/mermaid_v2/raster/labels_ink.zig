const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");

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
        if (onSegment(self.seg_a, self.seg_b, x, y)) return true;
        if (self.polyline.len < 2) return false;
        for (self.polyline[0 .. self.polyline.len - 1], 0..) |p, i| {
            if (onSegment(p, self.polyline[i + 1], x, y)) return true;
        }
        return false;
    }
};

fn onSegment(a: sketch.Point, b: sketch.Point, x: i32, y: i32) bool {
    if (a.x != b.x and a.y != b.y) return false;
    return x >= @min(a.x, b.x) and x <= @max(a.x, b.x) and
        y >= @min(a.y, b.y) and y <= @max(a.y, b.y);
}

pub fn classifyAt(lat: *const lattice.Lattice, owner: Owner, x: i32, y: i32) InkClass {
    if (x < 0 or y < 0) return .none;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= lat.width or uy >= lat.height) return .none;
    return switch (lat.atConst(ux, uy).occupant) {
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
    if (x < 0 or y < 0) return false;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= lat.width or uy >= lat.height) return false;
    return switch (lat.atConst(ux, uy).occupant) {
        .label_char, .label_cont => true,
        else => false,
    };
}

/// @guarded-by: labels_ladder_test.zig "isolation rejects a foreign-ink neighbour in every one of the 8 directions"
/// @guarded-by: labels_ladder_test.zig "own-edge ink beside the anchor does not displace the label"
/// @guarded-by: labels_ladder_test.zig "allow_solid waives only the node/cluster margin, never the foreign-edge margin"
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
    // @guarded-by: labels_test.zig "edge-label runs on the same row keep two blank cells apart"
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
