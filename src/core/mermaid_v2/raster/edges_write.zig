const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const roles = @import("edge_roles.zig");
const crossings = @import("crossings.zig");
const aux = @import("aux.zig");

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

pub fn recordCarrier(
    rec: aux.Recorder,
    x: u32,
    y: u32,
    edge: u32,
    how: lattice.CarrierKind,
) void {
    rec.at(x, y, .carrier, edge, @intFromEnum(how));
}

pub fn recordRailMember(
    rec: aux.Recorder,
    x: u32,
    y: u32,
    edge: u32,
    polarity: lattice.RailPolarity,
) void {
    rec.at(x, y, .rail_member, edge, @intFromEnum(polarity));
}

pub fn recordTap(
    rec: aux.Recorder,
    x: u32,
    y: u32,
    edge: u32,
    polarity: lattice.RailPolarity,
) void {
    rec.at(x, y, .tap, edge, @intFromEnum(polarity));
}

pub fn recordIntrusion(
    rec: aux.Recorder,
    x: u32,
    y: u32,
    edge: u32,
    how: lattice.IntrusionKind,
) void {
    rec.at(x, y, .intrusion, edge, @intFromEnum(how));
}

pub fn railPolarity(role: lattice.EdgeRole) ?lattice.RailPolarity {
    return switch (role) {
        .fan_out_rail, .fan_out_dropper => .out,
        .fan_in_rail, .fan_in_dropper => .in,
        else => null,
    };
}

pub fn roleState(role: lattice.EdgeRole) lattice.InkState {
    return switch (role) {
        .fan_out_rail, .fan_in_rail => .rail_interior,
        else => .stroke,
    };
}

pub fn toCoord(p: sketch.Point) Coord {
    std.debug.assert(p.x >= 0 and p.y >= 0);
    return .{ .x = @intCast(p.x), .y = @intCast(p.y) };
}

/// @guarded-by: aux_test.zig "an OR-merge onto a foreign cell files a merged carrier; onto its own ink, nothing"
/// @guarded-by: edges_write_test.zig "writeEdgeCell files the merged carrier under the licence its caller established"
/// @guarded-by: edges_write_test.zig "a foreign lateral arm into a head is refused and counted against the writer"
/// @guarded-by: edges_write_test.zig "a co-member riding a head's axis keeps the rail-interior residue"
pub fn writeEdgeCell(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    role: lattice.EdgeRole,
    extra: lattice.Neighbours,
    x: u32,
    y: u32,
    cells_lost: *u32,
    counts: *crossings.CrossingCounts,
    licence: lattice.CarrierKind,
    rec: aux.Recorder,
) void {
    switch (cell.occupant) {
        .empty => {
            cell.occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = kind, .role = role } };
            cell.neighbours = extra;
            cell.stroke_kind = kind;
            cell.state = roleState(role);
        },
        .cluster_border => {
            cell.occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = kind, .role = role } };
            cell.neighbours = orMask(cell.neighbours, extra);
            cell.stroke_kind = kind;
            cell.upgradeState(.junction);
        },
        .edge_segment => |existing| {
            if (existing.edge != edge_id) {
                const grows = (cell.neighbours.toMask() | extra.toMask()) != cell.neighbours.toMask();
                cell.upgradeState(if (grows) .junction else .rail_interior);
            }
            cell.occupant = .{ .edge_segment = .{
                .edge = existing.edge,
                .kind = existing.kind,
                .role = roles.mergeRole(existing.role, role),
            } };
            cell.neighbours = orMask(cell.neighbours, extra);
            if (existing.edge != edge_id) recordCarrier(rec, x, y, edge_id, licence);
        },
        .arrowhead => |head| {
            if (head.edge != edge_id) {
                if (refuseLateral(counts, cells_lost, head.dir, extra)) {
                    recordCarrier(rec, x, y, edge_id, .suppressed);
                    return;
                }
                cell.upgradeState(.rail_interior);
            }
            cell.neighbours = orMask(cell.neighbours, extra);
            if (head.edge != edge_id) recordCarrier(rec, x, y, edge_id, licence);
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

fn refuseLateral(
    counts: *crossings.CrossingCounts,
    cells_lost: *u32,
    tip: Move,
    mask: lattice.Neighbours,
) bool {
    const lateral: u32 = @popCount(crossings.lateralArms(tip, mask).toMask());
    if (lateral == 0) return false;
    counts.arm_into_head += lateral;
    cells_lost.* += 1;
    return true;
}

/// @guarded-by: edges_write_test.zig "a head stamped over a co-member's run is rail-interior; over a stranger's, junction"
/// @guarded-by: edges_write_test.zig "writeArrowCell stamps the edge's own stroke_kind"
/// @guarded-by: edges_write_test.zig "a foreign head pointing another way is refused; one pointing the same way rides"
/// @guarded-by: aux_test.zig "an arrowhead stamped over a foreign run files a carrier for the run it covered"
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
    heads_lost: *u32,
    counts: *crossings.CrossingCounts,
    licence: lattice.CarrierKind,
    rec: aux.Recorder,
) void {
    switch (cell.occupant) {
        .empty, .edge_segment, .cluster_border => {
            switch (cell.occupant) {
                .empty => cell.upgradeState(.stroke),
                .edge_segment => |seg| if (seg.edge != edge_id) cell.upgradeState(if (licence == .merged_licensed) .rail_interior else .junction) else if (cell.state == .none) {
                    cell.state = .stroke;
                },
                .cluster_border => cell.upgradeState(.junction),
                else => unreachable,
            }
            if (cell.occupant == .edge_segment and cell.occupant.edge_segment.edge != edge_id) {
                recordCarrier(rec, x, y, cell.occupant.edge_segment.edge, licence);
            }
            cell.occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge_id, .arrow = arrow } };
            cell.neighbours = orMask(cell.neighbours, along);
            cell.stroke_kind = kind;
        },
        .arrowhead => |head| {
            if (head.edge != edge_id) {
                if (head.dir != dir) {
                    if (!refuseLateral(counts, cells_lost, head.dir, along)) cells_lost.* += 1;
                    heads_lost.* += 1;
                    recordCarrier(rec, x, y, edge_id, .suppressed);
                    return;
                }
                cell.upgradeState(.rail_interior);
            }
            cell.neighbours = orMask(cell.neighbours, along);
            if (head.edge != edge_id) recordCarrier(rec, x, y, edge_id, licence);
        },
        .node_interior, .node_border, .label_char, .label_cont => {
            cells_lost.* += 1;
            heads_lost.* += 1;
            log.debug(
                "mermaid_v2/raster/edges: arrowhead for edge {d} at ({d},{d}) collides; skipping",
                .{ edge_id, x, y },
            );
        },
    }
}

/// @guarded-by: edges_write_test.zig "writeArrowGuarded refuse branch stamps the arrowhead's own stroke_kind"
/// @guarded-by: edges_write_test.zig "an arrowhead landing on a foreign arrowhead files a foreign carrier"
/// @guarded-by: aux_test.zig "a refused arrowhead transit files a suppressed carrier for the crossed run"
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
    heads_lost: *u32,
    ctx: crossings.Ctx,
    rec: aux.Recorder,
) void {
    if (cell.occupant == .edge_segment) {
        const seg = cell.occupant.edge_segment;
        if (crossings.arrowheadTransit(ctx.counts, ctx.bundles, ctx.bundle_sets, seg.edge, edge_id, crossings.cellAt(x, y))) {
            cell.occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge_id, .arrow = arrow } };
            cell.neighbours = along;
            cell.stroke_kind = kind;
            cell.upgradeState(.crossing);
            recordCarrier(rec, x, y, seg.edge, .suppressed);
            return;
        }
    }
    const licence = crossings.carrierKindOnto(cell, ctx.bundle_sets, ctx.stamp_state, edge_id, null, crossings.cellAt(x, y));
    writeArrowCell(cell, edge_id, kind, arrow, dir, along, x, y, cells_lost, heads_lost, ctx.counts, licence, rec);
}

test {
    _ = @import("edges_write_test.zig");
}
