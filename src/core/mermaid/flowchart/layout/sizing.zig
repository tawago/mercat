const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");
const ports = @import("ports.zig");

pub const NodeGeom = routing.NodeGeom;

pub const FixedSize = struct { node: sg.NodeId, w: u32, h: u32, synthetic: bool = false };

pub const Dims = struct { w: u32, h: u32 };

pub fn shapeMinDims(shape: sg.NodeShape) Dims {
    return switch (shape) {
        .circle, .double_circle => .{ .w = 5, .h = 3 },
        .cylinder => .{ .w = 5, .h = 3 },
        else => .{ .w = 3, .h = 3 },
    };
}

pub fn labelLines(
    a: std.mem.Allocator,
    label: []const u8,
    max_label_width: ?u32,
) error{OutOfMemory}![]const []const u8 {
    if (max_label_width) |cap| {
        return prim.wrapToWidth(a, label, cap);
    }
    // @guarded-by: sizing_test.zig "labelLines hard-break-only path matches wrapToWidth at an effectively infinite cap"
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, label, prim.LINE_BREAK);
    while (it.next()) |seg| try lines.append(a, seg);
    return try lines.toOwnedSlice(a);
}

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
    // @guarded-by: sizing_test.zig "sizeNodes pre-swaps an LR multi-line label so post-applyDirection dims match the visual box"
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
