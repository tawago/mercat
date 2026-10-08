const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const geo = @import("geometry.zig");

pub fn tagShape(lat: *lattice.Lattice, np: sketch.NodePlacement) void {
    if (np.shape == .rect) return;
    if (!geo.rectFitsLattice(np.rect, lat)) return;
    const shape = np.shape;
    const x0: u32 = @intCast(np.rect.x);
    const y0: u32 = @intCast(np.rect.y);
    const x_end: u32 = x0 + np.rect.w;
    const y_end: u32 = y0 + np.rect.h;
    var y: u32 = y0;
    while (y < y_end) : (y += 1) {
        var x: u32 = x0;
        while (x < x_end) : (x += 1) {
            const cell = lat.at(x, y);
            switch (cell.occupant) {
                .node_border => |b| if (b.node == np.id) {
                    cell.shape = shape;
                },
                .node_interior => |id| if (id == np.id) {
                    cell.shape = shape;
                },
                else => {},
            }
        }
    }
}

pub fn rasterizeSubroutineInner(lat: *lattice.Lattice, np: sketch.NodePlacement) void {
    if (np.shape != .subroutine) return;
    if (!geo.rectFitsLattice(np.rect, lat)) return;
    if (np.rect.w < 5 or np.rect.h < 3) return;
    const x0: u32 = @intCast(np.rect.x);
    const y0: u32 = @intCast(np.rect.y);
    const x_last: u32 = x0 + np.rect.w - 1;
    const y_last: u32 = y0 + np.rect.h - 1;
    const left_x: u32 = x0 + 1;
    const right_x: u32 = x_last - 1;
    if (right_x <= left_x + 1) return;

    addNeighbourIfBorder(lat, left_x, y0, np.id, .{ .s = true });
    addNeighbourIfBorder(lat, right_x, y0, np.id, .{ .s = true });
    addNeighbourIfBorder(lat, left_x, y_last, np.id, .{ .n = true });
    addNeighbourIfBorder(lat, right_x, y_last, np.id, .{ .n = true });

    var y: u32 = y0 + 1;
    while (y < y_last) : (y += 1) {
        writeInnerWall(lat, left_x, y, np.id, .edge_w);
        writeInnerWall(lat, right_x, y, np.id, .edge_e);
    }
}

fn addNeighbourIfBorder(
    lat: *lattice.Lattice,
    x: u32,
    y: u32,
    node: lattice.NodeId,
    extra: lattice.Neighbours,
) void {
    const cell = lat.at(x, y);
    switch (cell.occupant) {
        .node_border => |b| if (b.node == node) {
            const merged: u4 = cell.neighbours.toMask() | extra.toMask();
            cell.neighbours = lattice.Neighbours.fromMask(merged);
        },
        else => {},
    }
}

fn writeInnerWall(
    lat: *lattice.Lattice,
    x: u32,
    y: u32,
    node: lattice.NodeId,
    role: lattice.BorderRole,
) void {
    const cell = lat.at(x, y);
    switch (cell.occupant) {
        .node_interior => |id| if (id == node) {
            cell.* = .{
                .occupant = .{ .node_border = .{ .node = node, .role = role } },
                .neighbours = .{ .n = true, .s = true },
                .shape = .subroutine,
            };
        },
        else => {},
    }
}

const testing = std.testing;

test {
    _ = @import("node_shapes_test.zig");
}
