//! Tests for `node_shapes.zig`'s `rasterizeSubroutineInner` width gate.
//! Split out of the former misc grab-bag test file (since dissolved)
//! into node_shapes.zig's own sibling, per the mermaid_v2/ test-file
//! convention. Discovered via node_shapes.zig's top-level
//! `test { _ = @import("node_shapes_test.zig"); }` block. (node_shapes.zig's
//! own shape-identity test stays inline in node_shapes.zig itself.)

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const node_shapes = @import("node_shapes.zig");

const testing = std.testing;

fn makeLattice(alloc: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try alloc.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn buildNodeRect(lat: *lattice.Lattice, rect: sketch.Rect, id: u32) void {
    var y: i32 = rect.y;
    while (y < rect.bottom()) : (y += 1) {
        var x: i32 = rect.x;
        while (x < rect.right()) : (x += 1) {
            const border = (y == rect.y or y == rect.bottom() - 1 or x == rect.x or x == rect.right() - 1);
            lat.at(@intCast(x), @intCast(y)).* = .{
                .occupant = if (border)
                    .{ .node_border = .{ .node = id, .role = .corner_nw } }
                else
                    .{ .node_interior = id },
                .neighbours = .{},
            };
        }
    }
}

// ---------------------------------------------------------------------
// node_shapes.zig: rasterizeSubroutineInner's width>=5 gate (near line 46)
// ---------------------------------------------------------------------
test "rasterizeSubroutineInner: width 4 draws no inner wall, width 5 does" {
    const allocator = testing.allocator;

    // Width 4 (< 5): the gate must reject the overlay entirely.
    {
        var lat = try makeLattice(allocator, 10, 5);
        defer allocator.free(lat.cells);
        const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = 4, .h = 3 };
        buildNodeRect(&lat, rect, 1);
        const np: sketch.NodePlacement = .{ .id = 1, .rect = rect, .shape = .subroutine, .lines = &.{}, .cluster_id = null };

        node_shapes.rasterizeSubroutineInner(&lat, np);

        // Middle row interior cells stay plain node_interior — no wall.
        switch (lat.atConst(1, 1).occupant) {
            .node_interior => {},
            else => return error.UnexpectedOverlayAtWidth4,
        }
        switch (lat.atConst(2, 1).occupant) {
            .node_interior => {},
            else => return error.UnexpectedOverlayAtWidth4,
        }
    }

    // Width 5 (>= 5): the overlay must be drawn at columns x0+1 / x_last-1.
    {
        var lat = try makeLattice(allocator, 10, 5);
        defer allocator.free(lat.cells);
        const rect: sketch.Rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 };
        buildNodeRect(&lat, rect, 1);
        const np: sketch.NodePlacement = .{ .id = 1, .rect = rect, .shape = .subroutine, .lines = &.{}, .cluster_id = null };

        node_shapes.rasterizeSubroutineInner(&lat, np);

        switch (lat.atConst(1, 1).occupant) {
            .node_border => |b| {
                try testing.expectEqual(@as(lattice.NodeId, 1), b.node);
                try testing.expectEqual(lattice.BorderRole.edge_w, b.role);
            },
            else => return error.MissingLeftWall,
        }
        switch (lat.atConst(3, 1).occupant) {
            .node_border => |b| {
                try testing.expectEqual(@as(lattice.NodeId, 1), b.node);
                try testing.expectEqual(lattice.BorderRole.edge_e, b.role);
            },
            else => return error.MissingRightWall,
        }
    }
}
