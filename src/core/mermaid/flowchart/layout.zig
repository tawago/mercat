const std = @import("std");
const bundle_plan = @import("base/bundle_plan.zig");
const sg = @import("sem_graph.zig");
const sketch = @import("sketch.zig");
const sketch_ports = @import("sketch_ports.zig");
const sugiyama = @import("layout/sugiyama.zig");
const crossing = @import("layout/crossing.zig");
const routing = @import("layout/routing.zig");
const node_geom = @import("layout/node_geom.zig");
const bounds = @import("layout/bbox.zig");
const fan_mod = @import("layout/fan.zig");
const fan_lanes = @import("layout/fan_lanes.zig");
const gap_rows = @import("layout/gap_rows.zig");
const mirror = @import("layout/mirror.zig");
const x_assign = @import("layout/x_assign.zig");
const sizing = @import("layout/sizing.zig");
const pressure = @import("layout/pressure.zig");
const bundle_decision = @import("layout/bundle_decision.zig");
const port_plan = @import("layout/port_plan.zig");
const options = @import("layout/options.zig");

pub const FixedSize = options.FixedSize;
pub const LayoutOptions = options.LayoutOptions;
pub const Justify = options.Justify;

pub const CoordsError = error{
    OutOfMemory,
    EmptyGraph,
};

const NodeGeom = node_geom.NodeGeom;

pub fn layout(
    allocator: std.mem.Allocator,
    graph: sg.SemGraph,
    opts: LayoutOptions,
) CoordsError!sketch.Sketch {
    if (graph.nodes.len == 0) return error.EmptyGraph;

    const source_direction = graph.direction;
    var layout_graph = graph;
    const use_bt_mirror = source_direction == .BT;
    if (use_bt_mirror) layout_graph.direction = .TD;

    var lg = sugiyama.assignLayers(allocator, layout_graph) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EmptyGraph => return error.EmptyGraph,
        error.InconsistentEdge => return error.EmptyGraph,
    };
    defer lg.deinit(allocator);

    try crossing.reduceCrossings(allocator, &lg);

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();

    var result = try buildSketch(a, layout_graph, lg, opts);
    if (use_bt_mirror) result = try mirror.vertical(a, result, .BT);
    return result;
}

fn buildSketch(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    opts: LayoutOptions,
) error{OutOfMemory}!sketch.Sketch {
    const total = lg.nodes.len;
    const geom = try a.alloc(NodeGeom, total);
    const node_lines = try a.alloc([]const []const u8, total);

    const decision = try bundle_decision.decide(a, graph, lg, opts.bundle_permits);
    const fans = try ownFans(a, decision.fans);
    try sizing.sizeNodes(a, graph, lg, geom, opts.node_padding, opts.fixed_sizes, opts.max_label_width, node_lines);
    sizing.applyPortDemand(graph, lg, geom, decision.attachments);
    const layer_h = try heights(a, lg, geom);
    const v_sp_per_gap = try gaps(a, graph.direction, lg, opts.v_spacing);

    const compact_x = (graph.direction == .TD) and !opts.is_direction_rotated;

    try x_assign.spread(a, graph, geom, lg, opts.h_spacing, compact_x);

    if (fans.len > 0) fan_mod.gateFanInSharedLabels(NodeGeom, fans, geom);
    if (fans.len > 0) try fan_lanes.assignLanes(NodeGeom, a, graph, lg, geom, fans, decision.bundles);

    if (fans.len > 0) fan_mod.refreshLabelWidths(graph, fans);

    assignY(geom, lg.layers, layer_h, v_sp_per_gap);

    try pressure.run(a, graph, lg, geom, fans, v_sp_per_gap, opts, compact_x);

    if (fans.len > 0) fan_mod.assignRoles(fans, try x_assign.centersX(a, geom));
    foldLayerOffsets(lg, geom, layer_h);

    const predicted_ports = try port_plan.predict(a, graph, lg, geom, decision.attachments, decision.bundles, decision.port_active);
    const supers = try a.alloc(gap_rows.Super, opts.fixed_sizes.len);
    for (opts.fixed_sizes, supers) |fixed, *sup| sup.* = .{ .node = fixed.node, .drawn = !fixed.synthetic };
    const rows = try gap_rows.buildPiece(a, graph, lg, geom, fans, decision.bundles, predicted_ports, v_sp_per_gap, supers, opts.departures, opts.label_room);
    restack(lg, geom, layer_h, v_sp_per_gap, rows);

    mirror.applyDirection(geom, graph.direction);

    const placements = try sizing.buildPlacements(a, graph, lg, geom, node_lines);
    const allocated_ports = try port_plan.allocate(a, graph, placements, decision.attachments, decision.bundles);
    const edges_result = if (decision.port_active)
        try routing.buildEdgesWithPlan(a, graph, lg, geom, placements, fans, decision.bundles, allocated_ports, rows)
    else
        try routing.buildEdges(a, graph, lg, geom, placements, fans, rows);
    const edges_out = edges_result.edges;

    const rail_lever = (opts.spacing_scale > 0) and
        (graph.direction == .TD) and !opts.is_direction_rotated;
    const bbox = bounds.computeBbox(placements, edges_out, edges_result.polylines, edges_result.rails, rail_lever, opts.max_width);
    var diagnostics: std.ArrayListUnmanaged(sketch.Diagnostic) = .empty;
    if (bbox.w > opts.max_width) {
        try diagnostics.append(a, .width_overflow);
    }
    if (opts.max_label_width != null) {
        try diagnostics.appendSlice(a, try sizing.forcedWraps(a, graph, lg, node_lines));
    }

    const rails_out = try a.alloc(sketch.Rail, edges_result.rails.len);
    for (edges_result.rails, rails_out) |b, *out| out.* = b.rail;

    const base_sets = if (decision.plan_realized)
        bundle_plan.bundlesFromPlan(a, decision.bundles) catch edges_result.bundles
    else
        edges_result.bundles;
    return .{
        .bbox = bbox,
        .direction = graph.direction,
        .nodes = placements,
        .clusters = &.{},
        .edges = edges_out,
        .rails = rails_out,
        .sharing = .{
            .realized = decision.bundles,
            .bundles = sketch_ports.appendPortShares(a, base_sets, edges_out) catch base_sets,
            .claims = edges_result.claims,
        },
        .diagnostics = try diagnostics.toOwnedSlice(a),
        .budget = .{ .max_width = opts.max_width, .rung = opts.rung },
    };
}

fn ownFans(a: std.mem.Allocator, fans: []const fan_mod.Fan) error{OutOfMemory}![]fan_mod.Fan {
    const out = try a.dupe(fan_mod.Fan, fans);
    for (out) |*f| f.peers = try a.dupe(fan_mod.FanEdge, f.peers);
    return out;
}

pub fn heights(a: std.mem.Allocator, lg: sugiyama.LayeredGraph, geom: []const NodeGeom) error{OutOfMemory}![]u32 {
    const layer_h = try a.alloc(u32, lg.layers.len);
    @memset(layer_h, 0);
    for (lg.layers, layer_h) |row, *tallest| {
        for (row) |idx| tallest.* = @max(tallest.*, geom[idx].h);
    }
    return layer_h;
}

pub fn gaps(a: std.mem.Allocator, direction: sg.Direction, lg: sugiyama.LayeredGraph, v_spacing: u32) error{OutOfMemory}![]u32 {
    const base: u32 = switch (direction) {
        .TD => v_spacing,
        .BT => unreachable,
        .LR, .RL => 4,
    };
    if (lg.layers.len == 0) return try a.alloc(u32, 0);
    const out = try a.alloc(u32, lg.layers.len - 1);
    @memset(out, base);
    return out;
}

pub fn assignY(geom: []NodeGeom, layers: [][]u32, layer_h: []const u32, v_sp_per_gap: []const u32) void {
    var cursor: i32 = 0;
    for (layers, 0..) |row, li| {
        for (row) |idx| geom[idx].y += cursor;
        const gap: u32 = if (li < v_sp_per_gap.len) v_sp_per_gap[li] else 0;
        cursor += @as(i32, @intCast(layer_h[li])) + @as(i32, @intCast(gap));
    }
}

pub fn foldLayerOffsets(lg: sugiyama.LayeredGraph, geom: []NodeGeom, layer_h: []u32) void {
    for (lg.layers, 0..) |row, li| {
        var top: i32 = std.math.maxInt(i32);
        for (row) |idx| if (lg.nodes[idx] == .real) {
            top = @min(top, geom[idx].y);
        };
        if (top == std.math.maxInt(i32)) for (row) |idx| {
            top = @min(top, geom[idx].y);
        };
        var block: u32 = 0;
        for (row) |idx| {
            geom[idx].y = if (lg.nodes[idx] == .real) geom[idx].y - top else 0;
            block = @max(block, @as(u32, @intCast(geom[idx].y)) + geom[idx].h);
        }
        layer_h[li] = block;
    }
}

fn growSubGaps(lg: sugiyama.LayeredGraph, geom: []NodeGeom, layer_h: []u32, rows: gap_rows.Ledger) void {
    var i: usize = 0;
    while (i < rows.sub_gaps.len) : (i += 1) {
        const sgp = &rows.sub_gaps[i];
        const extra = rows.extraRows(sgp.gap);
        if (extra == 0) continue;
        const shift: i32 = @intCast(extra);
        for (lg.layers[sgp.layer]) |idx| if (lg.nodes[idx] == .real and geom[idx].y >= sgp.top) {
            geom[idx].y += shift;
        };
        for (rows.sub_gaps[i..]) |*later| if (later.layer == sgp.layer) {
            later.top += shift;
            if (later.far >= sgp.top) later.far += shift;
        };
        layer_h[sgp.layer] += extra;
    }
}

pub fn restack(lg: sugiyama.LayeredGraph, geom: []NodeGeom, layer_h: []u32, v_sp_per_gap: []u32, rows: gap_rows.Ledger) void {
    for (v_sp_per_gap, 0..) |*gap, i| gap.* += rows.extraRows(i);
    growSubGaps(lg, geom, layer_h, rows);
    assignY(geom, lg.layers, layer_h, v_sp_per_gap);
}

test {
    _ = @import("layout/layout_test.zig");
    _ = @import("layout/layer_axis_test.zig");
}
