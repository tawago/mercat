const prim = @import("prim");
const sketch = @import("../sketch.zig");
const fan_rail = @import("fan_rail.zig");

pub fn computeBbox(
    placements: []sketch.NodePlacement,
    edges: []sketch.EdgePath,
    polylines: [][]sketch.Point,
    rails: []fan_rail.Built,
    pressure: bool,
    max_width: u32,
) sketch.Rect {
    if (placements.len == 0) {
        return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }
    var min_x: i32 = placements[0].rect.x;
    var min_y: i32 = placements[0].rect.y;
    var max_x: i32 = placements[0].rect.right();
    var max_y: i32 = placements[0].rect.bottom();
    for (placements) |p| {
        if (p.rect.x < min_x) min_x = p.rect.x;
        if (p.rect.y < min_y) min_y = p.rect.y;
        if (p.rect.right() > max_x) max_x = p.rect.right();
        if (p.rect.bottom() > max_y) max_y = p.rect.bottom();
    }
    for (edges) |e| {
        for (e.polyline) |pt| {
            if (pt.x < min_x) min_x = pt.x;
            if (pt.y < min_y) min_y = pt.y;
            if (pt.x + 1 > max_x) max_x = pt.x + 1;
            if (pt.y + 1 > max_y) max_y = pt.y + 1;
        }
        const relocatable = pressure and e.role == .back_edge;
        if (relocatable) continue;
        if (labelFootprint(e, false, max_width, 0)) |fp| {
            if (fp.lx < min_x) min_x = fp.lx;
            if (fp.ly < min_y) min_y = fp.ly;
            if (fp.lend_x > max_x) max_x = fp.lend_x;
            if (fp.ly + 1 > max_y) max_y = fp.ly + 1;
        }
    }
    for (rails) |b| {
        const rail = b.rail;
        for (rail.stem) |pt| extendPoint(&min_x, &min_y, &max_x, &max_y, pt);
        extendPoint(&min_x, &min_y, &max_x, &max_y, rail.crossbar[0]);
        extendPoint(&min_x, &min_y, &max_x, &max_y, rail.crossbar[1]);
        for (rail.taps) |tap| {
            extendPoint(&min_x, &min_y, &max_x, &max_y, tap.at);
            extendPoint(&min_x, &min_y, &max_x, &max_y, tap.landing);
            const lbl = tap.label orelse continue;
            if (lbl.len == 0) continue;
            const seg = rail.tapLabelSeg(tap);
            const lbl_w = prim.displayWidth(lbl);
            const anchor = prim.edgeLabelAnchor(seg[0].x, seg[0].y, seg[1].x, seg[1].y, lbl_w, .{});
            if (anchor.x < min_x) min_x = anchor.x;
            if (anchor.y < min_y) min_y = anchor.y;
            if (anchor.x + @as(i32, @intCast(lbl_w)) > max_x) max_x = anchor.x + @as(i32, @intCast(lbl_w));
            if (anchor.y + 1 > max_y) max_y = anchor.y + 1;
        }
    }

    for (edges) |*e| {
        if (!(pressure and e.role == .back_edge)) continue;
        if (labelFootprint(e.*, true, max_width, max_x)) |fp| {
            e.label_left_of_run = fp.left_of_run;
            if (fp.lx < min_x) min_x = fp.lx;
            if (fp.ly < min_y) min_y = fp.ly;
            if (fp.lend_x > max_x) max_x = fp.lend_x;
            if (fp.ly + 1 > max_y) max_y = fp.ly + 1;
        }
    }

    const dx: i32 = -min_x;
    const dy: i32 = -min_y;
    if (dx != 0 or dy != 0) {
        shiftAll(placements, polylines, rails, dx, dy);
    }

    return .{
        .x = 0,
        .y = 0,
        .w = @intCast(max_x - min_x),
        .h = @intCast(max_y - min_y),
    };
}

fn shiftAll(
    placements: []sketch.NodePlacement,
    polylines: [][]sketch.Point,
    rails: []fan_rail.Built,
    dx: i32,
    dy: i32,
) void {
    for (placements) |*p| {
        p.rect.x += dx;
        p.rect.y += dy;
    }
    for (polylines) |pts| {
        for (pts) |*pt| {
            pt.x += dx;
            pt.y += dy;
        }
    }
    for (rails) |*b| {
        for (&b.rail.crossbar) |*pt| {
            pt.x += dx;
            pt.y += dy;
        }
        for (b.taps) |*tap| {
            tap.at.x += dx;
            tap.at.y += dy;
            tap.landing.x += dx;
            tap.landing.y += dy;
        }
    }
}

fn extendPoint(min_x: *i32, min_y: *i32, max_x: *i32, max_y: *i32, pt: sketch.Point) void {
    if (pt.x < min_x.*) min_x.* = pt.x;
    if (pt.y < min_y.*) min_y.* = pt.y;
    if (pt.x + 1 > max_x.*) max_x.* = pt.x + 1;
    if (pt.y + 1 > max_y.*) max_y.* = pt.y + 1;
}

const LabelFootprint = struct {
    lx: i32,
    ly: i32,
    lend_x: i32,
    left_of_run: bool,
};

fn labelFootprint(
    e: sketch.EdgePath,
    back_ctx: bool,
    max_width: u32,
    others_right: i32,
) ?LabelFootprint {
    const lbl = e.label orelse return null;
    if (lbl.len == 0 or e.polyline.len < 2) return null;
    const seg = pickMidSegmentBbox(e.polyline) orelse return null;
    const lbl_w = prim.displayWidth(lbl);
    const ctx: prim.BackRailCtx = if (back_ctx) .{
        .active = true,
        .max_width = max_width,
        .others_right = others_right,
    } else .{};
    const anchor = prim.edgeLabelAnchor(seg.a.x, seg.a.y, seg.b.x, seg.b.y, lbl_w, ctx);
    const mid_x: i32 = @divTrunc(seg.a.x + seg.b.x, 2);
    return .{
        .lx = anchor.x,
        .ly = anchor.y,
        .lend_x = anchor.x + @as(i32, @intCast(lbl_w)),
        .left_of_run = anchor.x < mid_x + 2,
    };
}

const SegPair = struct { a: sketch.Point, b: sketch.Point };

fn pickMidSegmentBbox(poly: []const sketch.Point) ?SegPair {
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

test {
    _ = @import("clusters_test.zig");
}
