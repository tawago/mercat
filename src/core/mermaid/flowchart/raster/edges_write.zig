const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const crossings = @import("crossings.zig");

const log = std.log.scoped(.@"mermaid_v2.raster.edges");

pub const Move = lattice.Dir4;

pub fn straightMask(dir: Move) lattice.Neighbours {
    return switch (dir) {
        .north, .south => .{ .n = true, .s = true },
        .east, .west => .{ .e = true, .w = true },
    };
}

pub fn bitMask(dir: Move) lattice.Neighbours {
    return switch (dir) {
        .north => .{ .n = true },
        .east => .{ .e = true },
        .south => .{ .s = true },
        .west => .{ .w = true },
    };
}

pub fn reverse(dir: Move) Move {
    return switch (dir) {
        .north => .south,
        .south => .north,
        .east => .west,
        .west => .east,
    };
}

pub fn orMask(a: lattice.Neighbours, b: lattice.Neighbours) lattice.Neighbours {
    return lattice.Neighbours.fromMask(a.toMask() | b.toMask());
}

pub fn segmentDir(a: sketch.Point, b: sketch.Point) ?Move {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    if (dx == 0 and dy == 0) return null;
    if (dx != 0 and dy != 0) return null;
    if (dx > 0) return .east;
    if (dx < 0) return .west;
    if (dy > 0) return .south;
    return .north;
}

pub fn step(p: sketch.Point, dir: Move) sketch.Point {
    return switch (dir) {
        .north => .{ .x = p.x, .y = p.y - 1 },
        .south => .{ .x = p.x, .y = p.y + 1 },
        .east => .{ .x = p.x + 1, .y = p.y },
        .west => .{ .x = p.x - 1, .y = p.y },
    };
}

pub fn pointInBounds(p: sketch.Point, lat: *const lattice.Lattice) bool {
    return p.x >= 0 and p.y >= 0 and
        p.x < @as(i32, @intCast(lat.width)) and
        p.y < @as(i32, @intCast(lat.height));
}

pub const Coord = struct { x: u32, y: u32 };

/// The shared-run role a fan stroke of `role` belongs to, or null outside a fan.
pub fn railRole(role: lattice.EdgeRole) ?lattice.EdgeRole {
    return switch (role) {
        .fan_out_rail, .fan_out_dropper => .fan_out_rail,
        .fan_in_rail, .fan_in_dropper => .fan_in_rail,
        else => null,
    };
}

pub fn toCoord(p: sketch.Point) Coord {
    std.debug.assert(p.x >= 0 and p.y >= 0);
    return .{ .x = @intCast(p.x), .y = @intCast(p.y) };
}

pub fn writeEdgeCell(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    role: lattice.EdgeRole,
    extra: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
) void {
    switch (cell.occupant) {
        .empty => {
            cell.occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = kind, .role = role } };
            cell.neighbours = extra;
            cell.stroke_kind = kind;
        },
        .cluster_border => {
            cell.occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = kind, .role = role } };
            cell.neighbours = orMask(cell.neighbours, extra);
            cell.stroke_kind = kind;
        },
        .edge_segment => |existing| {
            cell.occupant = .{ .edge_segment = .{
                .edge = existing.edge,
                .kind = existing.kind,
                .role = mergeRole(existing.role, role),
            } };
            cell.neighbours = orMask(cell.neighbours, extra);
        },
        .arrowhead => |head| {
            if (head.edge != edge_id and refuseLateral(cells_lost, head.dir, extra)) return;
            cell.neighbours = orMask(cell.neighbours, extra);
        },
        .node_interior, .node_border => {
            cells_lost.* += 1;
            log.debug(
                "mermaid_v2/raster/edges: edge {d} at ({d},{d}) collides with node-owned cell; skipping",
                .{ edge_id, x, y },
            );
        },
        .label_char, .label_cont => {
            cells_lost.* += 1;
            log.debug(
                "mermaid_v2/raster/edges: edge {d} at ({d},{d}) collides with label_char; skipping",
                .{ edge_id, x, y },
            );
        },
    }
}

fn refuseLateral(cells_lost: *u32, tip: Move, mask: lattice.Neighbours) bool {
    if (crossings.lateralArms(tip, mask).toMask() == 0) return false;
    cells_lost.* += 1;
    return true;
}

pub fn writeArrowCell(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    arrow: lattice.ArrowKind,
    dir: Move,
    along: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
) void {
    switch (cell.occupant) {
        .empty, .edge_segment, .cluster_border => {
            cell.occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge_id, .arrow = arrow } };
            cell.neighbours = orMask(cell.neighbours, along);
            cell.stroke_kind = kind;
        },
        .arrowhead => |head| {
            if (head.edge != edge_id and head.dir != dir) {
                cells_lost.* += 1;
                return;
            }
            cell.neighbours = orMask(cell.neighbours, along);
        },
        .node_interior, .node_border, .label_char, .label_cont => {
            cells_lost.* += 1;
            log.debug(
                "mermaid_v2/raster/edges: arrowhead for edge {d} at ({d},{d}) collides; skipping",
                .{ edge_id, x, y },
            );
        },
    }
}

pub fn writeArrowGuarded(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    arrow: lattice.ArrowKind,
    dir: Move,
    along: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
    ctx: crossings.Ctx,
) void {
    if (cell.occupant == .edge_segment) {
        const seg = cell.occupant.edge_segment;
        if (crossings.arrowheadTransit(ctx.counts, ctx.bundles, ctx.bundle_sets, seg.edge, edge_id, crossings.cellAt(x, y))) {
            cell.occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge_id, .arrow = arrow } };
            cell.neighbours = along;
            cell.stroke_kind = kind;
            return;
        }
    }
    writeArrowCell(cell, edge_id, kind, arrow, dir, along, x, y, cells_lost);
}

pub fn mergeRole(existing: lattice.EdgeRole, incoming: lattice.EdgeRole) lattice.EdgeRole {
    if (priority(incoming) > priority(existing)) return incoming;
    return existing;
}

fn priority(r: lattice.EdgeRole) u8 {
    return switch (r) {
        .fan_out_rail, .fan_in_rail => 3,
        .fan_out_dropper, .fan_in_dropper => 2,
        .back_edge, .self_loop, .cluster_internal => 1,
        .forward, .member_stroke => 0,
    };
}

test {
    _ = @import("edges_write_test.zig");
}
