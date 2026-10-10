const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels_edge = @import("labels_edge.zig");
const labels_onrun = @import("labels_onrun.zig");
const labels_ink = @import("labels_ink.zig");
const lw = @import("labels_write.zig");

const log = std.log.scoped(.@"mermaid.raster.labels");

pub const RasterError = error{OutOfMemory};

pub const Omission = labels_edge.Omission;

pub const LabelOwner = union(enum) {
    edge: sketch.EdgeId,
    tap: struct { rail: u32, edge: sketch.EdgeId },
};

pub const Form = enum { on_run, beside_run };

pub const EdgeLabel = struct {
    owner: LabelOwner,
    origin: sketch.EdgeId,
    form: ?Form,
    first_choice: bool,
    omitted: ?Omission,
};

pub const LabelPlan = struct {
    edges: []const EdgeLabel = &.{},
    node_dropped: u32 = 0,
    cluster_dropped: u32 = 0,

    pub fn omittedRouted(self: LabelPlan) u32 {
        var n: u32 = 0;
        for (self.edges) |e| {
            if (e.omitted) |o| {
                if (o != .unrouted_host) n += 1;
            }
        }
        return n;
    }

    pub fn dropped(self: LabelPlan) u32 {
        var n: u32 = self.node_dropped + self.cluster_dropped;
        for (self.edges) |e| {
            if (e.omitted != null) n += 1;
        }
        return n;
    }

    pub fn displaced(self: LabelPlan) u32 {
        var n: u32 = 0;
        for (self.edges) |e| {
            if (e.form != null and !e.first_choice) n += 1;
        }
        return n;
    }
};

const ELLIPSIS: u21 = 0x2026;

const Subject = struct {
    owner: LabelOwner,
    origin: sketch.EdgeId,
    hosts: []const labels_ink.Host,
    polyline: []const sketch.Point,
    left_of_run: bool = false,
};

fn placeEdgeLabel(lat: *lattice.Lattice, sub: Subject, run: lw.Run) EdgeLabel {
    var label: EdgeLabel = .{ .owner = sub.owner, .origin = sub.origin, .form = null, .first_choice = false, .omitted = null };
    for (sub.hosts, 0..) |h, i| {
        if (labels_onrun.tryOnRun(lat, h, run)) {
            label.form = .on_run;
            label.first_choice = i == 0;
            return label;
        }
    }
    if (labels_edge.beside(lat, sub.hosts, sub.polyline, run, sub.left_of_run)) {
        label.form = .beside_run;
        return label;
    }
    label.omitted = .no_room;
    return label;
}

pub fn rasterizeLabels(
    allocator: std.mem.Allocator,
    lat: *lattice.Lattice,
    s: sketch.Sketch,
) RasterError!LabelPlan {
    std.debug.assert(lat.glyphs.len == 0);
    var glyphs = lw.GlyphTable.init(allocator);
    errdefer glyphs.deinit();

    var plan: LabelPlan = .{};
    var edges: std.ArrayList(EdgeLabel) = .empty;
    errdefer edges.deinit(allocator);

    for (s.nodes) |np| {
        if (np.lines.len == 0) continue;
        if (!try placeNodeLabel(allocator, lat, np, &glyphs)) plan.node_dropped += 1;
    }

    for (s.edges) |ep| {
        const lbl = ep.label orelse continue;
        if (lbl.len == 0) continue;
        const owner: LabelOwner = .{ .edge = ep.id };
        const run = try lw.prepare(allocator, &glyphs, lbl);
        if (!ep.routed()) {
            try edges.append(allocator, .{ .owner = owner, .origin = ep.origin, .form = null, .first_choice = false, .omitted = .unrouted_host });
            continue;
        }
        const hosts = try labels_ink.hosts(allocator, ep.id, .{ ep.from, ep.to }, ep.polyline);
        defer allocator.free(hosts);
        const sub: Subject = .{ .owner = owner, .origin = ep.origin, .hosts = hosts, .polyline = ep.polyline, .left_of_run = ep.label_left_of_run };
        try edges.append(allocator, placeEdgeLabel(lat, sub, run));
    }

    for (s.rails, 0..) |rail, ri| {
        for (rail.taps) |tap| {
            const lbl = tap.label orelse continue;
            if (lbl.len == 0) continue;
            const owner: LabelOwner = .{ .tap = .{ .rail = @intCast(ri), .edge = tap.edge } };
            const run = try lw.prepare(allocator, &glyphs, lbl);
            const dropper = [2]sketch.Point{ tap.at, tap.landing };
            const hosts = try labels_ink.hosts(allocator, tap.edge, .{ rail.pivot, tap.node }, &dropper);
            defer allocator.free(hosts);
            const sub: Subject = .{ .owner = owner, .origin = tap.origin, .hosts = hosts, .polyline = &dropper };
            try edges.append(allocator, placeEdgeLabel(lat, sub, run));
        }
    }

    for (s.clusters) |cf| {
        if (cf.label.len == 0) continue;
        if (!try placeClusterLabel(allocator, lat, cf, &glyphs)) plan.cluster_dropped += 1;
    }

    lat.glyphs = try glyphs.finish();
    plan.edges = try edges.toOwnedSlice(allocator);
    return plan;
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
