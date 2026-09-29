const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const lw = @import("labels_write.zig");
const ink = @import("labels_ink.zig");

const log = std.log.scoped(.@"mermaid_v2.raster.labels");

const Pass = enum { own_adjacent, own_nearest, any, any_solid };
const passes = [4]Pass{ .own_adjacent, .own_nearest, .any, .any_solid };

const OWN_ADJ_RADIUS: u32 = 2;
const OWN_NEAR_RADIUS: u32 = 4;

pub const SegPair = struct { a: sketch.Point, b: sketch.Point };

pub fn pickMidSegment(poly: []const sketch.Point) ?SegPair {
    var count: usize = 0;
    for (poly[0 .. poly.len - 1], 0..) |p, i| {
        const q = poly[i + 1];
        if (p.x != q.x or p.y != q.y) count += 1;
    }
    if (count == 0) return null;
    const target = count / 2;
    var seen: usize = 0;
    for (poly[0 .. poly.len - 1], 0..) |p, i| {
        const q = poly[i + 1];
        if (p.x == q.x and p.y == q.y) continue;
        if (seen == target) return .{ .a = p, .b = q };
        seen += 1;
    }
    return null;
}

pub const Placement = enum { at_anchor, displaced, dropped };

pub fn placeEdgeLabel(
    lat: *lattice.Lattice,
    ep: sketch.EdgePath,
    run: lw.Run,
) Placement {
    if (ep.polyline.len < 2) return .dropped;

    const seg_pair = pickMidSegment(ep.polyline) orelse return .dropped;
    return placeLabelAtSeg(lat, ep.id, run, seg_pair.a, seg_pair.b, ep.label_left_of_run, ep.polyline);
}

pub fn placeLabelAtSeg(
    lat: *lattice.Lattice,
    edge_id: u32,
    run: lw.Run,
    a: sketch.Point,
    b: sketch.Point,
    left_of_run: bool,
    polyline: []const sketch.Point,
) Placement {
    const owner: ink.Owner = .{ .edge_id = edge_id, .polyline = polyline, .seg_a = a, .seg_b = b };

    const anchor = anchorFor(a, b, left_of_run, run.width);
    for (passes) |pass| {
        if (tryWrite(lat, run, anchor.x, anchor.y, owner, pass)) return .at_anchor;

        if (trySegment(lat, run, a, b, left_of_run, owner, pass)) return .displaced;

        if (polyline.len >= 2) {
            for (polyline[0 .. polyline.len - 1], 0..) |p, i| {
                const q = polyline[i + 1];
                if (p.x == q.x and p.y == q.y) continue;
                if (p.x == a.x and p.y == a.y and q.x == b.x and q.y == b.y) continue;
                if (trySegment(lat, run, p, q, left_of_run, owner, pass)) return .displaced;
            }
        }
    }

    log.debug(
        "raster/labels: edge {d} has no space for label (len={d}); skipping",
        .{ edge_id, run.width },
    );
    return .dropped;
}

fn anchorFor(a: sketch.Point, b: sketch.Point, left_of_run: bool, label_w: u32) prim.LabelAnchor {
    return if (left_of_run)
        prim.leftOfRailAnchor(a.x, a.y, b.x, b.y, label_w)
    else
        prim.edgeLabelAnchor(a.x, a.y, b.x, b.y, label_w, .{});
}

fn trySegment(
    lat: *lattice.Lattice,
    run: lw.Run,
    a: sketch.Point,
    b: sketch.Point,
    left_of_run: bool,
    owner: ink.Owner,
    pass: Pass,
) bool {
    const orig_len: u32 = run.width;

    if (a.y == b.y) {
        const mid_x: i32 = @divTrunc(a.x + b.x, 2);
        const min_x = @min(a.x, b.x);
        const max_x = @max(a.x, b.x);
        const rows = [2]i32{ a.y - 1, a.y + 1 };
        for (rows) |row| {
            var d: i32 = 0;
            while (mid_x - d >= min_x or mid_x + d <= max_x) : (d += 1) {
                if (mid_x - d >= min_x and tryWrite(lat, run, mid_x - d, row, owner, pass)) return true;
                if (d > 0 and mid_x + d <= max_x and tryWrite(lat, run, mid_x + d, row, owner, pass)) return true;
            }
        }
        return false;
    }

    const mid_x: i32 = @divTrunc(a.x + b.x, 2);
    const mid_y: i32 = @divTrunc(a.y + b.y, 2);
    const min_y = @min(a.y, b.y);
    const max_y = @max(a.y, b.y);
    const right_x: i32 = mid_x + 2;
    const left_x: i32 = mid_x - 1 - @as(i32, @intCast(orig_len));
    const sides = if (left_of_run) [2]i32{ left_x, right_x } else [2]i32{ right_x, left_x };
    for (sides) |x| {
        var d: i32 = 0;
        while (mid_y - d >= min_y or mid_y + d <= max_y) : (d += 1) {
            if (mid_y - d >= min_y and tryWrite(lat, run, x, mid_y - d, owner, pass)) return true;
            if (d > 0 and mid_y + d <= max_y and tryWrite(lat, run, x, mid_y + d, owner, pass)) return true;
        }
    }
    return false;
}

fn passAllows(
    lat: *const lattice.Lattice,
    owner: ink.Owner,
    pass: Pass,
    start_x: i32,
    row: i32,
    cell_count: u32,
) bool {
    if (pass == .any or pass == .any_solid) return true;
    const d = ink.inkDistances(lat, owner, start_x, row, cell_count, OWN_NEAR_RADIUS);
    const own = d.own orelse return false;
    const limit: u32 = if (pass == .own_adjacent) OWN_ADJ_RADIUS else OWN_NEAR_RADIUS;
    if (own > limit) return false;
    if (d.foreign_edge) |f| {
        if (own >= f) return false;
    }
    return true;
}

fn tryWrite(
    lat: *lattice.Lattice,
    run: lw.Run,
    lx: i32,
    ly: i32,
    owner: ink.Owner,
    pass: Pass,
) bool {
    if (ly < 0 or @as(i64, ly) >= lat.height) return false;
    if (lx < 0) return false;
    const cell_count = run.cell_count;
    const start_x: u32 = @intCast(lx);
    const row: u32 = @intCast(ly);
    if (start_x + cell_count > lat.width) return false;

    if (!ink.spanIsolated(lat, owner, lx, ly, cell_count, pass == .any_solid)) return false;

    var i: u32 = 0;
    while (i < cell_count) : (i += 1) {
        const cell = lat.atConst(start_x + i, row);
        switch (cell.occupant) {
            .empty => {},
            else => return false,
        }
    }

    if (!passAllows(lat, owner, pass, lx, ly, cell_count)) return false;

    lw.writeRun(lat, start_x, row, run);
    return true;
}
