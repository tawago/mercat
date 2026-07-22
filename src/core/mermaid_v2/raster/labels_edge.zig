//! Edge and bus-bar tap label placement: anchors at the edge's mid-segment,
//! then falls back through a bounded, deterministic ladder — legacy anchor
//! first, then positions along the label's own segment (convention side,
//! walking outward from the midpoint), then remaining polyline segments.
//! Dropped (edge_label_no_space) only when every candidate collides or is
//! out of bounds.
//!
//! Import boundary: std, prim, sketch, lattice, raster siblings only (same
//! zone as labels.zig; enforced by tools/lint_imports.zig).

const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const labels = @import("labels.zig");

const log = std.log.scoped(.@"mermaid_v2.raster.labels");

pub const SegPair = struct { a: sketch.Point, b: sketch.Point };

pub fn pickMidSegment(poly: []const sketch.Point) ?SegPair {
    var count: usize = 0;
    for (poly[0 .. poly.len - 1], 0..) |p, i| {
        const q = poly[i + 1];
        if (p.x != q.x or p.y != q.y) count += 1;
    }
    if (count == 0) return null;
    const target = count / 2;
    var seen: usize = 0;
    for (poly[0 .. poly.len - 1], 0..) |p, i| {
        const q = poly[i + 1];
        if (p.x == q.x and p.y == q.y) continue;
        if (seen == target) return .{ .a = p, .b = q };
        seen += 1;
    }
    return null;
}

/// Outcome of one label's ladder walk. `displaced` (placed, but not at
/// the primary anchor) is a cheaper shipped defect than `dropped` — the
/// raster report counts both so the candidate score can price the
/// difference (a fold whose labels only fit at far fallbacks must not
/// score identically to a layout whose labels sit at convention anchors).
pub const Placement = enum { at_anchor, displaced, dropped };

pub fn placeEdgeLabel(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(labels.LabelDiagnostic),
    lat: *lattice.Lattice,
    ep: sketch.EdgePath,
    label: []const u8,
) labels.RasterError!Placement {
    if (ep.polyline.len < 2) return .dropped;

    // Midpoint of the polyline: pick the middle non-degenerate segment
    // (skip zero-length segments produced by routing fixups so e.g. a
    // [(x,y),(x,y'),(x,y')] polyline yields the (x,y)→(x,y') segment).
    const seg_pair = pickMidSegment(ep.polyline) orelse return .dropped;
    return placeLabelAtSeg(allocator, diags, lat, ep.id, label, seg_pair.a, seg_pair.b, ep.label_left_of_rail, ep.polyline);
}

/// Shared anchored-placement body for edge and bus-bar tap labels.
/// `polyline` supplies the fallback segments for the tail of the ladder;
/// bus-bar taps pass `&.{}` (the tap segment is the only geometry they own).
pub fn placeLabelAtSeg(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(labels.LabelDiagnostic),
    lat: *lattice.Lattice,
    edge_id: u32,
    label: []const u8,
    a: sketch.Point,
    b: sketch.Point,
    left_of_rail: bool,
    polyline: []const sketch.Point,
) labels.RasterError!Placement {
    // Number of lattice cells the label occupies = one cell per codepoint.
    const cell_count: u32 = @intCast(std.unicode.utf8CountCodepoints(label) catch label.len);

    // Candidate #1: legacy anchor recorded by layout on ep.label_left_of_rail (clusters.computeBbox). guarded-by: labels_test.zig "edge label fits above midpoint"
    const anchor = anchorFor(a, b, left_of_rail, prim.displayWidth(label));
    if (tryWrite(lat, label, cell_count, anchor.x, anchor.y)) return .at_anchor;

    if (trySegment(lat, label, cell_count, a, b, left_of_rail)) return .displaced;

    // Ladder tail: the remaining non-degenerate segments of the polyline.
    if (polyline.len >= 2) {
        for (polyline[0 .. polyline.len - 1], 0..) |p, i| {
            const q = polyline[i + 1];
            if (p.x == q.x and p.y == q.y) continue;
            if (p.x == a.x and p.y == a.y and q.x == b.x and q.y == b.y) continue;
            if (trySegment(lat, label, cell_count, p, q, left_of_rail)) return .displaced;
        }
    }

    _ = try emitEdgeNoSpace(allocator, diags, edge_id, prim.displayWidth(label));
    return .dropped;
}

/// The primary (legacy) anchor for a segment: right-of-rail / above-the-
/// line convention, or the LEFT-of-rail width-lever anchor when layout
/// chose it.
fn anchorFor(a: sketch.Point, b: sketch.Point, left_of_rail: bool, label_w: u32) prim.LabelAnchor {
    return if (left_of_rail)
        prim.leftOfRailAnchor(a.x, a.y, b.x, b.y, label_w)
    else
        prim.edgeLabelAnchor(a.x, a.y, b.x, b.y, label_w, .{});
}

/// Try every fallback position this segment offers, in ladder order:
/// convention side first, walking outward from the midpoint. The primary
/// anchor for the FIRST segment is tried by the caller before this; for
/// ladder-tail segments the anchor cell recurs as the d=0 walk position.
fn trySegment(
    lat: *lattice.Lattice,
    label: []const u8,
    cell_count: u32,
    a: sketch.Point,
    b: sketch.Point,
    left_of_rail: bool,
) bool {
    const orig_len: u32 = prim.displayWidth(label);

    if (a.y == b.y) {
        // Horizontal segment: rows above then below the line, walked outward from the midpoint. guarded-by: labels_test.zig "edge label falls back below the segment when above is out of bounds"
        const mid_x: i32 = @divTrunc(a.x + b.x, 2);
        const min_x = @min(a.x, b.x);
        const max_x = @max(a.x, b.x);
        const rows = [2]i32{ a.y - 1, a.y + 1 };
        for (rows) |row| {
            var d: i32 = 0;
            while (mid_x - d >= min_x or mid_x + d <= max_x) : (d += 1) {
                if (mid_x - d >= min_x and tryWrite(lat, label, cell_count, mid_x - d, row)) return true;
                if (d > 0 and mid_x + d <= max_x and tryWrite(lat, label, cell_count, mid_x + d, row)) return true;
            }
        }
        return false;
    }

    // Vertical (or routing-fixup diagonal) segment: convention side first
    // (right of the rail, or left when the width lever chose left), walking
    // rows outward from the midpoint within the segment's row span.
    const mid_x: i32 = @divTrunc(a.x + b.x, 2);
    const mid_y: i32 = @divTrunc(a.y + b.y, 2);
    const min_y = @min(a.y, b.y);
    const max_y = @max(a.y, b.y);
    const right_x: i32 = mid_x + 2;
    const left_x: i32 = mid_x - 1 - @as(i32, @intCast(orig_len));
    const sides = if (left_of_rail) [2]i32{ left_x, right_x } else [2]i32{ right_x, left_x };
    for (sides) |x| {
        var d: i32 = 0;
        while (mid_y - d >= min_y or mid_y + d <= max_y) : (d += 1) {
            if (mid_y - d >= min_y and tryWrite(lat, label, cell_count, x, mid_y - d)) return true;
            if (d > 0 and mid_y + d <= max_y and tryWrite(lat, label, cell_count, x, mid_y + d)) return true;
        }
    }
    return false;
}

/// True iff the cell at `(x,y)` is a `label_char` occupant.
fn isLabelChar(lat: *const lattice.Lattice, x: u32, y: u32) bool {
    return switch (lat.atConst(x, y).occupant) {
        .label_char => true,
        else => false,
    };
}

/// Bounds-check the span, require every cell empty, then write one
/// label_char cell per codepoint. All-or-nothing per candidate.
fn tryWrite(
    lat: *lattice.Lattice,
    label: []const u8,
    cell_count: u32,
    lx: i32,
    ly: i32,
) bool {
    if (ly < 0 or @as(i64, ly) >= lat.height) return false;
    if (lx < 0) return false;
    const start_x: u32 = @intCast(lx);
    const row: u32 = @intCast(ly);
    if (start_x + cell_count > lat.width) return false;

    // Require >=1 empty column of separation from any adjacent label span so
    // two independently-anchored labels never fuse into one unreadable run
    // (fan-out siblings "route: api"+"route: static"). Only label_char
    // neighbours force separation; abutting edge/node/arrow ink is legal.
    // Flank cells are on the SAME row, immediately left of start_x and
    // immediately right of the span end; a span flush to the grid edge simply
    // has no flank there. // guarded-by: labels_test.zig "tryWrite requires a blank column between abutting label spans"
    if (start_x >= 1 and isLabelChar(lat, start_x - 1, row)) return false;
    if (start_x + cell_count < lat.width and isLabelChar(lat, start_x + cell_count, row)) return false;

    // Any non-empty cell is a genuine collision (edges/earlier labels are rasterized first) — reject the candidate. // guarded-by: labels_test.zig "tryWrite rejects a pre-occupied primary-anchor cell as a real collision, not an OOB miss"
    var i: u32 = 0;
    while (i < cell_count) : (i += 1) {
        const cell = lat.atConst(start_x + i, row);
        switch (cell.occupant) {
            .empty => {},
            else => return false,
        }
    }

    var x: u32 = start_x;
    var bi: usize = 0;
    while (bi < label.len) {
        const dc = labels.nextCodepoint(label, bi);
        bi += dc.byte_len;
        lat.at(x, row).* = .{
            .occupant = .{ .label_char = labels.sentinelToSpace(dc.cp) },
            .neighbours = .{},
        };
        x += 1;
    }
    return true;
}

fn emitEdgeNoSpace(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(labels.LabelDiagnostic),
    edge_id: u32,
    orig_len: u32,
) labels.RasterError!bool {
    log.debug(
        "raster/labels: edge {d} has no space for label (len={d}); skipping",
        .{ edge_id, orig_len },
    );
    try diags.append(allocator, .{
        .kind = .edge_label_no_space,
        .node_or_edge_or_cluster_id = edge_id,
        .original_len = orig_len,
        .placed_len = 0,
    });
    return false;
}
