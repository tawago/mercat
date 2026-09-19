const std = @import("std");
const fan_mod = @import("fan.zig");

const Fan = fan_mod.Fan;
const FanEdge = fan_mod.FanEdge;
const Direction = fan_mod.Direction;

pub fn wrapWideFanOut(
    comptime G: type,
    fans: []Fan,
    geom: []G,
    budget: u32,
    h_spacing: u32,
    v_spacing: u32,
) void {
    wrapGrid(G, .out, fans, geom, budget, h_spacing, v_spacing);
}

pub fn wrapWideFanIn(
    comptime G: type,
    fans: []Fan,
    geom: []G,
    budget: u32,
    h_spacing: u32,
    v_spacing: u32,
) void {
    wrapGrid(G, .in, fans, geom, budget, h_spacing, v_spacing);
}

fn wrapGrid(
    comptime G: type,
    want: Direction,
    fans: []Fan,
    geom: []G,
    budget: u32,
    h_spacing: u32,
    v_spacing: u32,
) void {
    for (fans) |*f| {
        if (f.direction != want) continue;
        if (f.peers.len < 2) continue;

        const Ctx = struct {
            g: []const G,
            fn lt(c: @This(), a_e: FanEdge, b_e: FanEdge) bool {
                if (c.g[a_e.peer_idx].x != c.g[b_e.peer_idx].x)
                    return c.g[a_e.peer_idx].x < c.g[b_e.peer_idx].x;
                return a_e.edge_id < b_e.edge_id;
            }
        };
        std.mem.sort(FanEdge, f.peers, Ctx{ .g = geom }, Ctx.lt);

        // @guarded-by: fan_grid_test.zig "wrapWideFanIn wrap decision uses the minimal 1-cell fit gap, not h_spacing"
        const fit_gap: u32 = if (want == .in) 1 else h_spacing;
        // @guarded-by: fan_grid_test.zig "wrapWideFanIn floors the placement gap at 3 when h_spacing halves to 2"
        const place_gap: u32 = if (want == .in) @max(h_spacing, 3) else h_spacing;
        var single_row_w: u32 = 0;
        var max_child_w: u32 = 0;
        var max_child_h: u32 = 0;
        for (f.peers, 0..) |p, i| {
            const g = geom[p.peer_idx];
            single_row_w += g.w;
            if (i + 1 < f.peers.len) single_row_w += fit_gap;
            if (g.w > max_child_w) max_child_w = g.w;
            if (g.h > max_child_h) max_child_h = g.h;
        }
        if (single_row_w <= budget) continue;

        const n: u32 = @intCast(f.peers.len);

        // @guarded-by: fan_grid_test.zig "wrapWideFanOut legacy grid centres EACH row independently under the pivot"
        const slot_w = max_child_w + place_gap;
        const legacy_cols: u32 = blk: {
            var lc: u32 = if (slot_w == 0) 1 else (budget + place_gap) / slot_w;
            if (lc == 0) lc = 1;
            break :blk lc;
        };
        if (want == .out and legacy_cols >= 2 and legacy_cols < n) {
            legacyUniformGrid(G, f, geom, legacy_cols, n, max_child_h, place_gap, v_spacing);
            continue;
        }

        // @guarded-by: fan_grid_test.zig "wrapWideFanOut P5 pack finds a 2-column layout the old widest-slot math missed (29/25/25 @ budget 58)"
        const fit_budget: u32 = budget;
        var col_of_buf: [256]u8 = undefined;
        var cols: u32 = 1;
        {
            var try_cols: u32 = @min(n - 1, @as(u32, @intCast(col_of_buf.len)));
            while (try_cols >= 2) : (try_cols -= 1) {
                if (n > col_of_buf.len) break;
                if (packFeasible(G, f.peers, geom, try_cols, place_gap, fit_budget, col_of_buf[0..n])) {
                    cols = try_cols;
                    break;
                }
            }
        }
        // @guarded-by: fan_grid_test.zig "wrapWideFanOut falls back to a single column matching the legacy per-box centering"
        if (cols < 2) {
            cols = 1;
            for (col_of_buf[0..n]) |*c| c.* = 0;
        }

        // @guarded-by: fan_grid_test.zig "wrapWideFanOut falls back to a single column matching the legacy per-box centering"
        const rows: u32 = blk: {
            var max_row: u32 = 0;
            var r: u32 = 0;
            while (r < cols) : (r += 1) {
                var cnt: u32 = 0;
                for (col_of_buf[0..n]) |cc| {
                    if (cc == r) cnt += 1;
                }
                if (cnt > max_row) max_row = cnt;
            }
            break :blk max_row;
        };
        if (rows < 2) continue;

        f.rows = rows;

        const row_step = rowStep(max_child_h, v_spacing);

        const base_y: i32 = geom[f.peers[0].peer_idx].y;
        const added_h: i32 = @as(i32, @intCast(rows - 1)) * row_step;
        for (geom) |*g| {
            if (g.y > base_y) g.y += added_h;
        }

        // @guarded-by: fan_grid_test.zig "wrapWideFanOut variable per-column widths avoid re-overflow from 2 narrow columns"
        var col_w_buf: [256]u32 = undefined;
        const col_w = col_w_buf[0..cols];
        for (col_w) |*w| w.* = 0;
        for (col_of_buf[0..n], 0..) |cc, idx| {
            const cw = geom[f.peers[idx].peer_idx].w;
            if (cw > col_w[cc]) col_w[cc] = cw;
        }
        var block_w: u32 = 0;
        for (col_w, 0..) |w, ci| {
            block_w += w;
            if (ci + 1 < cols) block_w += place_gap;
        }
        const pivot_cx: i32 = geom[f.pivot_idx].x +
            @divTrunc(@as(i32, @intCast(geom[f.pivot_idx].w)), 2);
        const block_left: i32 = pivot_cx - @divTrunc(@as(i32, @intCast(block_w)), 2);

        var col_x_buf: [256]i32 = undefined;
        const col_x = col_x_buf[0..cols];
        {
            var cursor: i32 = block_left;
            for (col_w, 0..) |w, ci| {
                col_x[ci] = cursor;
                cursor += @as(i32, @intCast(w)) + @as(i32, @intCast(place_gap));
            }
        }

        // @guarded-by: fan_grid_test.zig "wrapWideFanIn centres a narrow box on its column's centre, not flush to a wide neighbour"
        var row_fill_buf: [256]u32 = undefined;
        const row_fill = row_fill_buf[0..cols];
        for (row_fill) |*r| r.* = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const cc = col_of_buf[i];
            const row_idx = row_fill[cc];
            row_fill[cc] += 1;
            const peer = f.peers[i];
            const w = geom[peer.peer_idx].w;
            const col_center: i32 = col_x[cc] + @divTrunc(@as(i32, @intCast(col_w[cc])), 2);
            geom[peer.peer_idx].x = col_center - @divTrunc(@as(i32, @intCast(w)), 2);
            geom[peer.peer_idx].y = base_y + @as(i32, @intCast(row_idx)) * row_step;
        }
    }
}

/// @guarded-by: fan_grid_test.zig "a gridded fan keeps three gap rows between its rows at halved spacing"
pub const GRID_GAP_ROWS: i32 = 3;

pub fn rowStep(max_child_h: u32, v_spacing: u32) i32 {
    const gap = @max(@as(i32, @intCast(v_spacing)) + 1, GRID_GAP_ROWS);
    return @as(i32, @intCast(max_child_h)) + gap;
}

fn legacyUniformGrid(
    comptime G: type,
    f: *Fan,
    geom: []G,
    cols: u32,
    n: u32,
    max_child_h: u32,
    gap: u32,
    v_spacing: u32,
) void {
    const rows: u32 = (n + cols - 1) / cols;
    if (rows < 2) return;
    f.rows = rows;

    const row_step = rowStep(max_child_h, v_spacing);

    const base_y: i32 = geom[f.peers[0].peer_idx].y;
    const added_h: i32 = @as(i32, @intCast(rows - 1)) * row_step;
    for (geom) |*g| {
        if (g.y > base_y) g.y += added_h;
    }

    const pivot_cx: i32 = geom[f.pivot_idx].x +
        @divTrunc(@as(i32, @intCast(geom[f.pivot_idx].w)), 2);

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const row_idx = i / cols;
        const row_start = row_idx * cols;
        const row_end = @min(row_start + cols, n);
        const row_count = row_end - row_start;

        var rw: u32 = 0;
        var c: u32 = row_start;
        while (c < row_end) : (c += 1) {
            rw += geom[f.peers[c].peer_idx].w;
            if (c + 1 < row_end) rw += gap;
        }
        const row_left: i32 = pivot_cx - @divTrunc(@as(i32, @intCast(rw)), 2);

        var cursor: i32 = row_left;
        var k: u32 = 0;
        while (k < row_count) : (k += 1) {
            const peer = f.peers[row_start + k];
            geom[peer.peer_idx].x = cursor;
            geom[peer.peer_idx].y = base_y + @as(i32, @intCast(row_idx)) * row_step;
            cursor += @as(i32, @intCast(geom[peer.peer_idx].w)) +
                @as(i32, @intCast(gap));
        }
    }
}

fn packFeasible(
    comptime G: type,
    peers: []const FanEdge,
    geom: []const G,
    cols: u32,
    gap: u32,
    budget: u32,
    col_of: []u8,
) bool {
    for (peers, 0..) |_, i| col_of[i] = @intCast(@as(u32, @intCast(i)) % cols);

    const n: u32 = @intCast(peers.len);
    const rows: u32 = (n + cols - 1) / cols;
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var rw: u32 = 0;
        var occupied: u32 = 0;
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            const idx: u32 = r * cols + c;
            var found_w: ?u32 = null;
            if (idx < n) found_w = geom[peers[idx].peer_idx].w;
            if (found_w) |w| {
                if (occupied > 0) rw += gap;
                rw += w;
                occupied += 1;
            }
        }
        if (rw > budget) return false;
    }
    return true;
}
