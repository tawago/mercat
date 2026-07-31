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

const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels_edge = @import("labels_edge.zig");
const labels_onrun = @import("labels_onrun.zig");
const lw = @import("labels_write.zig");
const aux = @import("aux.zig");

// Scoped logger — see module docstring. .debug keeps placement diagnostics
// out of release-build stderr while staying available to developers.
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

    var placed: u32 = 0;
    var attempted: u32 = 0;
    var displaced: u32 = 0;
    var on_run: u32 = 0;

    for (s.nodes) |np| {
        if (np.lines.len == 0) continue;
        attempted += 1;
        if (try placeNodeLabel(allocator, &diags, lat, np, sink)) placed += 1;
    }

    for (s.edges) |ep| {
        const lbl = ep.label orelse continue;
        if (lbl.len == 0) continue;
        attempted += 1;
        // Top-priority on-run candidate: the label sits OVER its own private
        // fan dropper (labels_onrun.zig). Any refusal falls through to the
        // ordinary ladder below. guarded-by: labels_onrun_test.zig "happy path: the label interrupts its own dropper for one row, sandwiched by run flanks"
        if (labels_onrun.tryOnRunEdge(lat, s, ep, lbl, sink)) {
            placed += 1;
            on_run += 1;
            continue;
        }
        switch (try labels_edge.placeEdgeLabel(allocator, &diags, lat, ep, lbl, sink)) {
            .at_anchor => placed += 1,
            .displaced => {
                placed += 1;
                displaced += 1;
            },
            .dropped => {},
        }
    }

    // Anchored on `Rail.tapLabelSeg`, the same segment layout/clusters.zig
    // reserved bbox space for, so reservation and paint agree.
    for (s.busbars) |bb| {
        for (bb.taps) |tap| {
            const lbl = tap.label orelse continue;
            if (lbl.len == 0) continue;
            attempted += 1;
            if (labels_onrun.tryOnRunTap(lat, s, tap, lbl, sink)) {
                placed += 1;
                on_run += 1;
                continue;
            }
            const seg = bb.tapLabelSeg(tap);
            switch (try labels_edge.placeLabelAtSeg(allocator, &diags, lat, tap.edge, lbl, seg[0], seg[1], false, &.{}, sink)) {
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
        if (try placeClusterLabel(allocator, &diags, lat, cf, sink)) placed += 1;
    }

    return Report{
        .placed = placed,
        .dropped = attempted - placed,
        .displaced = displaced,
        .on_run = on_run,
        .diagnostics = try diags.toOwnedSlice(allocator),
    };
}

/// One decoded codepoint of a label plus its UTF-8 byte length.
const Codepoint = struct { cp: u21, byte_len: usize };

/// Map the line-break sentinel (0x0A) to a space; edge and cluster
/// labels don't support multi-line, unlike node labels.
pub fn sentinelToSpace(cp: u21) u21 {
    return if (cp == prim.LINE_BREAK) @as(u21, ' ') else cp;
}

/// Decode the next UTF-8 codepoint at `text[index]`. On malformed UTF-8,
/// fall back to the raw byte as a u21 and advance 1 byte — the same
/// defensive policy as `prim.displayWidth`. `index` must be < text.len.
pub fn nextCodepoint(text: []const u8, index: usize) Codepoint {
    const seq_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
        return .{ .cp = @as(u21, text[index]), .byte_len = 1 };
    };
    if (index + seq_len > text.len) {
        return .{ .cp = @as(u21, text[index]), .byte_len = 1 };
    }
    const cp = std.unicode.utf8Decode(text[index .. index + seq_len]) catch {
        return .{ .cp = @as(u21, text[index]), .byte_len = 1 };
    };
    return .{ .cp = cp, .byte_len = seq_len };
}

/// Lattice cells one label codepoint occupies: an East-Asian-Wide
/// codepoint claims 2, everything else 1.
///
/// Deliberately NOT `prim.codepointWidth`: a tab (4 columns) stays ONE
/// cell and the C0 controls (0 columns, including the `prim.LINE_BREAK`
/// sentinel) stay one cell. That freezes the pre-existing cursor
/// arithmetic for every ASCII codepoint, which is what makes an
/// all-ASCII lattice bit-identical to the pre-continuation pipeline.
/// The tab column/cell skew is documented, not fixed.
/// guarded-by: labels_eaw_test.zig "cellSpan is 1 for every ASCII codepoint including tab"
pub fn cellSpan(cp: u21) u32 {
    return if (prim.codepointWidth(cp) == 2) 2 else 1;
}

/// Lattice cells `text` occupies: the sum of its codepoints' spans. The
/// one number every writer and every free-space probe reserves by, so
/// cells reserved and cells written can never disagree.
/// guarded-by: labels_eaw_test.zig "cellSpanOf equals prim.displayWidth for tab- and control-free text"
pub fn cellSpanOf(text: []const u8) u32 {
    var total: u32 = 0;
    var bi: usize = 0;
    while (bi < text.len) {
        const dc = nextCodepoint(text, bi);
        bi += dc.byte_len;
        total += cellSpan(dc.cp);
    }
    return total;
}

/// Write one node-label codepoint at (x,row), claiming all `span` cells
/// of its footprint. All-or-nothing: every cell must be `np`'s interior,
/// so a wide glyph is never split across foreign ink and never leaves a
/// widowed continuation. Returns true if written.
/// guarded-by: labels_eaw_test.zig "a wide node glyph whose second cell is not this node's interior is refused whole"
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
    sink: aux.Sink,
) RasterError!bool {
    if (np.rect.w < 3 or np.rect.h < 3) return false;

    const inner_w: u32 = np.rect.w - 2;
    // Line k paints interior row rect.y+1+k. // guarded-by: raster/labels_test.zig "node label fits centered"
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
        var bi: usize = 0;
        while (bi < text.len) {
            const dc = nextCodepoint(text, bi);
            bi += dc.byte_len;
            // Advance by the glyph's CELL footprint, matching the display
            // columns layout sized the box in. A refused glyph still
            // advances so the rest of the line keeps its column.
            const span = cellSpan(dc.cp);
            if (x + span > lat.width) break;
            if (writeNodeSpan(lat, np, x, row, dc.cp, span, sink)) wrote += 1;
            x += span;
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

// Edge and bus-bar tap label placement lives in labels_edge.zig: anchored
// at the mid-segment with a bounded deterministic fallback ladder.

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
    sink: aux.Sink,
) RasterError!bool {
    // Layout in the top border row:
    //   ┌─ <label> ───┐
    //   ^ ^ ^         ^
    //   0 1 2         w-1
    //
    // We write a leading space at col x+2, the label starting at x+3,
    // and a trailing space immediately after. Need at least width=6
    // (corners + `─` + space + 1 label col + space).
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

    // Leading space.
    if (lead < lat.width) {
        stampTitleCell(lat, lead, row, @as(u21, ' '), cf, sink);
        wrote += 1;
    }

    const start = lead + 1;
    var x: u32 = start;
    var bi: usize = 0;
    while (bi < text.len) {
        const dc = nextCodepoint(text, bi);
        bi += dc.byte_len;
        const cp = sentinelToSpace(dc.cp);
        // The band claims the glyph's whole footprint, so the trailing
        // space that closes it lands past the last painted column.
        // guarded-by: labels_eaw_test.zig "wide cluster title advances by span and still closes the band"
        const span = cellSpan(cp);
        if (x + span > lat.width) break;
        // Overwrite cluster_border edge_n cells (and tolerate empty too).
        stampTitleCell(lat, x, row, cp, cf, sink);
        var i: u32 = 1;
        while (i < span) : (i += 1) lw.writeCont(lat, x + i, row);
        wrote += 1;
        x += span;
    }
    if (truncated and x + cellSpan(ELLIPSIS) <= lat.width) {
        stampTitleCell(lat, x, row, ELLIPSIS, cf, sink);
        wrote += 1;
        x += cellSpan(ELLIPSIS);
    }

    // Trailing space (immediately after the last written label cell).
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
