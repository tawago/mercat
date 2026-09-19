const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ew = @import("edges_write.zig");
const aux = @import("aux.zig");
const crossings = @import("crossings.zig");

const Move = ew.Move;
const step = ew.step;
const reverse = ew.reverse;
const bitMask = ew.bitMask;
const orMask = ew.orMask;
const straightMask = ew.straightMask;
const segmentDir = ew.segmentDir;
const toCoord = ew.toCoord;
const pointInBounds = ew.pointInBounds;
const writeEdgeCell = ew.writeEdgeCell;

pub const Head = struct {
    cell: sketch.Point,
    dir: Move,
};

pub const PortEnd = struct {
    head: ?Head = null,
    role: lattice.EdgeRole = .forward,
};

/// @guarded-by: edges_port_test.zig "a decorated source end whose head faces the wall leaves it pristine"
/// @guarded-by: edges_port_test.zig "drawPortStroke: an invisible edge leaves the source node border untouched"
/// @guarded-by: aux_test.zig "drawPortStroke files a port record only for a stroke it actually draws"
pub fn drawPortStroke(
    lat: *lattice.Lattice,
    pts: []const sketch.Point,
    kind: lattice.EdgeKind,
    edge_id: u32,
    end: PortEnd,
    sink: aux.Sink,
) void {
    if (kind == .invisible) return;
    var first_dir_opt: ?Move = null;
    var fi: usize = 0;
    while (fi + 1 < pts.len) : (fi += 1) {
        if (segmentDir(pts[fi], pts[fi + 1])) |fd| {
            first_dir_opt = fd;
            break;
        }
    }
    const fd = first_dir_opt orelse return;
    mergePortBit(lat, pts[0], fd, kind, edge_id, end, sink);
}

/// @guarded-by: edges_port_test.zig "drawTargetPortStroke: arrival arms merge on all four faces"
/// @guarded-by: edges_port_test.zig "a decorated arrival whose head faces the wall leaves it pristine"
/// @guarded-by: edges_port_test.zig "a head adjacent to the wall but pointing ALONG the route still tees it"
pub fn drawTargetPortStroke(
    lat: *lattice.Lattice,
    pts: []const sketch.Point,
    kind: lattice.EdgeKind,
    edge_id: u32,
    end: PortEnd,
    sink: aux.Sink,
) void {
    if (kind == .invisible) return;
    var last_dir_opt: ?Move = null;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        if (segmentDir(pts[i], pts[i + 1])) |d| last_dir_opt = d;
    }
    const ld = last_dir_opt orelse return;
    mergePortBit(lat, pts[pts.len - 1], reverse(ld), kind, edge_id, end, sink);
}

fn samePoint(a: sketch.Point, b: sketch.Point) bool {
    return a.x == b.x and a.y == b.y;
}

/// @guarded-by: edges_port_test.zig "a head adjacent to the wall but pointing ALONG the route still tees it"
fn tipFaces(h: Head, q: sketch.Point) bool {
    return samePoint(step(h.cell, h.dir), q);
}

const Attach = struct { border: sketch.Point, gap: ?sketch.Point };

fn attachment(lat: *const lattice.Lattice, p: sketch.Point, travel: Move) ?Attach {
    if (!pointInBounds(p, lat)) return null;
    var q = p;
    var gap: ?sketch.Point = null;
    if (lat.atConst(toCoord(q).x, toCoord(q).y).occupant == .empty) {
        gap = q;
        q = step(q, travel);
        if (!pointInBounds(q, lat)) return null;
    }
    const c = toCoord(q);
    const cell = lat.atConst(c.x, c.y);
    if (cell.occupant != .node_border) return null;
    switch (cell.occupant.node_border.role) {
        .corner_nw, .corner_ne, .corner_se, .corner_sw => return null,
        else => {},
    }
    return .{ .border = q, .gap = gap };
}

/// @guarded-by: edges_slide_test.zig "a decorated gap arrival slides its head onto the border-adjacent cell"
/// @guarded-by: edges_slide_test.zig "an occupied gap cell leaves the head where it is"
pub fn slideHead(lat: *const lattice.Lattice, endpoint: sketch.Point, head: Head) Head {
    const at = attachment(lat, endpoint, head.dir) orelse return head;
    const g = at.gap orelse return head;
    if (!samePoint(step(head.cell, head.dir), g)) return head;
    return .{ .cell = g, .dir = head.dir };
}

/// @guarded-by: edges_port_test.zig "a head adjacent to the wall but pointing ALONG the route still tees it"
/// @guarded-by: edges_port_test.zig "an UNDECORATED gap arrival also gets tee, painted gap and run"
/// @guarded-by: edges_slide_test.zig "a decorated gap arrival slides its head onto the border-adjacent cell"
fn mergePortBit(
    lat: *lattice.Lattice,
    p: sketch.Point,
    arm: Move,
    kind: lattice.EdgeKind,
    edge_id: u32,
    end: PortEnd,
    sink: aux.Sink,
) void {
    // @guarded-by: edges_port_test.zig "a gap arrival merges its port bit across the 1-cell reprieve"
    // @guarded-by: edges_port_test.zig "a corner landing is refused: no merge, no record"
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
    aux.record(sink, lat.cellIndex(c.x, c.y), .port, edge_id, lattice.portArmDetail(arm));

    if (gap) |g| {
        const gc = toCoord(g);
        // @guarded-by: edges_port_test.zig "painting the gap cell costs no lost cells"
        var lost: u32 = 0;
        var counts: crossings.CrossingCounts = .{};
        writeEdgeCell(
            lat.at(gc.x, gc.y),
            edge_id,
            kind,
            end.role,
            straightMask(arm),
            gc.x,
            gc.y,
            &lost,
            &counts,
            .merged_untested,
            aux.Recorder.init(sink, lat),
        );
        std.debug.assert(lost == 0);
    }
}

test {
    _ = @import("edges_port_test.zig");
    _ = @import("edges_slide_test.zig");
}
