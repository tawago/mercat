//! Label rasterization — writes node, edge, and cluster labels into a
//! Lattice as `label_char` occupant cells. Runs last in the raster pass
//! (after nodes/clusters/edges) so it can detect conflicts defensively.
//!
//! Import boundary: only `std`, `prim`, `../sketch.zig`, `../lattice.zig`
//! (enforced by `tools/lint_imports.zig`); no `parse/` or `paint/`.
//!
//! Measured in display columns (`prim.displayWidth`), EAW-aware
//! truncation reserves a column for the ellipsis. Diagnostics log at
//! `.debug` scope only (kept out of release stderr).
//!
//! Text becomes cells exactly once, in `labels_write.prepare`: one cell
//! per grapheme head, multi-codepoint graphemes interned into the lattice's
//! `glyphs` table, which this entry point builds and attaches.

const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels_edge = @import("labels_edge.zig");
const labels_onrun = @import("labels_onrun.zig");
const lw = @import("labels_write.zig");
const aux = @import("aux.zig");

const log = std.log.scoped(.@"mermaid_v2.raster.labels");

pub const RasterError = error{OutOfMemory};

/// Codepoint U+2026 HORIZONTAL ELLIPSIS, used when truncating labels
/// that overflow their available width.
const ELLIPSIS: u21 = 0x2026;

pub const LabelDiagnostic = struct {
    kind: enum {
        node_label_truncated,
        edge_label_no_space,
        cluster_label_truncated,
    },
    /// Which entity the diagnostic refers to. Disambiguated by `kind`:
    ///   node_label_truncated    -> NodeId
    ///   edge_label_no_space     -> EdgeId
    ///   cluster_label_truncated -> ClusterId
    node_or_edge_or_cluster_id: u32,
    original_len: u32,
    placed_len: u32,
};

pub const Report = struct {
    placed: u32,
    /// Labels that were present in the Sketch (non-empty node lines,
    /// edge label, cluster label) but could NOT be placed at all —
    /// attempted minus placed (report-only).
    dropped: u32,
    /// Edge/tap labels placed by the fallback ladder at a position other
    /// than their primary anchor (see labels_edge.Placement) — a cheaper
    /// shipped defect than `dropped`, priced separately by the score.
    displaced: u32,
    /// Edge/tap labels placed ON their own private fan dropper (the
    /// top-priority on-run candidate, labels_onrun.zig). A PLACED label —
    /// counted in `placed`, never in `displaced` — reported separately for
    /// diagnostic honesty.
    on_run: u32,
    /// Arena-allocated. Lifetime matches the allocator passed to
    /// `rasterizeLabels` (callers should pass the same arena that owns
    /// the Sketch and Lattice).
    diagnostics: []const LabelDiagnostic,
};

/// Place labels (node, edge, cluster) into the lattice as `label_char`
/// occupant cells. Reads from the Sketch; mutates `lat` in place.
///
/// Allocator MUST be the same arena used for the Sketch + Lattice so
/// the returned diagnostics' lifetime matches.
pub fn rasterizeLabels(
    allocator: std.mem.Allocator,
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    sink: aux.Sink,
) RasterError!Report {
    var diags = std.ArrayList(LabelDiagnostic){};
    defer diags.deinit(allocator);

    // Interned multi-codepoint graphemes, attached to the lattice on the
    // way out. Labels are rasterized once per lattice, so nothing can
    // already refer into a table.
    std.debug.assert(lat.glyphs.len == 0);
    var glyphs = lw.GlyphTable.init(allocator);
    errdefer glyphs.deinit();

    var placed: u32 = 0;
    var attempted: u32 = 0;
    var displaced: u32 = 0;
    var on_run: u32 = 0;

    for (s.nodes) |np| {
        if (np.lines.len == 0) continue;
        attempted += 1;
        if (try placeNodeLabel(allocator, &diags, lat, np, &glyphs, sink)) placed += 1;
    }

    for (s.edges) |ep| {
        const lbl = ep.label orelse continue;
        if (lbl.len == 0) continue;
        attempted += 1;
        const run = try lw.prepare(allocator, &glyphs, lbl);
        // Top-priority on-run candidate: the label sits OVER its own private
        // fan dropper (labels_onrun.zig). Any refusal falls through to the
        // ordinary ladder below. @guarded-by: labels_onrun_test.zig "happy path: the label interrupts its own dropper for one row, sandwiched by run flanks"
        if (labels_onrun.tryOnRunEdge(lat, s, ep, run, sink)) {
            placed += 1;
            on_run += 1;
            continue;
        }
        switch (try labels_edge.placeEdgeLabel(allocator, &diags, lat, ep, run, sink)) {
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
            if (labels_onrun.tryOnRunTap(lat, s, tap, run, sink)) {
                placed += 1;
                on_run += 1;
                continue;
            }
            const seg = rail.tapLabelSeg(tap);
            switch (try labels_edge.placeLabelAtSeg(allocator, &diags, lat, tap.edge, run, seg[0], seg[1], false, &.{}, sink)) {
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
        if (try placeClusterLabel(allocator, &diags, lat, cf, &glyphs, sink)) placed += 1;
    }

    lat.glyphs = try glyphs.finish();

    return Report{
        .placed = placed,
        .dropped = attempted - placed,
        .displaced = displaced,
        .on_run = on_run,
        .diagnostics = try diags.toOwnedSlice(allocator),
    };
}

/// Cells one single-codepoint glyph claims (the ellipsis, the title
/// band's spaces); the text → cells vocabulary lives with the writer
/// contract in `labels_write.zig`.
pub const cellSpan = lw.cellSpan;

/// Write one node-label grapheme head at (x,row), claiming all `span` cells
/// of its footprint. All-or-nothing: every cell must be `np`'s interior,
/// so a wide glyph is never split across foreign ink and never leaves a
/// widowed continuation. Returns true if written.
/// @guarded-by: labels_eaw_test.zig "a wide node glyph whose second cell is not this node's interior is refused whole"
fn writeNodeSpan(
    lat: *lattice.Lattice,
    np: sketch.NodePlacement,
    x: u32,
    row: u32,
    cp: u21,
    span: u32,
    sink: aux.Sink,
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
    lw.writeSpan(lat, x, row, cp, span, .{ .kind = .node, .id = np.id }, sink);
    return true;
}

fn placeNodeLabel(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(LabelDiagnostic),
    lat: *lattice.Lattice,
    np: sketch.NodePlacement,
    glyphs: *lw.GlyphTable,
    sink: aux.Sink,
) RasterError!bool {
    if (np.rect.w < 3 or np.rect.h < 3) return false;

    const inner_w: u32 = np.rect.w - 2;
    // Line k paints interior row rect.y+1+k. // @guarded-by: raster/labels_test.zig "node label fits centered"
    var wrote: u32 = 0;
    var any_truncated = false;
    var max_orig: u32 = 0;
    for (np.lines, 0..) |line, k| {
        const row_i: i32 = np.rect.y + 1 + @as(i32, @intCast(k));
        if (row_i >= np.rect.y + @as(i32, @intCast(np.rect.h)) - 1) break;
        if (row_i < 0 or @as(i64, row_i) >= lat.height) continue;
        const row: u32 = @intCast(row_i);

        const orig_len: u32 = prim.displayWidth(line);
        if (orig_len > max_orig) max_orig = orig_len;
        const truncated = orig_len > inner_w;
        if (truncated) any_truncated = true;
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
            if (writeNodeSpan(lat, np, x, row, cell.value, cell.span, sink)) wrote += 1;
            x += cell.span;
        }
        if (truncated and x + cellSpan(ELLIPSIS) <= lat.width) {
            if (writeNodeSpan(lat, np, x, row, ELLIPSIS, cellSpan(ELLIPSIS), sink)) wrote += 1;
        }
    }

    if (any_truncated) {
        try diags.append(allocator, .{
            .kind = .node_label_truncated,
            .node_or_edge_or_cluster_id = np.id,
            .original_len = max_orig,
            .placed_len = inner_w,
        });
    }

    return wrote > 0;
}

/// Stamp one cluster-title cell as a `label_char` — EVERY cell, spaces
/// included. Owner ruling (D2 REJECTED, tawago 2026-07-19): the edge bridges
/// over the WHOLE title band (spaces and all); the band looks exactly like the
/// old render and the arrowhead below the band is the resumed edge. No
/// title-space conduction.
fn stampTitleCell(lat: *lattice.Lattice, x: u32, row: u32, cp: u21, cf: sketch.ClusterFrame, sink: aux.Sink) void {
    lw.writeGlyph(lat, x, row, cp, .{ .kind = .cluster, .id = cf.id }, sink);
}

fn placeClusterLabel(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(LabelDiagnostic),
    lat: *lattice.Lattice,
    cf: sketch.ClusterFrame,
    glyphs: *lw.GlyphTable,
    sink: aux.Sink,
) RasterError!bool {
    if (cf.rect.w < 6 or cf.rect.h < 2) return false;

    const inner_w: u32 = cf.rect.w - 5;
    const orig_len: u32 = prim.displayWidth(cf.label);
    const truncated = orig_len > inner_w;
    const text: []const u8 = if (truncated)
        prim.truncateToWidth(cf.label, inner_w - 1)
    else
        cf.label;
    const placed_len: u32 = if (truncated)
        prim.displayWidth(text) + 1
    else
        orig_len;

    const row_i: i32 = cf.rect.y;
    if (row_i < 0 or @as(i64, row_i) >= lat.height) return false;
    const row: u32 = @intCast(row_i);

    const lead_i: i32 = cf.rect.x + 2;
    if (lead_i < 0) return false;
    const lead: u32 = @intCast(lead_i);

    var wrote: u32 = 0;

    if (lead < lat.width) {
        stampTitleCell(lat, lead, row, @as(u21, ' '), cf, sink);
        wrote += 1;
    }

    const start = lead + 1;
    var x: u32 = start;
    const run = try lw.prepare(allocator, glyphs, text);
    for (run.cells) |cell| {
        // The band claims the glyph's whole footprint, so the trailing
        // space that closes it lands past the last painted column.
        // @guarded-by: labels_eaw_test.zig "wide cluster title advances by span and still closes the band"
        if (x + cell.span > lat.width) break;
        stampTitleCell(lat, x, row, cell.value, cf, sink);
        var i: u32 = 1;
        while (i < cell.span) : (i += 1) lw.writeCont(lat, x + i, row);
        wrote += 1;
        x += cell.span;
    }
    if (truncated and x + cellSpan(ELLIPSIS) <= lat.width) {
        stampTitleCell(lat, x, row, ELLIPSIS, cf, sink);
        wrote += 1;
        x += cellSpan(ELLIPSIS);
    }

    if (x < lat.width) {
        stampTitleCell(lat, x, row, @as(u21, ' '), cf, sink);
        wrote += 1;
    }

    if (truncated) {
        try diags.append(allocator, .{
            .kind = .cluster_label_truncated,
            .node_or_edge_or_cluster_id = cf.id,
            .original_len = orig_len,
            .placed_len = placed_len,
        });
    }

    return wrote > 0;
}

test {
    _ = @import("labels_test.zig");
    _ = @import("labels_ladder_test.zig");
    _ = @import("labels_eaw_test.zig");
}
