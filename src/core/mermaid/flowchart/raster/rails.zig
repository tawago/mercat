const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const edges_r = @import("edges.zig");

/// Cells the rails could not draw.
pub fn rasterizeRails(lat: *lattice.Lattice, s: sketch.Sketch) u32 {
    var lost: u32 = 0;
    for (s.rails) |rail| drawRail(lat, rail, &lost);
    return lost;
}

fn drawRail(lat: *lattice.Lattice, rail: sketch.Rail, lost: *u32) void {
    const crossbar_edge = rail.taps[0].edge;
    const junction = rail.stem[rail.stem.len - 1];
    const fan_in = rail.role == .fan_in_dropper or rail.role == .fan_in_rail;
    const crossbar_role: lattice.EdgeRole = if (fan_in) .fan_in_rail else .fan_out_rail;
    const dropper_role: lattice.EdgeRole = if (fan_in) .fan_in_dropper else .fan_out_dropper;

    const x0 = rail.crossbar[0].x;
    const x1 = rail.crossbar[1].x;
    const rail_y = rail.crossbar[0].y;
    var x = x0;
    while (x <= x1) : (x += 1) {
        const mask: lattice.Neighbours = .{ .e = x < x1, .w = x > x0 };
        claim(lat, .{ .x = x, .y = rail_y }, crossbar_edge, rail.kind, crossbar_role, mask, lost);
    }

    const pivot_head = pivotHead(rail);
    const pivot_end: edges_r.PortEnd = .{ .head = pivot_head, .role = crossbar_role };
    if (!fan_in) edges_r.drawPortStroke(lat, rail.stem, rail.kind, crossbar_edge, pivot_end);
    if (fan_in and rail.stem.len >= 2) {
        const pivot_stub = [_]sketch.Point{ rail.stem[1], rail.stem[0] };
        edges_r.drawTargetPortStroke(lat, &pivot_stub, rail.kind, crossbar_edge, pivot_end);
    }
    var i: usize = 0;
    var last_dir: ?edges_r.Move = null;
    while (i + 1 < rail.stem.len) : (i += 1) {
        const a = rail.stem[i];
        const b = rail.stem[i + 1];
        const dir = edges_r.segmentDir(a, b) orelse continue;
        if (last_dir) |prev| {
            claim(lat, a, crossbar_edge, rail.kind, crossbar_role, edges_r.orMask(edges_r.bitMask(edges_r.reverse(prev)), edges_r.bitMask(dir)), lost);
        }
        var cursor = edges_r.step(a, dir);
        while (cursor.x != b.x or cursor.y != b.y) : (cursor = edges_r.step(cursor, dir)) {
            claim(lat, cursor, crossbar_edge, rail.kind, crossbar_role, edges_r.straightMask(dir), lost);
        }
        last_dir = dir;
    }
    if (last_dir) |dir| {
        claim(lat, junction, crossbar_edge, rail.kind, crossbar_role, edges_r.bitMask(edges_r.reverse(dir)), lost);
    }
    if (pivot_head) |h| {
        if (pivotStemDir(rail)) |dir| {
            if (edges_r.pointInBounds(h.cell, lat)) {
                const c = edges_r.toCoord(h.cell);
                edges_r.writeArrowCell(lat.at(c.x, c.y), crossbar_edge, rail.kind, rail.pivot_arrow, h.dir, edges_r.straightMask(dir), c.x, c.y, lost);
            }
        }
    }

    for (rail.taps) |tap| {
        const tap_head = if (tap.continues) null else tapHead(tap, fan_in);
        const tap_end: edges_r.PortEnd = .{ .head = tap_head, .role = dropper_role };
        if (tap.continues) {} else if (fan_in) {
            const source_stub = [_]sketch.Point{ tap.landing, tap.at };
            edges_r.drawPortStroke(lat, &source_stub, rail.kind, tap.edge, tap_end);
        } else {
            const target_stub = [_]sketch.Point{ tap.at, tap.landing };
            edges_r.drawTargetPortStroke(lat, &target_stub, rail.kind, tap.edge, tap_end);
        }
        const dir = edges_r.segmentDir(tap.at, tap.landing) orelse continue;
        claim(lat, tap.at, tap.edge, rail.kind, crossbar_role, edges_r.bitMask(dir), lost);
        var cursor = edges_r.step(tap.at, dir);
        while (cursor.x != tap.landing.x or cursor.y != tap.landing.y) : (cursor = edges_r.step(cursor, dir)) {
            claim(lat, cursor, tap.edge, rail.kind, dropper_role, edges_r.straightMask(dir), lost);
        }
        if (tap.arrow != .none and !tap.continues) {
            if (tap_head) |h| {
                if (edges_r.pointInBounds(h.cell, lat)) {
                    const c = edges_r.toCoord(h.cell);
                    edges_r.writeArrowCell(lat.at(c.x, c.y), tap.edge, rail.kind, tap.arrow, h.dir, edges_r.straightMask(dir), c.x, c.y, lost);
                }
            }
        }
    }
}

fn pivotStemDir(rail: sketch.Rail) ?edges_r.Move {
    var si: usize = 0;
    while (si + 1 < rail.stem.len) : (si += 1) {
        if (edges_r.segmentDir(rail.stem[si], rail.stem[si + 1])) |d| return d;
    }
    return null;
}

fn pivotHead(rail: sketch.Rail) ?edges_r.Head {
    if (rail.pivot_arrow == .none) return null;
    const dir = pivotStemDir(rail) orelse return null;
    return .{ .cell = edges_r.step(rail.stem[0], dir), .dir = edges_r.reverse(dir) };
}

fn tapHead(tap: sketch.Tap, fan_in: bool) ?edges_r.Head {
    if (tap.arrow == .none) return null;
    const dir = edges_r.segmentDir(tap.at, tap.landing) orelse return null;
    const first = edges_r.step(tap.at, dir);
    if (first.x == tap.landing.x and first.y == tap.landing.y) return null;
    return .{
        .cell = edges_r.step(tap.landing, edges_r.reverse(dir)),
        .dir = if (fan_in) edges_r.reverse(dir) else dir,
    };
}

fn claim(
    lat: *lattice.Lattice,
    p: sketch.Point,
    edge_id: u32,
    kind: lattice.EdgeKind,
    role: lattice.EdgeRole,
    mask: lattice.Neighbours,
    lost: *u32,
) void {
    if (!edges_r.pointInBounds(p, lat)) return;
    const c = edges_r.toCoord(p);
    edges_r.writeEdgeCell(lat.at(c.x, c.y), edge_id, kind, role, mask, c.x, c.y, lost);
}

test {
    _ = @import("rails_test.zig");
}
