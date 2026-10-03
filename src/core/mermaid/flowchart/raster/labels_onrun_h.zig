const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const lw = @import("labels_write.zig");
const ink = @import("labels_ink.zig");
const cover = @import("labels_cover.zig");
const geo = @import("geometry.zig");

const MAX_SEGS: usize = 32;

pub fn longestHorizontalInterior(polyline: []const sketch.Point) u32 {
    if (polyline.len < 2) return 0;
    var best: u32 = 0;
    for (polyline[0 .. polyline.len - 1], 0..) |p, i| {
        const q = polyline[i + 1];
        if (p.y != q.y or p.x == q.x) continue;
        const span: u32 = @intCast(@max(p.x, q.x) - @min(p.x, q.x));
        if (span < 1) continue;
        const interior: u32 = span - 1;
        if (interior > best) best = interior;
    }
    return best;
}

pub fn tryOnRunEdgeH(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    ep: sketch.EdgePath,
    run: lw.Run,
) bool {
    if (ep.polyline.len < 2) return false;
    if (run.cell_count == 0) return false;

    var tried = [_]bool{false} ** MAX_SEGS;
    const nsegs = @min(ep.polyline.len - 1, MAX_SEGS);

    var k: usize = 0;
    while (k < nsegs) : (k += 1) {
        var pick: ?usize = null;
        var pick_len: i32 = -1;
        var i: usize = 0;
        while (i < nsegs) : (i += 1) {
            if (tried[i]) continue;
            const p = ep.polyline[i];
            const q = ep.polyline[i + 1];
            if (p.y != q.y or p.x == q.x) continue;
            const len: i32 = @max(p.x, q.x) - @min(p.x, q.x) - 1;
            if (len > pick_len) {
                pick_len = len;
                pick = i;
            }
        }
        const idx = pick orelse return false;
        tried[idx] = true;
        const p = ep.polyline[idx];
        const q = ep.polyline[idx + 1];
        const owner: ink.Owner = .{ .edge_id = ep.id, .polyline = ep.polyline, .seg_a = p, .seg_b = q };
        if (tryRunH(lat, s, ep.id, p.y, @min(p.x, q.x) + 1, @max(p.x, q.x) - 1, run, owner)) return true;
    }
    return false;
}

fn tryRunH(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    edge_id: u32,
    row: i32,
    x_lo: i32,
    x_hi: i32,
    run: lw.Run,
    owner: ink.Owner,
) bool {
    const cc: i32 = @intCast(run.cell_count);
    if (x_hi - x_lo + 1 < cc + 2) return false;
    const start_lo: i32 = x_lo + 1;
    const start_hi: i32 = x_hi - cc;
    const mid: i32 = @divTrunc(start_lo + start_hi, 2);
    var d: i32 = 0;
    while (mid - d >= start_lo or mid + d <= start_hi) : (d += 1) {
        if (mid - d >= start_lo and tryAtH(lat, s, edge_id, mid - d, row, run, owner)) return true;
        if (d > 0 and mid + d <= start_hi and tryAtH(lat, s, edge_id, mid + d, row, run, owner)) return true;
    }
    return false;
}

fn tryAtH(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    edge_id: u32,
    start_x: i32,
    row: i32,
    run: lw.Run,
    owner: ink.Owner,
) bool {
    const cell_count = run.cell_count;
    const cc: i32 = @intCast(cell_count);
    if (row < 0 or @as(i64, row) >= lat.height) return false;
    if (start_x < 1) return false;
    const sx: u32 = @intCast(start_x);
    const urow: u32 = @intCast(row);
    if (sx + cell_count >= lat.width) return false;

    var i: i32 = 0;
    while (i < cc) : (i += 1) {
        const cx = start_x + i;
        if (!ink.plainRunCell(lat, edge_id, cx, row, .horizontal)) return false;
        if (cover.coveredByOther(s, edge_id, cx, row)) return false;
    }

    if (!ink.plainRunCell(lat, edge_id, start_x - 1, row, .horizontal)) return false;
    if (!ink.plainRunCell(lat, edge_id, start_x + cc, row, .horizontal)) return false;
    if (cover.coveredByOther(s, edge_id, start_x - 1, row)) return false;
    if (cover.coveredByOther(s, edge_id, start_x + cc, row)) return false;

    if (!visualRunIsPrivate(lat, s, edge_id, start_x, row, cc)) return false;

    if (!ink.spanIsolated(lat, owner, start_x, row, cell_count, false)) return false;

    var j: i32 = 0;
    while (j < cc) : (j += 1) std.debug.assert(ink.plainRunCell(lat, edge_id, start_x + j, row, .horizontal));

    lw.writeRun(lat, sx, urow, run);
    return true;
}

fn visualRunIsPrivate(
    lat: *const lattice.Lattice,
    s: sketch.Sketch,
    edge_id: u32,
    start_x: i32,
    row: i32,
    cc: i32,
) bool {
    for ([2]i32{ -1, 1 }) |dir| {
        var x: i32 = if (dir < 0) start_x - 1 else start_x + cc;
        while (geo.cellAt(lat, x, row)) |cell| : (x += dir) {
            const owner: u32 = switch (cell.occupant) {
                .edge_segment => |seg| seg.edge,
                .arrowhead => |ah| ah.edge,
                else => break,
            };
            if (owner != edge_id) return false;
            if (cover.coveredByOther(s, edge_id, x, row)) return false;
        }
    }
    return true;
}

test {
    _ = @import("labels_onrun_h_test.zig");
}
