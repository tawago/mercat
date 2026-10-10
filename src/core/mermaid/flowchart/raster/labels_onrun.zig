const lattice = @import("../lattice.zig");
const lw = @import("labels_write.zig");
const ink = @import("labels_ink.zig");
const geo = @import("geometry.zig");

pub fn tryOnRun(lat: *lattice.Lattice, h: ink.Host, run: lw.Run) bool {
    if (run.cell_count == 0) return false;
    const cc: i32 = @intCast(run.cell_count);
    const lo: i32, const hi: i32 = switch (h.axis) {
        .vertical => .{ h.lo.y + 1, h.hi.y - 1 },
        .horizontal => .{ h.lo.x + 2, h.hi.x - 1 - cc },
    };
    if (lo > hi) return false;
    var it = ink.MiddleOut.init(lo, hi);
    while (it.next()) |t| {
        if (tryAt(lat, h, t, run)) return true;
    }
    return false;
}

fn tryAt(lat: *lattice.Lattice, h: ink.Host, t: i32, run: lw.Run) bool {
    const cc: i32 = @intCast(run.cell_count);
    const w: i64 = lat.width;
    switch (h.axis) {
        .vertical => {
            const x = h.lo.x;
            if (!privateRun(lat, h, x, t)) return false;
            if (!privateRun(lat, h, x, t - 1) or !privateRun(lat, h, x, t + 1)) return false;
            const start_x = x - @divTrunc(cc - 1, 2);
            if (start_x < 0 or start_x + cc > w) return false;
            var cx = start_x;
            while (cx < start_x + cc) : (cx += 1) {
                if (cx != x and lat.atConst(@intCast(cx), @intCast(t)).occupant != .empty) return false;
            }
            if (!stretchClear(lat, h, x, t - 1, 0, -1) or !stretchClear(lat, h, x, t + 1, 0, 1)) return false;
            return place(lat, h, start_x, t, run);
        },
        .horizontal => {
            const y = h.lo.y;
            if (t < 1 or t + cc >= w) return false;
            var cx = t - 1;
            while (cx <= t + cc) : (cx += 1) {
                if (!privateRun(lat, h, cx, y)) return false;
            }
            if (!stretchClear(lat, h, t - 1, y, -1, 0) or !stretchClear(lat, h, t + cc, y, 1, 0)) return false;
            return place(lat, h, t, y, run);
        },
    }
}

fn place(lat: *lattice.Lattice, h: ink.Host, start_x: i32, row: i32, run: lw.Run) bool {
    const cc: i32 = @intCast(run.cell_count);
    var cx = start_x;
    while (cx < start_x + cc) : (cx += 1) {
        if (touchesBox(lat, h, cx, row - 1) or touchesBox(lat, h, cx, row + 1)) return false;
    }
    for ([_]i32{ start_x - 3, start_x - 2, start_x - 1, start_x + cc, start_x + cc + 1, start_x + cc + 2 }, 0..) |lx, i| {
        if (touchesBox(lat, h, lx, row)) return false;
        if (i != 0 and i != 5 and ink.relationAt(lat, h, lx, row) == .label) return false;
    }
    lw.writeRun(lat, @intCast(start_x), @intCast(row), run);
    return true;
}

fn privateRun(lat: *const lattice.Lattice, h: ink.Host, x: i32, y: i32) bool {
    const cell = geo.cellAt(lat, x, y) orelse return false;
    return ink.relationAt(lat, h, x, y) == .private and ink.along(cell.neighbours, h.axis);
}

fn touchesBox(lat: *const lattice.Lattice, h: ink.Host, x: i32, y: i32) bool {
    return switch (ink.relationAt(lat, h, x, y)) {
        .foreign_box, .frame => true,
        else => false,
    };
}

fn stretchClear(lat: *const lattice.Lattice, h: ink.Host, x0: i32, y0: i32, dx: i32, dy: i32) bool {
    var x = x0;
    var y = y0;
    while (geo.cellAt(lat, x, y)) |cell| : ({
        x += dx;
        y += dy;
    }) {
        if (cell.occupant != .edge_segment) return true;
        const rel = ink.relationAt(lat, h, x, y);
        if (rel == .piercing) continue;
        if (rel == .rail_interior) return true;
        if (@popCount(cell.neighbours.toMask()) >= 3 or !ink.along(cell.neighbours, h.axis)) return true;
        if (rel != .private) return false;
    }
    return true;
}

test {
    _ = @import("labels_onrun_test.zig");
    _ = @import("labels_onrun_h_test.zig");
}
