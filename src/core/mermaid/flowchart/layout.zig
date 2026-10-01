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
const layer_axis = @import("layout/layer_axis.zig");
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

    crossing.reduceCrossings(allocator, &lg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();

    var result = buildSketch(a, layout_graph, lg, opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (use_bt_mirror) {
        result = mirror.vertical(a, result, .BT) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
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
    const layer_h = try layer_axis.heights(a, lg, geom);
    const v_sp_per_gap = try layer_axis.gaps(a, graph.direction, lg, opts.v_spacing);

    const compact_x = (graph.direction == .TD) and !opts.is_direction_rotated;

    try x_assign.spread(a, graph, geom, lg, opts.h_spacing, compact_x);

    if (fans.len > 0) fan_mod.gateFanInSharedLabels(NodeGeom, fans, geom);
    if (fans.len > 0) try fan_lanes.assignLanes(NodeGeom, a, graph, lg, geom, fans, decision.bundles);

    if (fans.len > 0) fan_mod.refreshLabelWidths(graph, fans);

    layer_axis.assignY(geom, lg.layers, layer_h, v_sp_per_gap);

    try pressure.run(a, graph, lg, geom, fans, v_sp_per_gap, opts, compact_x);

    if (fans.len > 0) fan_mod.assignRoles(fans, try x_assign.centersX(a, geom));
    layer_axis.foldLayerOffsets(lg, geom, layer_h);

    const predicted_ports = try port_plan.predict(a, graph, lg, geom, decision.attachments, decision.bundles, decision.port_active);
    const supers = try a.alloc(gap_rows.Super, opts.fixed_sizes.len);
    for (opts.fixed_sizes, supers) |fixed, *sup| sup.* = .{ .node = fixed.node, .drawn = !fixed.synthetic };
    const rows = try gap_rows.buildPiece(a, graph, lg, geom, fans, decision.bundles, predicted_ports, v_sp_per_gap, supers, opts.departures);
    layer_axis.restack(lg, geom, layer_h, v_sp_per_gap, rows);

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
        bundle_plan.bundlesFromPlan(a, decision.bundles) catch edges_result.bundle_sets
    else
        edges_result.bundle_sets;
    return .{
        .bbox = bbox,
        .direction = graph.direction,
        .nodes = placements,
        .clusters = &.{},
        .edges = edges_out,
        .rails = rails_out,
        .rail_claims = edges_result.rail_claims,
        .bundles = decision.bundles,
        .bundle_sets = sketch_ports.appendPortShares(a, base_sets, edges_out) catch base_sets,
        .diagnostics = try diagnostics.toOwnedSlice(a),
        .budget = .{ .max_width = opts.max_width, .rung = opts.rung },
    };
}

fn ownFans(a: std.mem.Allocator, fans: []const fan_mod.Fan) error{OutOfMemory}![]fan_mod.Fan {
    const out = try a.dupe(fan_mod.Fan, fans);
    for (out) |*f| f.peers = try a.dupe(fan_mod.FanEdge, f.peers);
    return out;
}

test {
    _ = @import("layout/layout_test.zig");
}
