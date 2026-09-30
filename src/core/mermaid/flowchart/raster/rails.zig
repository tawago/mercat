const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ew = @import("edges_write.zig");
const ep = @import("edges_port.zig");
const geo = @import("geometry.zig");

/// Cells the rails could not draw.
pub fn rasterizeRails(lat: *lattice.Lattice, s: sketch.Sketch) u32 {
    var lost: u32 = 0;
    for (s.rails) |rail| drawRail(lat, rail, &lost);
    return lost;
}

const RailDraw = struct {
    lat: *lattice.Lattice,
    rail: sketch.Rail,
    lost: *u32,
    fan_in: bool,
    edge: u32,
    crossbar_role: lattice.EdgeRole,
    dropper_role: lattice.EdgeRole,

    fn claim(self: RailDraw, p: sketch.Point, edge_id: u32, role: lattice.EdgeRole, mask: lattice.Neighbours) void {
        if (!geo.pointInBounds(p, self.lat)) return;
        const c = geo.toCoord(p);
        ew.writeEdgeCell(self.lat.at(c.x, c.y), edge_id, self.rail.kind, role, mask, c.x, c.y, self.lost);
    }

    fn claimHead(self: RailDraw, h: ep.Head, edge_id: u32, arrow: lattice.ArrowKind) void {
        if (!geo.pointInBounds(h.cell, self.lat)) return;
        const c = geo.toCoord(h.cell);
        ew.writeArrowCell(self.lat.at(c.x, c.y), edge_id, self.rail.kind, arrow, h.dir, geo.straightMask(h.dir), c.x, c.y, self.lost);
    }

    fn crossbar(self: RailDraw) void {
        const x0 = self.rail.crossbar[0].x;
        const x1 = self.rail.crossbar[1].x;
        const y = self.rail.crossbar[0].y;
        var x = x0;
        while (x <= x1) : (x += 1) {
            self.claim(.{ .x = x, .y = y }, self.edge, self.crossbar_role, .{ .e = x < x1, .w = x > x0 });
        }
    }

    fn stem(self: RailDraw) void {
        const pts = self.rail.stem;
        const junction = pts[pts.len - 1];
        const head = pivotHead(self.rail);
        const end: ep.PortEnd = .{ .head = head, .role = self.crossbar_role };
        if (!self.fan_in) ep.drawPortStroke(self.lat, pts, self.rail.kind, self.edge, end);
        if (self.fan_in and pts.len >= 2) {
            const stub = [_]sketch.Point{ pts[1], pts[0] };
            ep.drawTargetPortStroke(self.lat, &stub, self.rail.kind, self.edge, end);
        }
        var last_dir: ?geo.Move = null;
        for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
            const dir = geo.segmentDir(a, b) orelse continue;
            if (last_dir) |prev| {
                self.claim(a, self.edge, self.crossbar_role, geo.orMask(geo.bitMask(geo.reverse(prev)), geo.bitMask(dir)));
            }
            var cursor = geo.step(a, dir);
            while (!geo.samePoint(cursor, b)) : (cursor = geo.step(cursor, dir)) {
                self.claim(cursor, self.edge, self.crossbar_role, geo.straightMask(dir));
            }
            last_dir = dir;
        }
        if (last_dir) |dir| self.claim(junction, self.edge, self.crossbar_role, geo.bitMask(geo.reverse(dir)));
        if (head) |h| self.claimHead(h, self.edge, self.rail.pivot_arrow);
    }

    fn tap(self: RailDraw, t: sketch.Tap) void {
        const head = if (t.continues) null else tapHead(t, self.fan_in);
        const end: ep.PortEnd = .{ .head = head, .role = self.dropper_role };
        if (!t.continues) {
            if (self.fan_in) {
                const stub = [_]sketch.Point{ t.landing, t.at };
                ep.drawPortStroke(self.lat, &stub, self.rail.kind, t.edge, end);
            } else {
                const stub = [_]sketch.Point{ t.at, t.landing };
                ep.drawTargetPortStroke(self.lat, &stub, self.rail.kind, t.edge, end);
            }
        }
        const dir = geo.segmentDir(t.at, t.landing) orelse return;
        self.claim(t.at, t.edge, self.crossbar_role, geo.bitMask(dir));
        var cursor = geo.step(t.at, dir);
        while (!geo.samePoint(cursor, t.landing)) : (cursor = geo.step(cursor, dir)) {
            self.claim(cursor, t.edge, self.dropper_role, geo.straightMask(dir));
        }
        if (head) |h| self.claimHead(h, t.edge, t.arrow);
    }
};

fn drawRail(lat: *lattice.Lattice, rail: sketch.Rail, lost: *u32) void {
    const fan_in = rail.role == .fan_in_dropper or rail.role == .fan_in_rail;
    const draw: RailDraw = .{
        .lat = lat,
        .rail = rail,
        .lost = lost,
        .fan_in = fan_in,
        .edge = rail.taps[0].edge,
        .crossbar_role = if (fan_in) .fan_in_rail else .fan_out_rail,
        .dropper_role = if (fan_in) .fan_in_dropper else .fan_out_dropper,
    };
    draw.crossbar();
    draw.stem();
    for (rail.taps) |t| draw.tap(t);
}

fn pivotHead(rail: sketch.Rail) ?ep.Head {
    if (rail.pivot_arrow == .none) return null;
    const dir = geo.firstDir(rail.stem) orelse return null;
    return .{ .cell = geo.step(rail.stem[0], dir), .dir = geo.reverse(dir) };
}

fn tapHead(tap: sketch.Tap, fan_in: bool) ?ep.Head {
    if (tap.arrow == .none) return null;
    const dir = geo.segmentDir(tap.at, tap.landing) orelse return null;
    const first = geo.step(tap.at, dir);
    if (geo.samePoint(first, tap.landing)) return null;
    return .{
        .cell = geo.step(tap.landing, geo.reverse(dir)),
        .dir = if (fan_in) geo.reverse(dir) else dir,
    };
}

test {
    _ = @import("rails_test.zig");
}
