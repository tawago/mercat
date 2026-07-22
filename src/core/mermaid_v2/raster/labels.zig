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
) RasterError!Report {
    var diags = std.ArrayList(LabelDiagnostic){};
    defer diags.deinit(allocator);

    var placed: u32 = 0;
    var attempted: u32 = 0;
    var displaced: u32 = 0;

    for (s.nodes) |np| {
        if (np.lines.len == 0) continue;
        attempted += 1;
        if (try placeNodeLabel(allocator, &diags, lat, np)) placed += 1;
    }

    for (s.edges) |ep| {
        const lbl = ep.label orelse continue;
        if (lbl.len == 0) continue;
        attempted += 1;
        switch (try labels_edge.placeEdgeLabel(allocator, &diags, lat, ep, lbl)) {
            .at_anchor => placed += 1,
            .displaced => {
                placed += 1;
                displaced += 1;
            },
            .dropped => {},
        }
    }

    // Anchored on `BusBar.tapLabelSeg`, the same segment layout/clusters.zig
    // reserved bbox space for, so reservation and paint agree.
    for (s.busbars) |bb| {
        for (bb.taps) |tap| {
            const lbl = tap.label orelse continue;
            if (lbl.len == 0) continue;
            attempted += 1;
            const seg = bb.tapLabelSeg(tap);
            switch (try labels_edge.placeLabelAtSeg(allocator, &diags, lat, tap.edge, lbl, seg[0], seg[1], false, &.{})) {
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
        if (try placeClusterLabel(allocator, &diags, lat, cf)) placed += 1;
    }

    return Report{
        .placed = placed,
        .dropped = attempted - placed,
        .displaced = displaced,
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

/// Write a single node-label codepoint into the cell at (x,row), but only
/// if that cell is the interior of `np`. Returns true if written.
fn writeNodeCell(
    lat: *lattice.Lattice,
    np: sketch.NodePlacement,
    x: u32,
    row: u32,
    cp: u21,
) bool {
    const cell = lat.at(x, row);
    switch (cell.occupant) {
        .node_interior => |nid| {
            if (nid != np.id) {
                log.debug(
                    "raster/labels: node {d} label cell ({d},{d}) is interior of node {d}; skipping",
                    .{ np.id, x, row, nid },
                );
                return false;
            }
            cell.* = .{
                .occupant = .{ .label_char = cp },
                .neighbours = .{},
            };
            return true;
        },
        else => {
            log.debug(
                "raster/labels: node {d} label cell ({d},{d}) not node_interior; skipping",
                .{ np.id, x, row },
            );
            return false;
        },
    }
}

fn placeNodeLabel(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(LabelDiagnostic),
    lat: *lattice.Lattice,
    np: sketch.NodePlacement,
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
            if (x >= lat.width) break;
            if (writeNodeCell(lat, np, x, row, dc.cp)) wrote += 1;
            x += 1;
        }
        if (truncated and x < lat.width) {
            if (writeNodeCell(lat, np, x, row, ELLIPSIS)) wrote += 1;
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
fn stampTitleCell(lat: *lattice.Lattice, x: u32, row: u32, cp: u21) void {
    lat.at(x, row).* = .{
        .occupant = .{ .label_char = cp },
        .neighbours = .{},
    };
}

fn placeClusterLabel(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(LabelDiagnostic),
    lat: *lattice.Lattice,
    cf: sketch.ClusterFrame,
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
        stampTitleCell(lat, lead, row, @as(u21, ' '));
        wrote += 1;
    }

    const start = lead + 1;
    var x: u32 = start;
    var bi: usize = 0;
    while (bi < text.len) {
        const dc = nextCodepoint(text, bi);
        bi += dc.byte_len;
        if (x >= lat.width) break;
        // Overwrite cluster_border edge_n cells (and tolerate empty too).
        stampTitleCell(lat, x, row, sentinelToSpace(dc.cp));
        wrote += 1;
        x += 1;
    }
    if (truncated and x < lat.width) {
        stampTitleCell(lat, x, row, ELLIPSIS);
        wrote += 1;
        x += 1;
    }

    // Trailing space (immediately after the last written label cell).
    if (x < lat.width) {
        stampTitleCell(lat, x, row, @as(u21, ' '));
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
}
