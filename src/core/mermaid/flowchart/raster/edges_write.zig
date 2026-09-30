const std = @import("std");
const lattice = @import("../lattice.zig");
const crossings = @import("crossings.zig");
const geo = @import("geometry.zig");

const log = std.log.scoped(.@"mermaid_v2.raster.edges");

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
            cell.neighbours = geo.orMask(cell.neighbours, extra);
            cell.stroke_kind = kind;
        },
        .edge_segment => |existing| {
            cell.occupant = .{ .edge_segment = .{
                .edge = existing.edge,
                .kind = existing.kind,
                .role = mergeRole(existing.role, role),
            } };
            cell.neighbours = geo.orMask(cell.neighbours, extra);
        },
        .arrowhead => |head| {
            if (head.edge != edge_id and refuseLateral(cells_lost, head.dir, extra)) return;
            cell.neighbours = geo.orMask(cell.neighbours, extra);
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

fn refuseLateral(cells_lost: *u32, tip: geo.Move, mask: lattice.Neighbours) bool {
    if (crossings.lateralArms(tip, mask).toMask() == 0) return false;
    cells_lost.* += 1;
    return true;
}

pub fn writeArrowCell(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    arrow: lattice.ArrowKind,
    dir: geo.Move,
    along: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
) void {
    switch (cell.occupant) {
        .empty, .edge_segment, .cluster_border => {
            cell.occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge_id, .arrow = arrow } };
            cell.neighbours = geo.orMask(cell.neighbours, along);
            cell.stroke_kind = kind;
        },
        .arrowhead => |head| {
            if (head.edge != edge_id and head.dir != dir) {
                cells_lost.* += 1;
                return;
            }
            cell.neighbours = geo.orMask(cell.neighbours, along);
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
    dir: geo.Move,
    along: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
    ctx: crossings.Ctx,
) void {
    if (cell.occupant == .edge_segment) {
        const seg = cell.occupant.edge_segment;
        if (ctx.arrowheadTransit(seg.edge, edge_id, crossings.cellAt(x, y))) {
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
        .back_edge, .self_loop => 1,
        .forward, .member_stroke => 0,
    };
}

test {
    _ = @import("edges_write_test.zig");
}
