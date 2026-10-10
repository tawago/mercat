const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const lw = @import("labels_write.zig");
const ink = @import("labels_ink.zig");

const Pass = enum { own_adjacent, own_nearest, any, any_solid };
const passes = [4]Pass{ .own_adjacent, .own_nearest, .any, .any_solid };

const OWN_ADJ_RADIUS: u32 = 2;
const OWN_NEAR_RADIUS: u32 = 4;

pub const Omission = enum { unrouted_host, no_room };

pub fn beside(
    lat: *lattice.Lattice,
    hosts: []const ink.Host,
    polyline: []const sketch.Point,
    run: lw.Run,
    left_of_run: bool,
) bool {
    for (passes) |pass| {
        for (hosts) |h| {
            const owner: ink.Owner = .{ .edge_id = h.edge, .polyline = polyline, .seg_a = h.lo, .seg_b = h.hi };
            if (trySegment(lat, run, h, left_of_run, owner, pass)) return true;
        }
    }
    return false;
}

fn trySegment(
    lat: *lattice.Lattice,
    run: lw.Run,
    h: ink.Host,
    left_of_run: bool,
    owner: ink.Owner,
    pass: Pass,
) bool {
    switch (h.axis) {
        .horizontal => {
            for ([2]i32{ h.lo.y - 1, h.lo.y + 1 }) |row| {
                var it = ink.MiddleOut.init(h.lo.x, h.hi.x);
                while (it.next()) |x| {
                    if (tryWrite(lat, run, x, row, owner, pass)) return true;
                }
            }
        },
        .vertical => {
            const right_x: i32 = h.lo.x + 2;
            const left_x: i32 = h.lo.x - 1 - @as(i32, @intCast(run.width));
            const sides = if (left_of_run) [2]i32{ left_x, right_x } else [2]i32{ right_x, left_x };
            for (sides) |x| {
                var it = ink.MiddleOut.init(h.lo.y, h.hi.y);
                while (it.next()) |y| {
                    if (tryWrite(lat, run, x, y, owner, pass)) return true;
                }
            }
        },
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
