const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels_edge = @import("labels_edge.zig");
const labels_onrun = @import("labels_onrun.zig");
const lw = @import("labels_write.zig");
const types = @import("labels_types.zig");

const log = std.log.scoped(.@"mermaid_v2.raster.labels");

pub const RasterError = types.RasterError;
pub const Report = types.Report;

const ELLIPSIS: u21 = 0x2026;

pub fn rasterizeLabels(
    allocator: std.mem.Allocator,
    lat: *lattice.Lattice,
    s: sketch.Sketch,
) RasterError!Report {
    std.debug.assert(lat.glyphs.len == 0);
    var glyphs = lw.GlyphTable.init(allocator);
    errdefer glyphs.deinit();

    var placed: u32 = 0;
    var attempted: u32 = 0;
    var displaced: u32 = 0;

    for (s.nodes) |np| {
        if (np.lines.len == 0) continue;
        attempted += 1;
        if (try placeNodeLabel(allocator, lat, np, &glyphs)) placed += 1;
    }

    for (s.edges) |ep| {
        const lbl = ep.label orelse continue;
        if (lbl.len == 0) continue;
        attempted += 1;
        const run = try lw.prepare(allocator, &glyphs, lbl);
        if (labels_onrun.tryOnRunEdge(lat, s, ep, run)) {
            placed += 1;
            continue;
        }
        switch (labels_edge.placeEdgeLabel(lat, ep, run)) {
            .at_anchor => placed += 1,
            .displaced => {
                placed += 1;
                displaced += 1;
            },
            .dropped => {},
        }
    }

    for (s.rails) |rail| {
        for (rail.taps) |tap| {
            const lbl = tap.label orelse continue;
            if (lbl.len == 0) continue;
            attempted += 1;
            const run = try lw.prepare(allocator, &glyphs, lbl);
            if (labels_onrun.tryOnRunTap(lat, s, tap, run)) {
                placed += 1;
                continue;
            }
            const seg = rail.tapLabelSeg(tap);
            switch (labels_edge.placeLabelAtSeg(lat, tap.edge, run, seg[0], seg[1], false, &.{})) {
                .at_anchor => placed += 1,
                .displaced => {
                    placed += 1;
                    displaced += 1;
                },
                .dropped => {},
            }
        }
    }

    for (s.clusters) |cf| {
        if (cf.label.len == 0) continue;
        attempted += 1;
        if (try placeClusterLabel(allocator, lat, cf, &glyphs)) placed += 1;
    }

    lat.glyphs = try glyphs.finish();

    return Report{
        .placed = placed,
        .dropped = attempted - placed,
        .displaced = displaced,
    };
}

pub const cellSpan = lw.cellSpan;

fn writeNodeSpan(
    lat: *lattice.Lattice,
    np: sketch.NodePlacement,
    x: u32,
    row: u32,
    cp: u21,
    span: u32,
) bool {
    var i: u32 = 0;
    while (i < span) : (i += 1) {
        switch (lat.atConst(x + i, row).occupant) {
            .node_interior => |nid| {
                if (nid != np.id) {
                    log.debug(
                        "raster/labels: node {d} label cell ({d},{d}) is interior of node {d}; skipping",
                        .{ np.id, x + i, row, nid },
                    );
                    return false;
                }
            },
            else => {
                log.debug(
                    "raster/labels: node {d} label cell ({d},{d}) not node_interior; skipping",
                    .{ np.id, x + i, row },
                );
                return false;
            },
        }
    }
    lw.writeSpan(lat, x, row, cp, span);
    return true;
}

fn placeNodeLabel(
    allocator: std.mem.Allocator,
    lat: *lattice.Lattice,
    np: sketch.NodePlacement,
    glyphs: *lw.GlyphTable,
) RasterError!bool {
    if (np.rect.w < 3 or np.rect.h < 3) return false;

    const inner_w: u32 = np.rect.w - 2;
    var wrote: u32 = 0;
    for (np.lines, 0..) |line, k| {
        const row_i: i32 = np.rect.y + 1 + @as(i32, @intCast(k));
        if (row_i >= np.rect.y + @as(i32, @intCast(np.rect.h)) - 1) break;
        if (row_i < 0 or @as(i64, row_i) >= lat.height) continue;
        const row: u32 = @intCast(row_i);

        const orig_len: u32 = prim.displayWidth(line);
        const truncated = orig_len > inner_w;
        const text: []const u8 = if (truncated)
            prim.truncateToWidth(line, inner_w - 1)
        else
            line;
        const placed_len: u32 = if (truncated)
            prim.displayWidth(text) + 1
        else
            orig_len;

        const left_pad: u32 = (inner_w - placed_len) / 2;
        const start_i: i32 = np.rect.x + 1 + @as(i32, @intCast(left_pad));
        if (start_i < 0) continue;
        var x: u32 = @intCast(start_i);
        const run = try lw.prepare(allocator, glyphs, text);
        for (run.cells) |cell| {
            if (x + cell.span > lat.width) break;
            if (writeNodeSpan(lat, np, x, row, cell.value, cell.span)) wrote += 1;
            x += cell.span;
        }
        if (truncated and x + cellSpan(ELLIPSIS) <= lat.width) {
            if (writeNodeSpan(lat, np, x, row, ELLIPSIS, cellSpan(ELLIPSIS))) wrote += 1;
        }
    }

    return wrote > 0;
}

fn stampTitleCell(lat: *lattice.Lattice, x: u32, row: u32, cp: u21) void {
    lw.writeGlyph(lat, x, row, cp);
}

fn placeClusterLabel(
    allocator: std.mem.Allocator,
    lat: *lattice.Lattice,
    cf: sketch.ClusterFrame,
    glyphs: *lw.GlyphTable,
) RasterError!bool {
    if (cf.rect.w < 6 or cf.rect.h < 2) return false;

    const inner_w: u32 = cf.rect.w - 5;
    const orig_len: u32 = prim.displayWidth(cf.label);
    const truncated = orig_len > inner_w;
    const text: []const u8 = if (truncated)
        prim.truncateToWidth(cf.label, inner_w - 1)
    else
        cf.label;

    const row_i: i32 = cf.rect.y;
    if (row_i < 0 or @as(i64, row_i) >= lat.height) return false;
    const row: u32 = @intCast(row_i);

    const lead_i: i32 = cf.rect.x + 2;
    if (lead_i < 0) return false;
    const lead: u32 = @intCast(lead_i);

    var wrote: u32 = 0;

    if (lead < lat.width) {
        stampTitleCell(lat, lead, row, @as(u21, ' '));
        wrote += 1;
    }

    const start = lead + 1;
    var x: u32 = start;
    const run = try lw.prepare(allocator, glyphs, text);
    for (run.cells) |cell| {
        if (x + cell.span > lat.width) break;
        stampTitleCell(lat, x, row, cell.value);
        var i: u32 = 1;
        while (i < cell.span) : (i += 1) lw.writeCont(lat, x + i, row);
        wrote += 1;
        x += cell.span;
    }
    if (truncated and x + cellSpan(ELLIPSIS) <= lat.width) {
        stampTitleCell(lat, x, row, ELLIPSIS);
        wrote += 1;
        x += cellSpan(ELLIPSIS);
    }

    if (x < lat.width) {
        stampTitleCell(lat, x, row, @as(u21, ' '));
        wrote += 1;
    }

    return wrote > 0;
}

test {
    _ = @import("labels_test.zig");
    _ = @import("labels_ladder_test.zig");
    _ = @import("labels_eaw_test.zig");
}
