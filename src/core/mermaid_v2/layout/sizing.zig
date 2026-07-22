//! Node dimensioning helpers for `layout.zig`.
//! Owns per-shape minimum boxes, label-derived sizing, caller-imposed size
//! overrides (super-node sizing), the `sizeNodes` pass (writes initial w/h
//! into `NodeGeom`), and `buildPlacements` (geom+lines → sketch.NodePlacement).
//! For LR/RL, dims are pre-swapped so `layout.applyDirection`'s post-layout
//! swap restores the visual (label-runs-horizontal) orientation.
//!
//! Lint zone: may import std, prim, sem_graph, sketch, sugiyama, sibling
//! layout/* files; must not reach raster/, lattice/, paint/.

const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");
const ports = @import("ports.zig");

pub const NodeGeom = routing.NodeGeom;

/// A caller-imposed size override for one node, keyed by SemGraph NodeId.
/// Used by the cluster driver to size a "super-node" (a subgraph seen from
/// the outer flowchart) to the bounding box of its already-laid-out child,
/// since layout cannot derive that size from a label. The `w`/`h` are the
/// node's final visual dimensions; `sizeNodes` applies the same LR/RL axis
/// pre-swap it applies to label-derived dims so the post-`applyDirection`
/// result matches.
pub const FixedSize = struct { node: sg.NodeId, w: u32, h: u32 };

pub const Dims = struct { w: u32, h: u32 };

pub fn shapeMinDims(shape: sg.NodeShape) Dims {
    return switch (shape) {
        .circle, .double_circle => .{ .w = 5, .h = 3 },
        .cylinder => .{ .w = 5, .h = 3 },
        else => .{ .w = 3, .h = 3 },
    };
}

/// Compute the wrapped/segmented display lines of `label` for the given
/// soft-wrap cap. The lines are the single source of truth for box width,
/// box height, AND painting (P1a — one channel, no byte-vs-display drift).
///
///   - `max_label_width == null`: split on hard `\n` sentinels only (today's
///     behavior — each author segment is one line). No soft wrapping.
///   - else: `prim.wrapToWidth` — hard breaks honored, then each segment is
///     soft-wrapped to the cap.
///
/// Returned slice is arena-allocated; element slices are sub-slices of the
/// label (zero text duplication). An empty label yields one empty line.
pub fn labelLines(
    a: std.mem.Allocator,
    label: []const u8,
    max_label_width: ?u32,
) error{OutOfMemory}![]const []const u8 {
    if (max_label_width) |cap| {
        return prim.wrapToWidth(a, label, cap);
    }
    // Hard-break split only. Equivalent to wrapToWidth with an infinite cap, but cheaper and a sub-slice of the label. // guarded-by: sizing_test.zig "labelLines hard-break-only path matches wrapToWidth at an effectively infinite cap"
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, label, prim.LINE_BREAK);
    while (it.next()) |seg| try lines.append(a, seg);
    return try lines.toOwnedSlice(a);
}

/// Visual (pre-axis-swap) dimensions of a node from its already-computed
/// `lines`. Width = widest line + horizontal chrome; height = line count +
/// top/bottom border, each clamped up to the shape minimum.
pub fn dimsFromLines(lines: []const []const u8, shape: sg.NodeShape, node_padding: u32) Dims {
    const min = shapeMinDims(shape);
    var widest: u32 = 0;
    for (lines) |line| {
        const w = prim.displayWidth(line);
        if (w > widest) widest = w;
    }
    const padded_w = widest + node_padding * 2 + 2;
    const w = if (padded_w > min.w) padded_w else min.w;
    const line_count: u32 = @intCast(if (lines.len == 0) 1 else lines.len);
    const h_text: u32 = line_count + 2;
    const h = if (h_text > min.h) h_text else min.h;
    return .{ .w = w, .h = h };
}

/// Look up a caller-imposed size override for `id`, or null if none.
pub fn fixedSize(overrides: []const FixedSize, id: sg.NodeId) ?Dims {
    for (overrides) |f| {
        if (f.node == id) return .{ .w = f.w, .h = f.h };
    }
    return null;
}

pub fn realNode(graph: sg.SemGraph, id: sg.NodeId) sg.Node {
    for (graph.nodes) |n| {
        if (n.id == id) return n;
    }
    return graph.nodes[0];
}

/// Size every node and capture its label lines in one pass.
///
/// Writes initial (w, h) into `geom` and a parallel `node_lines[i]` (indexed
/// like `lg.nodes`; virtual nodes → empty slice). The lines are the single
/// authority later reused by `buildPlacements` → painting (P1a).
///
/// P1b — wrap axis: visual dims are computed from the lines FIRST (wrapping
/// decided on the visual width budget), THEN the LR/RL transpose is applied,
/// so soft-wrap always measures the axis the label actually runs along.
pub fn sizeNodes(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []NodeGeom,
    node_padding: u32,
    fixed_sizes: []const FixedSize,
    max_label_width: ?u32,
    node_lines: [][]const []const u8,
) error{OutOfMemory}!void {
    // For LR/RL flows, pre-swap dims are transposed so applyDirection's dim-swap restores the visual (label-runs-horizontal) orientation. // guarded-by: sizing_test.zig "sizeNodes pre-swaps an LR multi-line label so post-applyDirection dims match the visual box"
    const swap = (graph.direction == .LR or graph.direction == .RL);
    for (lg.nodes, 0..) |n, i| {
        switch (n) {
            .real => |nid| {
                const node = realNode(graph, nid);
                const lines = try labelLines(a, node.label, max_label_width);
                node_lines[i] = lines;
                const dims = fixedSize(fixed_sizes, nid) orelse
                    dimsFromLines(lines, node.shape, node_padding);
                const w = if (swap) dims.h else dims.w;
                const h = if (swap) dims.w else dims.h;
                geom[i] = .{ .x = 0, .y = 0, .w = w, .h = h, .layer = 0 };
            },
            .virtual => {
                node_lines[i] = &.{};
                geom[i] = .{ .x = 0, .y = 0, .w = 1, .h = 1, .layer = 0 };
            },
        }
    }
}

/// Apply D-PORT clause-9 minima after label sizing and before coordinates.
pub fn applyPortDemand(graph: sg.SemGraph, lg: sugiyama.LayeredGraph, geom: []NodeGeom, derived: []const ports.DerivedAttachment) void {
    const swap = graph.direction == .LR or graph.direction == .RL;
    for (lg.nodes, 0..) |node, i| switch (node) {
        .virtual => {},
        .real => |id| {
            const min = ports.demandDims(ports.sideDemand(derived, id));
            const want_w = if (swap) min.h_min else min.w_min;
            const want_h = if (swap) min.w_min else min.h_min;
            geom[i].w = @max(geom[i].w, want_w);
            geom[i].h = @max(geom[i].h, want_h);
        },
    };
}

/// Turn the final geometry + the sizing pass's label lines into Sketch
/// NodePlacements (real nodes only — virtuals exist for routing alone).
pub fn buildPlacements(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const NodeGeom,
    node_lines: []const []const []const u8,
) error{OutOfMemory}![]sketch.NodePlacement {
    var out: std.ArrayListUnmanaged(sketch.NodePlacement) = .empty;
    for (lg.nodes, 0..) |ln, i| {
        switch (ln) {
            .real => |nid| {
                const node = realNode(graph, nid);
                const g = geom[i];
                try out.append(a, .{
                    .id = nid,
                    .rect = .{ .x = g.x, .y = g.y, .w = g.w, .h = g.h },
                    .shape = mapShape(node.shape),
                    // Same lines the sizing pass measured (P1a).
                    .lines = node_lines[i],
                    .cluster_id = node.cluster,
                });
            },
            .virtual => {},
        }
    }
    return try out.toOwnedSlice(a);
}

fn mapShape(s: sg.NodeShape) sketch.Shape {
    return switch (s) {
        .rect => .rect,
        .round => .round,
        .stadium => .stadium,
        .subroutine => .subroutine,
        .cylinder => .cylinder,
        .circle, .double_circle => .circle,
        .asymmetric_left => .asymmetric_left,
        .asymmetric_right => .asymmetric_right,
        .rhombus => .rhombus,
        .hexagon => .hexagon,
        .parallelogram, .parallelogram_alt => .parallelogram,
        .trapezoid, .trapezoid_alt => .trapezoid,
    };
}

test {
    _ = @import("sizing_test.zig");
}
