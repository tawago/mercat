const lattice = @import("../lattice.zig");
const lw = @import("labels_write.zig");
const ink = @import("labels_ink.zig");
const geo = @import("geometry.zig");

pub const Omission = enum { unrouted_host, no_room, no_faithful_place };

pub const Verdict = enum { placed, no_room, no_faithful_place };

pub fn beside(lat: *lattice.Lattice, hosts: []const ink.Host, run: lw.Run, left_of_run: bool) Verdict {
    var refused = false;
    for (hosts) |h| switch (tryHost(lat, run, h, left_of_run)) {
        .placed => return .placed,
        .no_faithful_place => refused = true,
        .no_room => {},
    };
    return if (refused) .no_faithful_place else .no_room;
}

fn tryHost(lat: *lattice.Lattice, run: lw.Run, h: ink.Host, left_of_run: bool) Verdict {
    var refused = false;
    switch (h.axis) {
        .horizontal => {
            for ([2]i32{ h.lo.y - 1, h.lo.y + 1 }) |row| {
                var it = ink.MiddleOut.init(h.lo.x, h.hi.x);
                while (it.next()) |x| switch (tryWrite(lat, run, h, x, row)) {
                    .placed => return .placed,
                    .no_faithful_place => refused = true,
                    .no_room => {},
                };
            }
        },
        .vertical => {
            const right_x: i32 = h.lo.x + 2;
            const left_x: i32 = h.lo.x - 1 - @as(i32, @intCast(run.width));
            const sides = if (left_of_run) [2]i32{ left_x, right_x } else [2]i32{ right_x, left_x };
            for (sides) |x| {
                var it = ink.MiddleOut.init(h.lo.y, h.hi.y);
                while (it.next()) |y| switch (tryWrite(lat, run, h, x, y)) {
                    .placed => return .placed,
                    .no_faithful_place => refused = true,
                    .no_room => {},
                };
            }
        },
    }
    return if (refused) .no_faithful_place else .no_room;
}

fn tryWrite(lat: *lattice.Lattice, run: lw.Run, h: ink.Host, lx: i32, ly: i32) Verdict {
    if (ly < 0 or @as(i64, ly) >= lat.height or lx < 0) return .no_room;
    const cc: i32 = @intCast(run.cell_count);
    if (@as(i64, lx) + cc > lat.width) return .no_room;
    var x = lx;
    while (x < lx + cc) : (x += 1) {
        if (lat.atConst(@intCast(x), @intCast(ly)).occupant != .empty) return .no_room;
    }
    if (h.axis == .vertical) {
        const gap = if (lx > h.lo.x) h.lo.x + 1 else h.lo.x - 1;
        if (ink.relationAt(lat, h, gap, ly) != .none) return .no_room;
    }
    for ([_]i32{ lx - 2, lx - 1, lx + cc, lx + cc + 1 }) |sx| {
        if (ink.relationAt(lat, h, sx, ly) == .label) return .no_room;
    }
    if (!faithful(lat, h, lx, ly, cc)) return .no_faithful_place;
    lw.writeRun(lat, @intCast(lx), @intCast(ly), run);
    return .placed;
}

fn faithful(lat: *const lattice.Lattice, h: ink.Host, sx: i32, row: i32, cc: i32) bool {
    const ex = sx + cc - 1;
    var owned = false;
    switch (h.axis) {
        .horizontal => {
            var x = sx;
            while (x <= ex) : (x += 1) {
                if (!acrossAllows(lat, h, x, h.lo.y, &owned)) return false;
            }
        },
        .vertical => if (!acrossAllows(lat, h, h.lo.x, row, &owned)) return false,
    }
    if (!owned) return false;

    var x = sx;
    while (x <= ex) : (x += 1) {
        if (touches(lat, h, x, row - 1) or touches(lat, h, x, row + 1)) return false;
    }
    if (touches(lat, h, sx - 1, row) or touches(lat, h, ex + 1, row)) return false;

    const host_distance: i32 = if (h.axis == .horizontal) 1 else 2;
    var k: i32 = 1;
    while (k <= host_distance) : (k += 1) {
        var ring: Pull = .none;
        x = sx;
        while (x <= ex) : (x += 1) {
            ring = ring.join(pull(lat, h, x, row - k, .horizontal)).join(pull(lat, h, x, row + k, .horizontal));
        }
        ring = ring.join(pull(lat, h, sx - k, row, .vertical)).join(pull(lat, h, ex + k, row, .vertical));
        switch (ring) {
            .none => {},
            .own => return true,
            .foreign => return false,
        }
    }
    return true;
}

const Pull = enum {
    none,
    own,
    foreign,

    fn join(a: Pull, b: Pull) Pull {
        return @enumFromInt(@max(@intFromEnum(a), @intFromEnum(b)));
    }
};

fn pull(lat: *const lattice.Lattice, h: ink.Host, x: i32, y: i32, axis: ink.Axis) Pull {
    const m = (geo.cellAt(lat, x, y) orelse return .none).neighbours;
    return switch (ink.relationAt(lat, h, x, y)) {
        .private => if (ink.along(m, axis)) .own else .none,
        .foreign_run, .joined => if (ink.along(m, axis) or m.toMask() == 0b1111) .foreign else .none,
        else => .none,
    };
}

fn acrossAllows(lat: *const lattice.Lattice, h: ink.Host, x: i32, y: i32, owned: *bool) bool {
    switch (ink.relationAt(lat, h, x, y)) {
        .joined, .foreign_run, .rail_interior => return false,
        .private => {
            const cell = geo.cellAt(lat, x, y) orelse return true;
            if (ink.along(cell.neighbours, h.axis)) owned.* = true;
        },
        else => {},
    }
    return true;
}

fn touches(lat: *const lattice.Lattice, h: ink.Host, x: i32, y: i32) bool {
    return switch (ink.relationAt(lat, h, x, y)) {
        .foreign_box, .rail_interior => true,
        else => false,
    };
}
