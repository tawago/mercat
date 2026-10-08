const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const edges = @import("edges.zig");
const prims = @import("geometry.zig");

const testing = std.testing;

fn sourceBorderLattice(a: std.mem.Allocator, border_y: u32) !lattice.Lattice {
    const cells = try a.alloc(lattice.Cell, 2);
    for (cells) |*c| c.* = lattice.Cell.empty;
    cells[border_y] = .{
        .occupant = .{ .node_border = .{ .node = 0, .role = .edge_s } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .solid,
        .shape = .rect,
    };
    return .{ .width = 1, .height = 2, .cells = cells };
}

fn borderLattice3(a: std.mem.Allocator, bx: u32, by: u32, mask: lattice.Neighbours) !lattice.Lattice {
    const cells = try a.alloc(lattice.Cell, 9);
    for (cells) |*c| c.* = lattice.Cell.empty;
    cells[by * 3 + bx] = .{
        .occupant = .{ .node_border = .{ .node = 0, .role = .edge_n } },
        .neighbours = mask,
        .stroke_kind = .solid,
        .shape = .rect,
    };
    return .{ .width = 3, .height = 3, .cells = cells };
}

test "port strokes stamp a thick or dotted kind on either end; an invisible edge leaves the border untouched" {
    const a = testing.allocator;
    const kinds = [_]lattice.EdgeKind{ .solid, .thick, .dotted, .invisible };
    for ([2]bool{ true, false }) |source| {
        for (kinds) |kind| {
            var lat = if (source) try sourceBorderLattice(a, 0) else try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
            defer a.free(lat.cells);
            const visible = kind != .invisible;
            const cell = if (source) blk: {
                const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
                edges.drawPortStroke(&lat, &pts, kind, 0, .{});
                try testing.expectEqual(visible, lat.atConst(0, 0).neighbours.s);
                break :blk lat.atConst(0, 0);
            } else blk: {
                const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
                edges.drawTargetPortStroke(&lat, &pts, kind, 0, .{});
                try testing.expectEqual(visible, lat.atConst(1, 2).neighbours.n);
                break :blk lat.atConst(1, 2);
            };
            try testing.expectEqual(if (visible) kind else .solid, cell.stroke_kind);
        }
    }
}

test "drawTargetPortStroke: arrival arms merge on all four faces" {
    const a = testing.allocator;
    const cases = [_]struct {
        border: [2]u32,
        border_mask: lattice.Neighbours,
        from: sketch.Point,
        expect: lattice.Neighbours,
    }{
        .{ .border = .{ 1, 2 }, .border_mask = .{ .e = true, .w = true }, .from = .{ .x = 1, .y = 0 }, .expect = .{ .n = true } },
        .{ .border = .{ 1, 0 }, .border_mask = .{ .e = true, .w = true }, .from = .{ .x = 1, .y = 2 }, .expect = .{ .s = true } },
        .{ .border = .{ 2, 1 }, .border_mask = .{ .n = true, .s = true }, .from = .{ .x = 0, .y = 1 }, .expect = .{ .w = true } },
        .{ .border = .{ 0, 1 }, .border_mask = .{ .n = true, .s = true }, .from = .{ .x = 2, .y = 1 }, .expect = .{ .e = true } },
    };
    for (cases) |tc| {
        var lat = try borderLattice3(a, tc.border[0], tc.border[1], tc.border_mask);
        defer a.free(lat.cells);
        const pts = [_]sketch.Point{ tc.from, .{ .x = @intCast(tc.border[0]), .y = @intCast(tc.border[1]) } };
        edges.drawTargetPortStroke(&lat, &pts, .solid, 0, .{});
        const got = lat.atConst(tc.border[0], tc.border[1]).neighbours;
        try testing.expectEqual(
            prims.orMask(tc.border_mask, tc.expect).toMask(),
            got.toMask(),
        );
    }
}

test "drawTargetPortStroke: refuses non-border occupants" {
    const a = testing.allocator;
    {
        var lat = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
        defer a.free(lat.cells);
        const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 } };
        edges.drawTargetPortStroke(&lat, &pts, .solid, 0, .{});
        try testing.expectEqual(@as(u4, 0), lat.atConst(0, 2).neighbours.toMask());
    }
    {
        var lat = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
        defer a.free(lat.cells);
        lat.at(1, 2).* = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
        const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
        edges.drawTargetPortStroke(&lat, &pts, .solid, 0, .{});
        try testing.expectEqual(@as(u4, 0), lat.atConst(1, 2).neighbours.toMask());
    }
}

test "a decorated arrival whose head faces the wall leaves it pristine; one pointing along or detached still tees" {
    const a = testing.allocator;
    const N = lattice.Neighbours;
    const cases = [_]struct {
        border: [2]u32,
        border_mask: N,
        from: sketch.Point,
        to: sketch.Point,
        head: edges.Head,
        tee: N = .{},
    }{
        .{ .border = .{ 1, 2 }, .border_mask = .{ .e = true, .w = true }, .from = .{ .x = 1, .y = 0 }, .to = .{ .x = 1, .y = 2 }, .head = .{ .cell = .{ .x = 1, .y = 1 }, .dir = .south } },
        .{ .border = .{ 1, 0 }, .border_mask = .{ .e = true, .w = true }, .from = .{ .x = 1, .y = 2 }, .to = .{ .x = 1, .y = 0 }, .head = .{ .cell = .{ .x = 1, .y = 1 }, .dir = .north } },
        .{ .border = .{ 2, 1 }, .border_mask = .{ .n = true, .s = true }, .from = .{ .x = 0, .y = 1 }, .to = .{ .x = 2, .y = 1 }, .head = .{ .cell = .{ .x = 1, .y = 1 }, .dir = .east } },
        .{ .border = .{ 0, 1 }, .border_mask = .{ .n = true, .s = true }, .from = .{ .x = 2, .y = 1 }, .to = .{ .x = 0, .y = 1 }, .head = .{ .cell = .{ .x = 1, .y = 1 }, .dir = .west } },
        // A head adjacent to the wall but pointing ALONG the route still tees it.
        .{ .border = .{ 1, 0 }, .border_mask = .{ .e = true, .w = true }, .from = .{ .x = 1, .y = 2 }, .to = .{ .x = 1, .y = 0 }, .head = .{ .cell = .{ .x = 1, .y = 1 }, .dir = .west }, .tee = .{ .s = true } },
        // A DETACHED head (not on the gap) still tees the wall across the gap.
        .{ .border = .{ 2, 1 }, .border_mask = .{ .n = true, .s = true }, .from = .{ .x = 0, .y = 1 }, .to = .{ .x = 1, .y = 1 }, .head = .{ .cell = .{ .x = 0, .y = 1 }, .dir = .east }, .tee = .{ .w = true } },
    };
    for (cases) |tc| {
        var lat = try borderLattice3(a, tc.border[0], tc.border[1], tc.border_mask);
        defer a.free(lat.cells);
        if (tc.to.x != tc.border[0] or tc.to.y != tc.border[1]) lat.at(tc.border[0], tc.border[1]).occupant.node_border.role = .edge_w;
        const pts = [_]sketch.Point{ tc.from, tc.to };
        edges.drawTargetPortStroke(&lat, &pts, .solid, 0, .{ .head = tc.head });
        const wall = lat.atConst(tc.border[0], tc.border[1]);
        try testing.expectEqual(prims.orMask(tc.border_mask, tc.tee).toMask(), wall.neighbours.toMask());
        try testing.expectEqual(lattice.EdgeKind.solid, wall.stroke_kind);
    }
}

test "an UNDECORATED gap arrival also gets tee, painted gap and run" {
    const a = testing.allocator;
    var lat = try borderLattice3(a, 2, 1, .{ .n = true, .s = true });
    defer a.free(lat.cells);
    lat.at(2, 1).occupant.node_border.role = .edge_w;
    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } };
    edges.drawTargetPortStroke(&lat, &pts, .dotted, 3, .{});
    try testing.expect(lat.atConst(2, 1).neighbours.w);
    try testing.expectEqual(
        lattice.Occupant.edge_segment,
        std.meta.activeTag(lat.atConst(1, 1).occupant),
    );
    try testing.expectEqual(lattice.EdgeKind.dotted, lat.atConst(1, 1).stroke_kind);
}

test "an OCCUPIED gap cell is never painted and never probed across" {
    const a = testing.allocator;
    var lat = try borderLattice3(a, 2, 1, .{ .n = true, .s = true });
    defer a.free(lat.cells);
    lat.at(2, 1).occupant.node_border.role = .edge_w;
    lat.at(1, 1).* = .{
        .occupant = .{ .label_char = 'x' },
        .neighbours = .{},
    };
    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } };
    edges.drawTargetPortStroke(&lat, &pts, .solid, 0, .{});
    try testing.expect(!lat.atConst(2, 1).neighbours.w);
    try testing.expectEqual(
        lattice.Occupant.label_char,
        std.meta.activeTag(lat.atConst(1, 1).occupant),
    );
}

test "a bidirectional edge: facing heads leave BOTH walls plain, others tee both" {
    const a = testing.allocator;
    {
        var lat = try borderLattice3(a, 1, 0, .{ .e = true, .w = true });
        defer a.free(lat.cells);
        lat.at(1, 2).* = .{
            .occupant = .{ .node_border = .{ .node = 1, .role = .edge_n } },
            .neighbours = .{ .e = true, .w = true },
            .stroke_kind = .solid,
            .shape = .rect,
        };
        const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
        const up: edges.Head = .{ .cell = .{ .x = 1, .y = 1 }, .dir = .north };
        const down: edges.Head = .{ .cell = .{ .x = 1, .y = 1 }, .dir = .south };
        edges.drawPortStroke(&lat, &pts, .solid, 0, .{ .head = up });
        edges.drawTargetPortStroke(&lat, &pts, .solid, 0, .{ .head = down });
        try testing.expect(!lat.atConst(1, 0).neighbours.s);
        try testing.expect(!lat.atConst(1, 2).neighbours.n);
    }
    {
        const cells = try a.alloc(lattice.Cell, 15);
        defer a.free(cells);
        for (cells) |*c| c.* = lattice.Cell.empty;
        const wall: lattice.Cell = .{
            .occupant = .{ .node_border = .{ .node = 0, .role = .edge_n } },
            .neighbours = .{ .e = true, .w = true },
            .stroke_kind = .solid,
            .shape = .rect,
        };
        cells[0 * 3 + 1] = wall;
        cells[4 * 3 + 1] = wall;
        var lat = lattice.Lattice{ .width = 3, .height = 5, .cells = cells };
        const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 4 } };
        const up: edges.Head = .{ .cell = .{ .x = 1, .y = 2 }, .dir = .north };
        const down: edges.Head = .{ .cell = .{ .x = 1, .y = 2 }, .dir = .south };
        edges.drawPortStroke(&lat, &pts, .solid, 0, .{ .head = up });
        edges.drawTargetPortStroke(&lat, &pts, .solid, 0, .{ .head = down });
        try testing.expect(lat.atConst(1, 0).neighbours.s);
        try testing.expect(lat.atConst(1, 4).neighbours.n);
    }
}

test "a corner landing is refused: no merge" {
    const a = testing.allocator;
    var lat = try borderLattice3(a, 1, 2, .{ .e = true, .s = true });
    defer a.free(lat.cells);
    lat.at(1, 2).occupant.node_border.role = .corner_nw;
    const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
    edges.drawTargetPortStroke(&lat, &pts, .solid, 0, .{});
    try testing.expect(!lat.atConst(1, 2).neighbours.n);
}
