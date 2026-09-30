const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels_edge = @import("labels_edge.zig");
const labels_onrun = @import("labels_onrun.zig");
const lw = @import("labels_write.zig");

const log = std.log.scoped(.@"mermaid_v2.raster.labels");

pub const RasterError = error{OutOfMemory};

pub const Report = struct {
    placed: u32,
    dropped: u32,
    displaced: u32,
};

const ELLIPSIS: u21 = 0x2026;

const Tally = struct {
    attempted: u32 = 0,
    placed: u32 = 0,
    displaced: u32 = 0,

    fn record(self: *Tally, placement: labels_edge.Placement) void {
        switch (placement) {
            .at_anchor => self.placed += 1,
            .displaced => {
                self.placed += 1;
                self.displaced += 1;
            },
            .dropped => {},
        }
    }
};

pub fn rasterizeLabels(
    allocator: std.mem.Allocator,
    lat: *lattice.Lattice,
    s: sketch.Sketch,
) RasterError!Report {
    std.debug.assert(lat.glyphs.len == 0);
    var glyphs = lw.GlyphTable.init(allocator);
    errdefer glyphs.deinit();

    var tally: Tally = .{};

    for (s.nodes) |np| {
        if (np.lines.len == 0) continue;
        tally.attempted += 1;
        if (try placeNodeLabel(allocator, lat, np, &glyphs)) tally.placed += 1;
    }

    for (s.edges) |ep| {
        const lbl = ep.label orelse continue;
        if (lbl.len == 0) continue;
        tally.attempted += 1;
        const run = try lw.prepare(allocator, &glyphs, lbl);
        if (labels_onrun.tryOnRunEdge(lat, s, ep, run)) {
            tally.placed += 1;
            continue;
        }
        tally.record(labels_edge.placeEdgeLabel(lat, ep, run));
    }

    for (s.rails) |rail| {
        for (rail.taps) |tap| {
            const lbl = tap.label orelse continue;
            if (lbl.len == 0) continue;
            tally.attempted += 1;
            const run = try lw.prepare(allocator, &glyphs, lbl);
            if (labels_onrun.tryOnRunTap(lat, s, tap, run)) {
                tally.placed += 1;
                continue;
            }
            const seg = rail.tapLabelSeg(tap);
            tally.record(labels_edge.placeLabelAtSeg(lat, tap.edge, run, seg[0], seg[1], false, &.{}));
        }
    }

    for (s.clusters) |cf| {
        if (cf.label.len == 0) continue;
        tally.attempted += 1;
        if (try placeClusterLabel(allocator, lat, cf, &glyphs)) tally.placed += 1;
    }

    lat.glyphs = try glyphs.finish();

    return Report{
        .placed = tally.placed,
        .dropped = tally.attempted - tally.placed,
        .displaced = tally.displaced,
    };
}

const Fitted = struct { text: []const u8, width: u32, truncated: bool };

fn fitToWidth(text: []const u8, max: u32) Fitted {
    const full = prim.displayWidth(text);
    if (full <= max) return .{ .text = text, .width = full, .truncated = false };
    const cut = prim.truncateToWidth(text, max - 1);
    return .{ .text = cut, .width = prim.displayWidth(cut) + 1, .truncated = true };
}

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

        const fit = fitToWidth(line, inner_w);
        const left_pad: u32 = (inner_w - fit.width) / 2;
        const start_i: i32 = np.rect.x + 1 + @as(i32, @intCast(left_pad));
        if (start_i < 0) continue;
        var x: u32 = @intCast(start_i);
        const run = try lw.prepare(allocator, glyphs, fit.text);
        for (run.cells) |cell| {
            if (x + cell.span > lat.width) break;
            if (writeNodeSpan(lat, np, x, row, cell.value, cell.span)) wrote += 1;
            x += cell.span;
        }
        if (fit.truncated and x + lw.cellSpan(ELLIPSIS) <= lat.width) {
            if (writeNodeSpan(lat, np, x, row, ELLIPSIS, lw.cellSpan(ELLIPSIS))) wrote += 1;
        }
    }

    return wrote > 0;
}

fn placeClusterLabel(
    allocator: std.mem.Allocator,
    lat: *lattice.Lattice,
    cf: sketch.ClusterFrame,
    glyphs: *lw.GlyphTable,
) RasterError!bool {
    if (cf.rect.w < 6 or cf.rect.h < 2) return false;

    const fit = fitToWidth(cf.label, cf.rect.w - 5);

    const row_i: i32 = cf.rect.y;
    if (row_i < 0 or @as(i64, row_i) >= lat.height) return false;
    const row: u32 = @intCast(row_i);

    const lead_i: i32 = cf.rect.x + 2;
    if (lead_i < 0) return false;
    const lead: u32 = @intCast(lead_i);

    var wrote: u32 = 0;

    if (lead < lat.width) {
        lw.writeGlyph(lat, lead, row, ' ');
        wrote += 1;
    }

    var x: u32 = lead + 1;
    const run = try lw.prepare(allocator, glyphs, fit.text);
    for (run.cells) |cell| {
        if (x + cell.span > lat.width) break;
        lw.writeSpan(lat, x, row, cell.value, cell.span);
        wrote += 1;
        x += cell.span;
    }
    if (fit.truncated and x + lw.cellSpan(ELLIPSIS) <= lat.width) {
        lw.writeGlyph(lat, x, row, ELLIPSIS);
        wrote += 1;
        x += lw.cellSpan(ELLIPSIS);
    }

    if (x < lat.width) {
        lw.writeGlyph(lat, x, row, ' ');
        wrote += 1;
    }

    return wrote > 0;
}

test {
    _ = @import("labels_test.zig");
    _ = @import("labels_ladder_test.zig");
    _ = @import("labels_eaw_test.zig");
}
