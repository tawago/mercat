//! Wide fan grid wrapping for `fan.zig`: when a fan's peers would exceed the
//! canvas width budget as a single row, reflow them into a compact grid
//! (`cols` peers per row, stacked downward). The pivot keeps its column;
//! nodes below the gridded row are pushed down to make room.
//!
//! Shared by both fan directions: fan-OUT grids the child row below the
//! pivot; fan-IN grids the source row above the pivot and pushes the pivot
//! down too, preserving top-down flow direction. Only the fan-direction
//! filter and rail polyline (`fan.buildPolyline`) differ; the geometry
//! transform is identical. Generic over `G: type` exposing `x/y: i32,
//! w/h: u32`. Imports: only `std`, `fan.zig`.

const std = @import("std");
const fan_mod = @import("fan.zig");

const Fan = fan_mod.Fan;
const FanEdge = fan_mod.FanEdge;
const Direction = fan_mod.Direction;

/// Wrap any fan-OUT whose children, laid out as a single row, would
/// exceed `budget` cells of width, into a stacked grid. Thin wrapper over
/// the shared `wrapGrid` core. Mutates `geom` and sets `fan.rows`.
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

/// Wrap any flat fan-IN whose sources, laid out as a single row, would
/// exceed `budget` cells of width, into a stacked grid above the shared
/// target — keeping the diagram top-down so the budget ladder never has to
/// rotate it. Thin wrapper over the shared `wrapGrid` core.
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

/// Shared grid-pack core. `want` selects which fan direction to process; the
/// geometry is identical for both (see module doc). For fan-OUT the gridded
/// row is the children (`base_y` < pivot y); for fan-IN it is the sources
/// (`base_y` < target/pivot y, so the pivot itself is pushed down).
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

        // Single-row span = sum(peer widths) + gaps between them. fan-OUT
        // keeps `h_spacing`; fan-IN uses the minimal 1-cell gap so it wraps
        // only when irreducibly too wide. guarded-by: fan_grid_test.zig "wrapWideFanIn wrap decision uses the minimal 1-cell fit gap, not h_spacing"
        const fit_gap: u32 = if (want == .in) 1 else h_spacing;
        // Placement gap: fan-IN floors at 3 so its shared vertical trunk
        // (routed between the two centre columns) clears box walls even when
        // `h_spacing` halves to 2 under pressure. guarded-by: fan_grid_test.zig "wrapWideFanIn floors the placement gap at 3 when h_spacing halves to 2"
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
        if (single_row_w <= budget) continue; // fits — leave classic fan.

        const n: u32 = @intCast(f.peers.len);

        // LEGACY column formula (the historical uniform-widest-slot math), used
        // ONLY as a GATE: when it already yields a real grid (`legacy_cols >=
        // 2`) we reproduce the original per-row-centred layout via
        // `legacyUniformGrid`. Fan-IN never had a legacy path (gated by
        // `want == .out`). guarded-by: fan_grid_test.zig "wrapWideFanOut legacy grid centres EACH row independently under the pivot"
        const slot_w = max_child_w + place_gap;
        const legacy_cols: u32 = blk: {
            var lc: u32 = if (slot_w == 0) 1 else (budget + place_gap) / slot_w;
            if (lc == 0) lc = 1;
            break :blk lc;
        };
        if (want == .out and legacy_cols >= 2 and legacy_cols < n) {
            // The uniform-slot grid is feasible. Reproduce the original layout
            // exactly so previously-good fan-OUT grids stay byte-identical.
            legacyUniformGrid(G, f, geom, legacy_cols, n, max_child_h, place_gap, v_spacing);
            continue;
        }

        // Column count (P5): pick the LARGEST feasible `cols` (2..n-1) such
        // that, when the n children are distributed row-major (reading order)
        // into `cols` columns, the widest resulting ROW — summed from the ACTUAL
        // widths of the children that land in it plus inter-column `place_gap`s
        // — fits the budget. LARGEST feasible is the fewest-grid-rows choice
        // (rows = ceil(n / cols)), so the grid is as SHORT as possible; this is
        // what makes a wider budget (w90) pack more columns and stay short,
        // instead of over-stacking into a tall narrow grid. It also escapes the
        // old bug where the uniform widest-slot math forced `cols` to 1 even
        // when a real ≥2-column pack of the actual widths fit. guarded-by: fan_grid_test.zig "wrapWideFanOut P5 pack finds a 2-column layout the old widest-slot math missed (29/25/25 @ budget 58)"
        //
        // The feasibility row width is tested against the FULL budget: a row
        // exactly == budget still fits the canvas, and `normalizeX` after this
        // pass slides the centred block back inside the left margin. If no
        // `cols >= 2` is feasible we fall back to `cols = 1` — byte-identical to
        // the historical single-column stack.
        const fit_budget: u32 = budget;
        var col_of_buf: [256]u8 = undefined;
        var cols: u32 = 1;
        {
            // Largest feasible cols, from n-1 downward. The first feasible wins
            // (fewest grid rows). cols == n would be a single row, which already
            // failed the `single_row_w` test above, so start at n - 1.
            var try_cols: u32 = @min(n - 1, @as(u32, @intCast(col_of_buf.len)));
            while (try_cols >= 2) : (try_cols -= 1) {
                if (n > col_of_buf.len) break;
                if (packFeasible(G, f.peers, geom, try_cols, place_gap, fit_budget, col_of_buf[0..n])) {
                    cols = try_cols;
                    break;
                }
            }
        }
        // No feasible multi-column pack → fall back to the historical single
        // column: every child on its own row, centred under the pivot.
        // Skipping the wrap entirely would instead leave the row to clip, a
        // regression — so we always stack, never `continue` here. guarded-by: fan_grid_test.zig "wrapWideFanOut falls back to a single column matching the legacy per-box centering"
        if (cols < 2) {
            cols = 1;
            for (col_of_buf[0..n]) |*c| c.* = 0;
        }

        // Rows = the tallest column's member count. For cols == 1 this is n. guarded-by: fan_grid_test.zig "wrapWideFanOut falls back to a single column matching the legacy per-box centering"
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

        const row_step: i32 = @as(i32, @intCast(max_child_h)) +
            @as(i32, @intCast(v_spacing)) + 1;

        const base_y: i32 = geom[f.peers[0].peer_idx].y;
        const added_h: i32 = @as(i32, @intCast(rows - 1)) * row_step;
        for (geom) |*g| {
            if (g.y > base_y) g.y += added_h;
        }

        // Per-column x-offsets: each column is as wide as its widest member
        // (VARIABLE column widths, not max_child_w for every column), so 2
        // narrow columns can't re-overflow. guarded-by: fan_grid_test.zig "wrapWideFanOut variable per-column widths avoid re-overflow from 2 narrow columns"
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

        // Place each child: column from the bin-pack assignment, row = its rank
        // within that column (top-to-bottom in peer order). Centre each box on
        // its column's CENTRE so a narrow box in a wide column is not
        // left-jammed against the trunk (cols == 1 reduces to legacy
        // `x = pivot_cx - w/2`). guarded-by: fan_grid_test.zig "wrapWideFanIn centres a narrow box on its column's centre, not flush to a wide neighbour"
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

/// Uniform-slot fan-OUT grid: children packed `cols` per row in reading
/// order, each row centred as a block under the pivot, packed left-to-right
/// with `gap` between adjacent boxes (`gap` is the fan-OUT `place_gap`,
/// == `h_spacing`).
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

    const row_step: i32 = @as(i32, @intCast(max_child_h)) +
        @as(i32, @intCast(v_spacing)) + 1;

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

/// Distribute `peers` into `cols` columns in ROW-MAJOR reading order (peer `i`
/// → column `i % cols`, row `i / cols`) and report whether the widest resulting
/// ROW — summed from the ACTUAL widths of the boxes in it plus `gap` between
/// adjacent columns — fits `budget`. Fills `col_of[i]` with the column index.
///
/// Row-major (not height-balanced) is deliberate: it preserves the children's
/// left-to-right order, so a fan whose peers have their own downstream
/// substructure keeps its edges in reading order instead of being scrambled by
/// a height-greedy pack. The win this pass exists for — choosing `cols >= 2`
/// from REAL per-column widths where the old uniform-widest-slot math forced a
/// single column — comes from the variable column widths, not from reordering.
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
