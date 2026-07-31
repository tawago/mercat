//! Ink-ownership and label-region-isolation predicates for edge/tap label
//! placement (consumed by raster/labels_edge.zig).
//!
//! Two laws live here:
//!
//!  1. OWNERSHIP — every ink cell is classified relative to the label's own
//!     edge: `own` (the cell's edge id matches; OR the position lies on the
//!     label's own routed geometry — its polyline / anchor segment — which
//!     covers shared fan trunks and crossing cells whose single Cell id
//!     names another rider; OR a pre-attached side-table record — carrier /
//!     rail_member / tap — names the edge there; a SUPPRESSED carrier
//!     counts as the edge's ink for ownership, never as a blocker),
//!     `foreign_edge` (another edge's run or arrowhead), `foreign_solid`
//!     (node or cluster ink). Labels are not ink — their spacing is the
//!     run-separation rule below.
//!
//!  2. ISOLATION — a placed label span must keep a 1-cell margin (full
//!     8-neighbourhood) of non-ink cells against ALL foreign ink; only the
//!     label's own edge may touch the span. Two label runs on the same row
//!     additionally need >= 2 blank cells between them (a single space
//!     reads as one merged run).
//!
//! The LIVE aux collector is deliberately never consulted: rasterizing with
//! `collect_aux` on must change no painted cell (pinned by
//! tiling_records_test.zig "collecting the side table changes no painted
//! cell"), so placement may only depend on state both modes share — cell
//! ids, the Sketch geometry, and a lattice whose `aux` table was attached
//! BEFORE placement (synthetic fixtures only; production attaches it last).
//!
//! Import boundary: std, sketch, lattice, raster siblings only (raster
//! zone; enforced by tools/lint_imports.zig).

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");

/// Classification of one cell's ink relative to one label's edge.
pub const InkClass = enum { none, own, foreign_edge, foreign_solid };

/// Nearest-ink Chebyshev distances from a label span, per competing class.
/// `null` means "none found within the scanned radius".
pub const InkDistances = struct {
    own: ?u32 = null,
    foreign_edge: ?u32 = null,
};

/// The label's own edge, as the ownership tests see it: its id, its routed
/// polyline (empty for bus-bar taps), and the anchor segment the ladder is
/// walking (for taps, the tapLabelSeg stretch of shared rail — own ink even
/// though the trunk Cell names a single other rider).
pub const Owner = struct {
    edge_id: u32,
    polyline: []const sketch.Point,
    seg_a: sketch.Point,
    seg_b: sketch.Point,

    /// True iff (x, y) lies on the owner's routed geometry: the anchor
    /// segment or any axis-aligned polyline segment.
    fn onOwnPath(self: Owner, x: i32, y: i32) bool {
        if (onSegment(self.seg_a, self.seg_b, x, y)) return true;
        if (self.polyline.len < 2) return false;
        for (self.polyline[0 .. self.polyline.len - 1], 0..) |p, i| {
            if (onSegment(p, self.polyline[i + 1], x, y)) return true;
        }
        return false;
    }
};

fn onSegment(a: sketch.Point, b: sketch.Point, x: i32, y: i32) bool {
    if (a.x != b.x and a.y != b.y) return false; // routing-fixup diagonal: skip
    return x >= @min(a.x, b.x) and x <= @max(a.x, b.x) and
        y >= @min(a.y, b.y) and y <= @max(a.y, b.y);
}

fn recordsNameEdge(records: []const lattice.Aux, cell: u32, edge_id: u32) bool {
    for (records) |r| {
        if (r.cell != cell or r.value != edge_id) continue;
        switch (r.kind) {
            // Merged AND suppressed carriers both attribute the position to
            // the edge; rail_member/tap attribute shared fan-run ink to the
            // riding member. Ports are excluded: a port cell IS node border.
            .carrier, .rail_member, .tap => return true,
            else => {},
        }
    }
    return false;
}

/// Classify the ink at (x, y) relative to `owner`. Out-of-bounds positions,
/// empty cells and label cells are `.none`.
pub fn classifyAt(lat: *const lattice.Lattice, owner: Owner, x: i32, y: i32) InkClass {
    if (x < 0 or y < 0) return .none;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= lat.width or uy >= lat.height) return .none;
    return switch (lat.atConst(ux, uy).occupant) {
        .empty, .label_char, .label_cont => .none,
        .edge_segment => |seg| edgeInk(lat, owner, seg.edge, x, y),
        .arrowhead => |ah| edgeInk(lat, owner, ah.edge, x, y),
        .node_border, .node_interior, .cluster_border => .foreign_solid,
    };
}

fn edgeInk(lat: *const lattice.Lattice, owner: Owner, cell_edge: u32, x: i32, y: i32) InkClass {
    if (cell_edge == owner.edge_id) return .own;
    if (owner.onOwnPath(x, y)) return .own;
    if (recordsNameEdge(lat.aux, lat.cellIndex(@intCast(x), @intCast(y)), owner.edge_id)) return .own;
    return .foreign_edge;
}

fn isLabelCell(lat: *const lattice.Lattice, x: i32, y: i32) bool {
    if (x < 0 or y < 0) return false;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= lat.width or uy >= lat.height) return false;
    return switch (lat.atConst(ux, uy).occupant) {
        .label_char, .label_cont => true,
        else => false,
    };
}

/// LAW 2 candidate filter: true iff the 1×`cell_count` span at
/// (`start_x`, `row`) keeps a full 8-neighbourhood margin of non-ink cells
/// against every FOREIGN ink cell (own-edge ink may touch the span), and
/// keeps >= 2 blank cells of same-row separation from any other label run.
/// guarded-by: labels_ladder_test.zig "isolation rejects a foreign-ink neighbour in every one of the 8 directions"
/// guarded-by: labels_ladder_test.zig "own-edge ink beside the anchor does not displace the label"
pub fn spanIsolated(
    lat: *const lattice.Lattice,
    owner: Owner,
    start_x: i32,
    row: i32,
    cell_count: u32,
) bool {
    const cc: i32 = @intCast(cell_count);
    var y: i32 = row - 1;
    while (y <= row + 1) : (y += 1) {
        var x: i32 = start_x - 1;
        while (x <= start_x + cc) : (x += 1) {
            if (y == row and x >= start_x and x < start_x + cc) continue; // span cells themselves
            switch (classifyAt(lat, owner, x, y)) {
                .foreign_edge, .foreign_solid => return false,
                .none, .own => {},
            }
        }
    }
    // Same-row run separation: a single blank column between two label runs
    // reads as one merged run, so both flank cells at distance 1 AND 2 must
    // be label-free. // guarded-by: labels_test.zig "edge-label runs on the same row keep two blank cells apart"
    if (isLabelCell(lat, start_x - 1, row) or isLabelCell(lat, start_x - 2, row)) return false;
    if (isLabelCell(lat, start_x + cc, row) or isLabelCell(lat, start_x + cc + 1, row)) return false;
    return true;
}

/// Nearest own-edge ink and nearest foreign EDGE ink (node/cluster ink does
/// not compete for label ownership), measured as the minimum Chebyshev
/// distance from any span cell, scanning expanding rings up to `radius`.
/// Deterministic: pure function of the lattice, the owner geometry and the
/// span.
pub fn inkDistances(
    lat: *const lattice.Lattice,
    owner: Owner,
    start_x: i32,
    row: i32,
    cell_count: u32,
    radius: u32,
) InkDistances {
    var res: InkDistances = .{};
    const cc: i32 = @intCast(cell_count);
    var d: u32 = 1;
    while (d <= radius) : (d += 1) {
        if (res.own != null and res.foreign_edge != null) break;
        const di: i32 = @intCast(d);
        const x0 = start_x - di;
        const x1 = start_x + cc - 1 + di;
        const y0 = row - di;
        const y1 = row + di;
        var x = x0;
        while (x <= x1) : (x += 1) {
            note(&res, lat, owner, x, y0, d);
            note(&res, lat, owner, x, y1, d);
        }
        var y = y0 + 1;
        while (y < y1) : (y += 1) {
            note(&res, lat, owner, x0, y, d);
            note(&res, lat, owner, x1, y, d);
        }
    }
    return res;
}

fn note(res: *InkDistances, lat: *const lattice.Lattice, owner: Owner, x: i32, y: i32, d: u32) void {
    switch (classifyAt(lat, owner, x, y)) {
        .own => {
            if (res.own == null) res.own = d;
        },
        .foreign_edge => {
            if (res.foreign_edge == null) res.foreign_edge = d;
        },
        .none, .foreign_solid => {},
    }
}

test {
    _ = @import("labels_ink_test.zig");
}
