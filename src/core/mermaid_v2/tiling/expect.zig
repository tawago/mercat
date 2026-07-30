//! Expectation tier of the report-only structural audit: what the
//! geometry DECLARED versus what the lattice SHOWS.
//!
//! IDENTITY AUTHORITY — this tier is SKETCH-anchored, and that is a
//! deliberate limit. Clustered renders renumber node ids during the
//! cut/stitch recursion and the reverse map does not travel on the
//! Sketch, so a per-edge SemGraph<->Sketch match would either fabricate
//! verdicts or need a renderer change. The SemGraph therefore contributes
//! identity-free CENSUS counters only (`m_graph_*` against `m_sketch_*`):
//! semantic loss between the two IRs shows up as a delta, never as a
//! per-edge accusation.
//!
//! EVIDENCE IS POSITIONAL, never edge-id-keyed. Cell ids are
//! first-writer-lossy — an overlapping run keeps the first claimant's id
//! — so asking "is edge 7's ink at edge 7's terminal" would report
//! phantom losses on every legal overlap. The question asked here is
//! "does the declared position hold ink at all", and when it holds
//! SOMEONE ELSE's opaque ink that is a separate, non-defect bucket.
//!
//! The population is a GEOMETRY union: routed `Sketch.edges` plus every
//! bus-bar tap. A fan edge absorbed into a bus-bar has no polyline at
//! all, so keying on `Sketch.edges` alone would silently drop it; taps
//! key on their own rail/landing points instead.
//!
//! Deferred by design (phase 1): per-edge-label absence attribution.
//! `label_char` cells carry no owner, so only census-level label counters
//! are produced.
//!
//! Imports: `std`, `prim`, `lattice.zig`, `sem_graph.zig`, `sketch.zig`,
//! `cell.zig`, `counts.zig` (per-file row in `tools/lint_imports.zig`).

const std = @import("std");
const lattice = @import("../lattice.zig");
const sem_graph = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");

/// Everything this tier reads. A standalone struct rather than
/// `scan.Ctx`: `scan` imports this module, so the dependency may not run
/// the other way.
pub const Input = struct {
    graph: sem_graph.SemGraph,
    sketch: sketch.Sketch,
    lat: *const lattice.Lattice,
    labels_placed: u32 = 0,
    labels_dropped: u32 = 0,
    labels_displaced: u32 = 0,
};

const Point = sketch.Point;

fn dirOf(a: Point, b: Point) ?cell.Dir4 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    if (dx == 0 and dy == 0) return null;
    if (dx != 0 and dy != 0) return null;
    if (dx > 0) return .east;
    if (dx < 0) return .west;
    if (dy > 0) return .south;
    return .north;
}

fn stepPt(p: Point, d: cell.Dir4) Point {
    return switch (d) {
        .north => .{ .x = p.x, .y = p.y - 1 },
        .south => .{ .x = p.x, .y = p.y + 1 },
        .east => .{ .x = p.x + 1, .y = p.y },
        .west => .{ .x = p.x - 1, .y = p.y },
    };
}

/// Typed copy at a signed point, or null when it lies off the lattice.
fn at(v: cell.View, p: Point) ?cell.Typed {
    if (p.x < 0 or p.y < 0) return null;
    return v.at(@intCast(p.x), @intCast(p.y));
}

/// The first and last cells an edge's polyline actually claims, plus the
/// direction of travel at each. Replays the raster walk's own rules: a
/// segment's END point is always skipped (it is either the next corner,
/// owned by the corner writer, or the target's perimeter), and the final
/// corner takes the LAST segment's outgoing direction so a length-1 final
/// approach still points into the port.
const Walk = struct {
    first: ?Point = null,
    first_dir: ?cell.Dir4 = null,
    last: ?Point = null,
    last_dir: ?cell.Dir4 = null,
};

fn walk(v: cell.View, pts: []const Point) Walk {
    var r: Walk = .{};
    if (pts.len < 2) return r;

    var nontrivial: usize = 0;
    var k: usize = 0;
    while (k + 1 < pts.len) : (k += 1) {
        if (dirOf(pts[k], pts[k + 1]) != null) nontrivial += 1;
    }
    if (nontrivial == 0) return r;

    var prev_dir: ?cell.Dir4 = null;
    var seg_index: usize = 0;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        const a = pts[i];
        const b = pts[i + 1];
        const dir = dirOf(a, b) orelse continue;
        const is_last = seg_index == nontrivial - 1;
        seg_index += 1;

        if (prev_dir) |prev| {
            if (at(v, a) != null) {
                if (r.first == null) {
                    r.first = a;
                    r.first_dir = dir;
                }
                r.last = a;
                r.last_dir = if (is_last) dir else prev;
            }
        }

        var cursor = stepPt(a, dir);
        while (!(cursor.x == b.x and cursor.y == b.y)) : (cursor = stepPt(cursor, dir)) {
            if (at(v, cursor) != null) {
                if (r.first == null) {
                    r.first = cursor;
                    r.first_dir = dir;
                }
                r.last = cursor;
                r.last_dir = dir;
            }
        }
        prev_dir = dir;
    }
    return r;
}

/// Does the declared approach cell show any ink? A one-cell reprieve
/// along the approach axis mirrors the port-padding the rasterizer
/// itself allows.
fn terminalEvidence(v: cell.View, p: Point, d: cell.Dir4, c: *counts.Counts) void {
    const t = at(v, p) orelse {
        c.d_edge_no_terminal_evidence += 1;
        return;
    };
    switch (t.kind) {
        .stroke, .arrow => {},
        .blank => {
            const q = at(v, stepPt(p, d)) orelse {
                c.d_edge_no_terminal_evidence += 1;
                return;
            };
            switch (q.kind) {
                .stroke, .arrow => {},
                else => c.d_edge_no_terminal_evidence += 1,
            }
        },
        // Someone else's opaque ink holds the cell. Positional evidence
        // cannot say whose, and the arrival may well be underneath it.
        else => c.c_edge_absorbed += 1,
    }
}

/// Is a declared arrowhead visible along its approach axis? Id-blind: a
/// terminal cell claimed by a foreign run still carries the arrowhead
/// occupant, and that is the evidence being asked for.
fn arrowEvidence(v: cell.View, p: Point, d: cell.Dir4, c: *counts.Counts) void {
    const probes = [3]Point{ p, stepPt(p, d), stepPt(p, cell.reverse(d)) };
    for (probes) |q| {
        if (at(v, q)) |t| {
            if (t.kind == .arrow) return;
        }
    }
    if (at(v, p)) |t| {
        switch (t.kind) {
            // The documented refusal paths: an arrowhead write over node
            // geometry or a label is skipped and counted as a lost cell.
            .ring_node, .fill, .glyph => {
                c.c_arrow_refused += 1;
                return;
            },
            else => {},
        }
    }
    c.d_arrow_missing += 1;
}

/// Replay of the source-border merge's own preconditions: a non-invisible
/// edge whose first non-degenerate segment departs north or south from a
/// point sitting on a node border. The border cell must carry that
/// departure bit.
fn sourceMerge(v: cell.View, ep: sketch.EdgePath, c: *counts.Counts) void {
    var fd: ?cell.Dir4 = null;
    var i: usize = 0;
    while (i + 1 < ep.polyline.len) : (i += 1) {
        if (dirOf(ep.polyline[i], ep.polyline[i + 1])) |d| {
            fd = d;
            break;
        }
    }
    const d = fd orelse return;
    if (d != .north and d != .south) return;
    const t = at(v, ep.polyline[0]) orelse return;
    if (t.kind != .ring_node) return;
    if (t.mask & cell.bit(d) == 0) c.d_source_merge_missing += 1;
}

/// Labels the rasterizer would ATTEMPT, counted the same way it counts
/// them: node lines, edge labels, tap labels, cluster titles.
fn labelCensus(s: sketch.Sketch) u32 {
    var n: u32 = 0;
    for (s.nodes) |np| {
        if (np.lines.len > 0) n += 1;
    }
    for (s.edges) |ep| {
        const l = ep.label orelse continue;
        if (l.len > 0) n += 1;
    }
    for (s.busbars) |bb| {
        for (bb.taps) |tp| {
            const l = tp.label orelse continue;
            if (l.len > 0) n += 1;
        }
    }
    for (s.clusters) |cf| {
        if (cf.label.len > 0) n += 1;
    }
    return n;
}

fn rectFits(r: sketch.Rect, v: cell.View) bool {
    if (r.w == 0 or r.h == 0) return false;
    if (r.x < 0 or r.y < 0) return false;
    if (r.right() > @as(i32, @intCast(v.width()))) return false;
    if (r.bottom() > @as(i32, @intCast(v.height()))) return false;
    return true;
}

/// Ink cells immediately OUTSIDE a rect: the arrivals that reached it.
fn abuttingInk(v: cell.View, r: sketch.Rect) u32 {
    var n: u32 = 0;
    var x: i32 = r.x - 1;
    while (x <= r.right()) : (x += 1) {
        for ([2]i32{ r.y - 1, r.bottom() }) |y| {
            if (at(v, .{ .x = x, .y = y })) |t| {
                if (t.kind == .stroke or t.kind == .arrow) n += 1;
            }
        }
    }
    var y: i32 = r.y;
    while (y < r.bottom()) : (y += 1) {
        for ([2]i32{ r.x - 1, r.right() }) |x2| {
            if (at(v, .{ .x = x2, .y = y })) |t| {
                if (t.kind == .stroke or t.kind == .arrow) n += 1;
            }
        }
    }
    return n;
}

/// Per-node ring presence, label presence, and the arrival deficit.
/// `ring` is the scratch the caller allocated: index by node id.
fn nodeTier(v: cell.View, s: sketch.Sketch, ring: []bool, c: *counts.Counts) void {
    var y: u32 = 0;
    while (y < v.height()) : (y += 1) {
        var x: u32 = 0;
        while (x < v.width()) : (x += 1) {
            const t = v.at(x, y) orelse continue;
            if (t.kind != .ring_node) continue;
            const id = t.node orelse continue;
            if (id < ring.len) ring[id] = true;
        }
    }

    for (s.nodes) |np| {
        c.n_nodes_declared += 1;
        if (!rectFits(np.rect, v)) {
            c.c_node_offgrid += 1;
            continue;
        }
        if (np.id >= ring.len or !ring[np.id]) c.d_node_ring_missing += 1;

        if (np.lines.len > 0) {
            if (np.rect.w < 3 or np.rect.h < 3) {
                c.c_node_label_no_room += 1;
            } else if (!hasInteriorGlyph(v, np.rect)) {
                c.d_node_label_missing += 1;
            }
        }

        var arrivals: u32 = 0;
        for (s.edges) |ep| {
            if (ep.kind == .invisible) continue;
            if (ep.to == np.id) arrivals += 1;
        }
        for (s.busbars) |bb| {
            for (bb.taps) |tp| {
                if (tp.node == np.id) arrivals += 1;
            }
        }
        const seen = abuttingInk(v, np.rect);
        if (arrivals > seen) c.m_term_ink_deficit += arrivals - seen;
    }
}

fn hasInteriorGlyph(v: cell.View, r: sketch.Rect) bool {
    var y: i32 = r.y + 1;
    while (y < r.bottom() - 1) : (y += 1) {
        var x: i32 = r.x + 1;
        while (x < r.right() - 1) : (x += 1) {
            if (at(v, .{ .x = x, .y = y })) |t| {
                if (t.kind == .glyph) return true;
            }
        }
    }
    return false;
}

fn edgeTier(v: cell.View, s: sketch.Sketch, c: *counts.Counts) void {
    for (s.edges) |ep| {
        if (ep.kind == .invisible) continue;
        c.n_edges_declared += 1;
        sourceMerge(v, ep, c);

        const w = walk(v, ep.polyline);
        if (w.last) |p| {
            if (w.last_dir) |d| {
                terminalEvidence(v, p, d, c);
                if (ep.arrow_to != .none) {
                    c.n_arrows_declared += 1;
                    arrowEvidence(v, p, d, c);
                }
            }
        }
        if (ep.arrow_from != .none) {
            if (w.first) |p| {
                if (w.first_dir) |d| {
                    c.n_arrows_declared += 1;
                    arrowEvidence(v, p, cell.reverse(d), c);
                }
            }
        }
    }
}

fn tapTier(v: cell.View, s: sketch.Sketch, c: *counts.Counts) void {
    for (s.busbars) |bb| {
        for (bb.taps) |tp| {
            c.n_taps_declared += 1;
            const d = dirOf(tp.at, tp.landing) orelse continue;
            // The dropper stops one cell short of the landing (the node's
            // perimeter); with no room for a dropper the rail cell itself
            // is the tap's only ink.
            const back = stepPt(tp.landing, cell.reverse(d));
            const evc = if (back.x == tp.at.x and back.y == tp.at.y) tp.at else back;
            terminalEvidence(v, evc, d, c);
            if (tp.arrow != .none) {
                c.n_arrows_declared += 1;
                arrowEvidence(v, evc, d, c);
            }
        }
        if (bb.pivot_arrow != .none and bb.stem.len >= 2) {
            var i: usize = 0;
            while (i + 1 < bb.stem.len) : (i += 1) {
                const d = dirOf(bb.stem[i], bb.stem[i + 1]) orelse continue;
                c.n_arrows_declared += 1;
                arrowEvidence(v, stepPt(bb.stem[0], d), d, c);
                break;
            }
        }
    }
}

/// Run the whole tier. Never fails: the census and label counters are
/// filled in FIRST, so an allocation failure downgrades to partial counts
/// plus `u_audit_oom` rather than an empty record or a propagated error.
pub fn check(alloc: std.mem.Allocator, in: Input, c: *counts.Counts) void {
    const v = cell.View.init(in.lat);
    const s = in.sketch;

    var taps: u32 = 0;
    for (s.busbars) |bb| taps += @intCast(bb.taps.len);

    c.m_graph_nodes = @intCast(in.graph.nodes.len);
    c.m_graph_edges = @intCast(in.graph.edges.len);
    c.m_sketch_nodes = @intCast(s.nodes.len);
    c.m_sketch_edges = @intCast(s.edges.len + taps);

    const declared = labelCensus(s);
    c.n_labels_declared = declared;
    c.c_labels_dropped_reported = in.labels_dropped;
    c.c_labels_displaced_reported = in.labels_displaced;
    const reported = in.labels_placed + in.labels_dropped;
    c.u_label_census_mismatch = if (declared > reported) declared - reported else reported - declared;

    var max_id: u32 = 0;
    for (s.nodes) |np| max_id = @max(max_id, np.id);
    const ring = alloc.alloc(bool, @as(usize, max_id) + 1) catch {
        c.u_audit_oom += 1;
        return;
    };
    defer alloc.free(ring);
    @memset(ring, false);

    edgeTier(v, s, c);
    tapTier(v, s, c);
    nodeTier(v, s, ring, c);
}
