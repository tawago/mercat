const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ew = @import("edges_write.zig");
const geo = @import("geometry.zig");

const Move = geo.Move;
const step = geo.step;
const reverse = geo.reverse;
const bitMask = geo.bitMask;
const orMask = geo.orMask;
const straightMask = geo.straightMask;
const toCoord = geo.toCoord;
const samePoint = geo.samePoint;
const writeEdgeCell = ew.writeEdgeCell;

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

test {
    _ = @import("edges_port_test.zig");
    _ = @import("edges_slide_test.zig");
}
