const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const fan_roles = @import("fan_roles.zig");
const crossings = @import("crossings.zig");
const geo = @import("geometry.zig");
const prim = @import("prim");

const log = std.log.scoped(.@"mermaid_v2.raster.edges");

const Move = geo.Move;
const straightMask = geo.straightMask;
const bitMask = geo.bitMask;
const reverse = geo.reverse;
const orMask = geo.orMask;
const segmentDir = geo.segmentDir;
const step = geo.step;
const pointInBounds = geo.pointInBounds;
const samePoint = geo.samePoint;
const toCoord = geo.toCoord;

pub const EdgeRasterReport = struct {
    cells_lost: u32 = 0,
    crossings: crossings.CrossingCounts = .{},
};

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
    if (geo.lateralArms(tip, mask).toMask() == 0) return false;
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
        if (ctx.arrowheadTransit(seg.edge, edge_id, crossings.bundleCellAt(x, y))) {
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

pub const Head = struct {
    cell: sketch.Point,
    dir: Move,
};

pub const PortEnd = struct {
    head: ?Head = null,
    role: lattice.EdgeRole = .forward,
};

pub fn drawPortStroke(
    lat: *lattice.Lattice,
    pts: []const sketch.Point,
    kind: lattice.EdgeKind,
    edge_id: u32,
    end: PortEnd,
) void {
    if (kind == .invisible) return;
    const fd = geo.firstDir(pts) orelse return;
    mergePortBit(lat, pts[0], fd, kind, edge_id, end);
}

pub fn drawTargetPortStroke(
    lat: *lattice.Lattice,
    pts: []const sketch.Point,
    kind: lattice.EdgeKind,
    edge_id: u32,
    end: PortEnd,
) void {
    if (kind == .invisible) return;
    const ld = geo.lastDir(pts) orelse return;
    mergePortBit(lat, pts[pts.len - 1], reverse(ld), kind, edge_id, end);
}

fn tipFaces(h: Head, q: sketch.Point) bool {
    return samePoint(step(h.cell, h.dir), q);
}

const Attach = struct { border: sketch.Point, gap: ?sketch.Point };

fn attachment(lat: *const lattice.Lattice, p: sketch.Point, travel: Move) ?Attach {
    var q = p;
    var gap: ?sketch.Point = null;
    var cell = geo.cellAt(lat, q.x, q.y) orelse return null;
    if (cell.occupant == .empty) {
        gap = q;
        q = step(q, travel);
        cell = geo.cellAt(lat, q.x, q.y) orelse return null;
    }
    if (cell.occupant != .node_border) return null;
    switch (cell.occupant.node_border.role) {
        .corner_nw, .corner_ne, .corner_se, .corner_sw => return null,
        else => {},
    }
    return .{ .border = q, .gap = gap };
}

pub fn slideHead(lat: *const lattice.Lattice, endpoint: sketch.Point, head: Head) Head {
    const at = attachment(lat, endpoint, head.dir) orelse return head;
    const g = at.gap orelse return head;
    if (!samePoint(step(head.cell, head.dir), g)) return head;
    return .{ .cell = g, .dir = head.dir };
}

fn mergePortBit(
    lat: *lattice.Lattice,
    p: sketch.Point,
    arm: Move,
    kind: lattice.EdgeKind,
    edge_id: u32,
    end: PortEnd,
) void {
    const at = attachment(lat, p, reverse(arm)) orelse return;
    const gap = at.gap;
    if (end.head) |h| {
        if (tipFaces(h, at.border)) return;
    }
    const c = toCoord(at.border);
    const cell = lat.at(c.x, c.y);
    cell.neighbours = orMask(cell.neighbours, bitMask(arm));
    if (kind != .solid and cell.stroke_kind == .solid) {
        cell.stroke_kind = kind;
    }

    if (gap) |g| {
        const gc = toCoord(g);
        var lost: u32 = 0;
        writeEdgeCell(
            lat.at(gc.x, gc.y),
            edge_id,
            kind,
            end.role,
            straightMask(arm),
            gc.x,
            gc.y,
            &lost,
        );
        std.debug.assert(lost == 0);
    }
}

const EdgeWalkResult = struct {
    first: ?Head = null,
    last: ?Head = null,
    source_head: ?Head = null,
    target_head: ?Head = null,

    fn note(self: *EdgeWalkResult, at: sketch.Point, first_dir: Move, last_dir: Move) void {
        if (self.first == null) self.first = .{ .cell = at, .dir = first_dir };
        self.last = .{ .cell = at, .dir = last_dir };
    }
};

fn crossingKeepsFirstWriter(
    cell: *const lattice.Cell,
    incoming_edge: u32,
    incoming_mask: lattice.Neighbours,
    at: crossings.BundleCell,
    ctx: crossings.Ctx,
) bool {
    return switch (cell.occupant) {
        .edge_segment => |seg| ctx.segmentOverlap(seg.edge, cell.neighbours, incoming_edge, incoming_mask, at),
        .arrowhead => |a| ctx.headEntry(a.edge, a.dir, incoming_edge, incoming_mask, at),
        else => false,
    };
}

fn claimCornerCell(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    role: lattice.EdgeRole,
    corner_mask: lattice.Neighbours,
) void {
    cell.occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = kind, .role = role } };
    cell.neighbours = corner_mask;
    cell.stroke_kind = kind;
}

const RailEnds = struct { source: bool = false, target: bool = false };

fn railEnds(s: sketch.Sketch, edge: sketch.EdgePath) RailEnds {
    var ends: RailEnds = .{};
    if (edge.role != .member_stroke) return ends;
    for (s.rails) |rail| {
        const fan_in = rail.role == .fan_in_dropper or rail.role == .fan_in_rail;
        for (rail.taps) |tap| {
            if (tap.edge != edge.id or !tap.continues) continue;
            if (fan_in) ends.target = true else ends.source = true;
        }
    }
    return ends;
}

const EdgeWalk = struct {
    lat: *lattice.Lattice,
    edge: sketch.EdgePath,
    cells_lost: *u32,
    ctx: crossings.Ctx,
    result: EdgeWalkResult = .{},

    fn corner(self: *EdgeWalk, at: sketch.Point, prev: Move, dir: Move, is_last: bool) void {
        if (!pointInBounds(at, self.lat)) return;
        const edge = self.edge;
        const c = toCoord(at);
        const cell = self.lat.at(c.x, c.y);
        const corner_mask = orMask(bitMask(reverse(prev)), bitMask(dir));
        switch (cell.occupant) {
            .edge_segment => |seg| {
                const refused = seg.edge != edge.id and
                    self.ctx.segmentOverlap(seg.edge, cell.neighbours, edge.id, corner_mask, crossings.bundleCellAt(c.x, c.y));
                if (!refused) {
                    cell.neighbours = orMask(cell.neighbours, corner_mask);
                    cell.occupant = .{ .edge_segment = .{
                        .edge = seg.edge,
                        .kind = seg.kind,
                        .role = mergeRole(seg.role, edge.role),
                    } };
                    fan_roles.markShared(cell, edge.id, edge.role);
                }
            },
            .empty => claimCornerCell(cell, edge.id, edge.kind, edge.role, corner_mask),
            .cluster_border => if (self.ctx.mode != .bridge) claimCornerCell(cell, edge.id, edge.kind, edge.role, corner_mask),
            else => if (!crossingKeepsFirstWriter(cell, edge.id, corner_mask, crossings.bundleCellAt(c.x, c.y), self.ctx)) {
                writeEdgeCell(cell, edge.id, edge.kind, edge.role, corner_mask, c.x, c.y, self.cells_lost);
                fan_roles.markShared(cell, edge.id, edge.role);
            },
        }
        self.result.note(at, dir, if (is_last) dir else prev);
    }

    fn straight(self: *EdgeWalk, at: sketch.Point, dir: Move, terminal: bool) void {
        if (!pointInBounds(at, self.lat)) return;
        const edge = self.edge;
        const c = toCoord(at);
        const cell = self.lat.at(c.x, c.y);
        const bridged = self.ctx.mode == .bridge and cell.occupant == .cluster_border and !terminal;
        if (!bridged and !crossingKeepsFirstWriter(cell, edge.id, straightMask(dir), crossings.bundleCellAt(c.x, c.y), self.ctx)) {
            writeEdgeCell(cell, edge.id, edge.kind, edge.role, straightMask(dir), c.x, c.y, self.cells_lost);
            fan_roles.markShared(cell, edge.id, edge.role);
        }
        self.result.note(at, dir, dir);
    }
};

fn walkPolyline(
    lat: *lattice.Lattice,
    edge: sketch.EdgePath,
    ends: RailEnds,
    cells_lost: *u32,
    ctx: crossings.Ctx,
) EdgeWalkResult {
    const pts = edge.polyline;
    if (pts.len < 2) {
        log.debug(
            "mermaid_v2/raster/edges: edge {d} polyline has {d} points; skipping",
            .{ edge.id, pts.len },
        );
        return .{};
    }

    var nontrivial: usize = 0;
    for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
        if (segmentDir(a, b) != null) nontrivial += 1;
    }
    if (nontrivial == 0) {
        log.debug(
            "mermaid_v2/raster/edges: edge {d} polyline is degenerate; skipping",
            .{edge.id},
        );
        return .{};
    }

    var walk: EdgeWalk = .{ .lat = lat, .edge = edge, .cells_lost = cells_lost, .ctx = ctx };
    var prev_dir: ?Move = null;
    var seg_index: usize = 0;
    for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
        const dir = segmentDir(a, b) orelse continue;
        const is_last = seg_index == nontrivial - 1;
        seg_index += 1;

        if (prev_dir) |prev| walk.corner(a, prev, dir, is_last);

        var cursor = step(a, dir);
        while (!samePoint(cursor, b)) : (cursor = step(cursor, dir)) {
            walk.straight(cursor, dir, is_last and samePoint(step(cursor, dir), b));
        }

        prev_dir = dir;
    }

    var result = walk.result;
    if (!ends.source and edge.arrow_from != .none) if (result.first) |f| {
        result.source_head = slideHead(lat, pts[0], .{ .cell = f.cell, .dir = reverse(f.dir) });
    };
    if (!ends.target and edge.arrow_to != .none) if (result.last) |l| {
        result.target_head = slideHead(lat, pts[pts.len - 1], l);
    };
    if (!ends.source) drawPortStroke(lat, pts, edge.kind, edge.id, .{ .head = result.source_head, .role = edge.role });
    if (!ends.target) drawTargetPortStroke(lat, pts, edge.kind, edge.id, .{ .head = result.target_head, .role = edge.role });

    return result;
}

fn writeHead(
    lat: *lattice.Lattice,
    edge: sketch.EdgePath,
    arrow: lattice.ArrowKind,
    head: ?Head,
    cells_lost: *u32,
    ctx: crossings.Ctx,
) void {
    const h = head orelse return;
    if (!pointInBounds(h.cell, lat)) return;
    const c = toCoord(h.cell);
    writeArrowGuarded(lat.at(c.x, c.y), edge.id, edge.kind, arrow, h.dir, straightMask(h.dir), c.x, c.y, cells_lost, ctx);
}

pub fn rasterizeEdges(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    subgraph_edges: prim.SubgraphEdges,
) EdgeRasterReport {
    var cells_lost: u32 = 0;
    var cross_counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{
        .sharing = s.sharing,
        .counts = &cross_counts,
        .mode = subgraph_edges,
    };

    for (s.edges) |edge| {
        const r = walkPolyline(lat, edge, railEnds(s, edge), &cells_lost, ctx);
        writeHead(lat, edge, edge.arrow_to, r.target_head, &cells_lost, ctx);
        writeHead(lat, edge, edge.arrow_from, r.source_head, &cells_lost, ctx);
    }

    fan_roles.resolveMasks(lat, s);

    return .{ .cells_lost = cells_lost, .crossings = cross_counts };
}

test {
    _ = @import("edges_test.zig");
    _ = @import("edges_corner_test.zig");
    _ = @import("edges_write_test.zig");
    _ = @import("edges_port_test.zig");
    _ = @import("edges_slide_test.zig");
}
