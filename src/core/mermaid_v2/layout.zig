//! Layout stage orchestrator — SemGraph → Sketch.
//!
//! Runs Sugiyama layer assignment + crossing reduction, then coordinate
//! assignment and Sketch construction. Edge routing delegates to
//! `layout/routing.zig`, cluster frames to `layout/clusters.zig`.
//! Direction: internal layout is top-to-bottom; BT canonicalizes through TD
//! then mirrors; LR/RL transpose axes. Lint zone: may import std, prim,
//! sem_graph, sketch, and sibling layout/* files only.

const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");
const sg = @import("sem_graph.zig");
const sketch = @import("sketch.zig");
const sketch_ports = @import("sketch_ports.zig");
const sketch_bundles = @import("sketch_bundles.zig");
const sugiyama = @import("layout/sugiyama.zig");
const crossing = @import("layout/crossing.zig");
const routing = @import("layout/routing.zig");
const clusters = @import("layout/clusters.zig");
const spacing = @import("layout/spacing.zig");
const fan_mod = @import("layout/fan.zig");
const fan_gate = @import("layout/fan_gate.zig");
const fan_lanes = @import("layout/fan_lanes.zig");
const gap_rows = @import("layout/gap_rows.zig");
const mirror = @import("layout/mirror.zig");
const cx_mod = @import("layout/x_assign.zig");
const sizing = @import("layout/sizing.zig");
const components = @import("layout/components.zig");
const rank_grid = @import("layout/rank_grid.zig");
const decascade = @import("layout/decascade.zig");
const bundle_commit = @import("layout/bundle_commit.zig");
const options = @import("layout/options.zig");
const layer_axis = @import("layout/layer_axis.zig");
const ports = @import("layout/ports.zig");
const port_plan = @import("layout/port_plan.zig");

/// A caller-imposed size override for one node, keyed by SemGraph NodeId.
/// Used by the cluster driver to size a "super-node" (a subgraph seen from
/// the outer flowchart) to the bounding box of its already-laid-out child,
/// since layout cannot derive that size from a label. Defined in
/// `layout/sizing.zig`; re-exported here for callers (e.g. budget.zig).
pub const FixedSize = sizing.FixedSize;

pub const LayoutOptions = options.LayoutOptions;

pub const CoordsError = error{
    OutOfMemory,
    EmptyGraph,
};

pub const NodeGeom = routing.NodeGeom;

/// Pipeline entry: SemGraph → Sketch. Internally:
///   1. sugiyama.assignLayers     (cycle removal + layer assignment)
///   2. crossing.reduceCrossings  (24-iter barycenter)
///   3. coords:                   (this file) coord assignment + Sketch build
///
/// Returns a Sketch with an owning arena; caller frees via
/// `result.deinit(allocator)`. Does NOT call validate.zig.
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

    crossing.reduceCrossings(allocator, &lg, .{}) catch |err| switch (err) {
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

    const is_td = graph.direction == .TD;
    const fans_detected: []fan_mod.Fan = if (is_td) try fan_mod.detect(a, graph, lg) else &.{};
    // The rail construction's report-only counts ride the Sketch to telemetry.
    // @guarded-by: layout_test2.zig "construction-time rail exclusions are reported on the shipped Sketch"
    var closure: ledger.ClosureCounts = .{};
    addConstructionDiagnostics(&closure, fans_detected);
    const effective_plan: ?ledger.BundlePermits = try bundle_commit.effectivePlan(a, graph, opts.bundle_permits);
    const plan_ref: ?*const ledger.BundlePermits = if (effective_plan) |*p| p else null;
    var candidate_bundles = try bundle_commit.buildReported(a, graph, plan_ref, lg.reversed_edges, try longEdges(a, lg));
    // A long peer taps a rail or nothing: the per-peer polyline path assumes
    // a next-layer leaf. Where the plan did not select the fan's bundle, a
    // fan holding a long peer degrades to what it was before long peers
    // existed — no fan, private routing.
    // @guarded-by: layout/port_plan_test.zig "a fan with a long peer the plan did not select degrades to private routing"
    const fans = try fan_gate.keepRealizableLong(a, fans_detected, candidate_bundles);
    const construction_private = hasPrivatePeers(fans);
    const port_active = hasPortWork(candidate_bundles) or construction_private;
    const derived = if (plan_ref) |plan| blk: {
        if (port_active) break :blk ports.derive(a, graph, plan.*, candidate_bundles, graph.direction, lg.reversed_edges) catch &.{};
        if (construction_private) break :blk port_plan.deriveFanAttachments(a, graph, graph.direction, lg.reversed_edges, fans) catch &.{};
        break :blk &.{};
    } else if (construction_private)
        port_plan.deriveFanAttachments(a, graph, graph.direction, lg.reversed_edges, fans) catch &.{}
    else
        &.{};
    try sizeNodes(a, graph, lg, geom, opts.node_padding, opts.fixed_sizes, opts.max_label_width, node_lines);
    sizing.applyPortDemand(graph, lg, geom, derived);
    const layer_count: u32 = @intCast(lg.layers.len);
    const layer_h = try computeLayerHeights(a, lg, geom, layer_count);
    // Inter-layer spacing depends on flow direction (TD=2 rows, LR/RL=4 cols). @guarded-by: layout/layout_test.zig "inter-layer gap is 2 rows for TD but 4 columns for LR (same graph, default v_spacing)"
    const v_base: u32 = switch (graph.direction) {
        .TD => opts.v_spacing,
        .BT => unreachable,
        .LR, .RL => 4,
    };
    const v_sp_per_gap = try computeLayerSpacings(a, graph, lg, v_base);

    // X assignment precedes row reservation: the row ledger packs every
    // gap's runs by their placed columns, so coordinates must exist before
    // we decide how many rows each gap needs. Neither assignInitialX nor the
    // barycenter sweeps read geom.y, so running them ahead of assignY leaves x
    // byte-identical to the pre-reorder pipeline.
    //
    // Drift compaction fires only for natural TD; LR/RL and the rotation rung's is_direction_rotated flag both suppress it. @guarded-by: layout/layout_test.zig "drift compaction fires on natural TD but is suppressed by is_direction_rotated, and never fires for LR"
    const compact_x = (graph.direction == .TD) and !opts.is_direction_rotated;

    assignInitialX(graph, geom, lg.nodes, lg.layers, opts.h_spacing, opts.spacing_scale);
    try centerByBarycenter(a, graph, geom, lg, opts.h_spacing, .down, compact_x, opts.spacing_scale);
    try centerByBarycenter(a, graph, geom, lg, opts.h_spacing, .up, compact_x, opts.spacing_scale);

    normalizeX(geom);

    // Third .down sweep: the 2-pass (.down, .up) barycenter does not converge on fan-IN cases; re-running .down re-centers the sink onto the now-stable sources. @guarded-by: layout/fan_test.zig "5-source fan-IN sink recenters onto the exact mean of its sources"
    try centerByBarycenter(a, graph, geom, lg, opts.h_spacing, .down, compact_x, opts.spacing_scale);

    normalizeX(geom);

    // Two-sided fan run separation: when >=2 fans in one gap would fuse their
    // rails into a single run whose union has more than one source AND more
    // than one target, that run speaks for a pivot none of its members shares,
    // so each rail takes its own run class via fans[].lane and every declared
    // edge stays traceable. Single rails and pure fan-in|out stay class 0.
    // @guarded-by: layout/fan_lanes_test.zig "incomplete overlapping fans get separate lanes"
    if (fans.len > 0) fan_mod.gateFanInSharedLabels(NodeGeom, fans, geom);
    if (fans.len > 0) try fan_lanes.assignLanes(NodeGeom, a, graph, lg, geom, fans, candidate_bundles);

    // A fan's label band is a LABEL claim: that is where its labels sit — one
    // per dropper, x-aligned with the dropper they name — so the rows are
    // claimed whatever form the raster gives the labels.
    if (fans.len > 0) fan_mod.refreshLabelWidths(graph, fans);

    // The levers read and move the layer axis — a grid stacks a layer's
    // nodes into sub-rows — so the layers are laid out once at base
    // spacing for them, and their result folded back into per-node
    // offsets inside each layer before the ledger reads the geometry.
    layer_axis.assignY(geom, lg.layers, layer_h, v_sp_per_gap);

    // Flush-left justification: a pure leftward shift, so it can only narrow or hold the bbox, never widen it. @guarded-by: layout/x_assign_test.zig "flushLeftRows never widens the bounding box"
    const td_pressure = opts.justify == .flush_left and compact_x;
    if (td_pressure) {
        flushLeftRows(graph, geom, lg);
        normalizeX(geom);
    }

    // Lever A: component-packing. Under the same width pressure as flush-left
    // (justify == .flush_left, TD-only via compact_x), re-slot each
    // weakly-connected component into a tight left-justified column band so the
    // diagram width collapses to ~the widest single component instead of the
    // sum of every component's cross-aligned drift. Pure x-translation per
    // component (internal rails preserved, each component stays a contiguous
    // rect).
    // No-op for single-component graphs. @guarded-by: layout/components_test.zig "packComponents leaves node geometry unchanged for a single connected component"
    if (td_pressure) {
        try components.packComponents(a, graph, geom, lg);
        normalizeX(geom);
    }

    if (is_td and fans.len > 0) {
        fan_mod.wrapWideFanOut(NodeGeom, fans, geom, opts.max_width, opts.h_spacing, opts.v_spacing);
        if (td_pressure) fan_mod.wrapWideFanIn(NodeGeom, fans, geom, opts.max_width, opts.h_spacing, opts.v_spacing);
        normalizeX(geom);
    }

    // Lever B: rank-grid re-flows any over-wide Sugiyama LAYER into a stacked grid, pushing lower layers down; layers a wide fan-OUT already grid-wrapped are skipped since edges re-route from final geom. @guarded-by: layout/rank_grid_test.zig "rank-grid leaves a wrapped fan-OUT layer as one row but still grids an over-wide multi-pivot sibling layer"
    if (td_pressure) {
        rank_grid.reflowWideRanks(NodeGeom, lg, geom, opts.max_width, opts.h_spacing, opts.v_spacing);
        normalizeX(geom);
    }

    // Lever D: the rows a de-cascaded head's entry corridor asks for join
    // that gap's base spacing, which the ledger packs into.
    if (td_pressure) {
        if (try decascade.deCascade(a, graph, geom, lg)) |drop| v_sp_per_gap[drop.gap] += drop.rows;
        normalizeX(geom);
    }

    if (fans.len > 0) fan_mod.assignRoles(fans, try centersX(a, geom));
    layer_axis.foldLayerOffsets(lg, geom, layer_h);

    // The row ledger: every run the routers will paint in a gap — fan
    // rails and per-peer runs, private jogs, skip-corridor entries and
    // exits, member-stroke jogs — claims its rows against the ports the
    // allocation will hand out, and the gap grows by exactly the rows the
    // packed claims need. Nothing else adds a row, and every router reads
    // its row back from this ledger.
    // @guarded-by: layout/gap_rows_test.zig "four disjoint realized rails share one row and the gap is rail, run, head"
    // @guarded-by: layout/gap_rows_test.zig "a skip edge claims one row in the gap above its target layer, a plain chain claims none"
    // @guarded-by: layout/gap_rows_test.zig "an offset decorated terminal claims one row; a column-aligned or undecorated one claims none"
    const predicted_ports = try gap_rows.predictPorts(NodeGeom, a, graph, lg, geom, derived, candidate_bundles, port_active, opts.rung);
    const supers = try a.alloc(gap_rows.Super, opts.fixed_sizes.len);
    for (opts.fixed_sizes, supers) |fixed, *sup| sup.* = .{ .node = fixed.node, .drawn = !fixed.synthetic };
    const rows = try gap_rows.buildPiece(NodeGeom, a, graph, lg, geom, fans, candidate_bundles, predicted_ports, v_sp_per_gap, supers, opts.departures);
    for (v_sp_per_gap, 0..) |*g, i| g.* += rows.extraRows(i);
    layer_axis.growSubGaps(lg, geom, layer_h, rows);
    layer_axis.assignY(geom, lg.layers, layer_h, v_sp_per_gap);
    const layer_top = try layer_axis.layerTops(a, geom, lg.layers);
    // The gap geometry the painted-ink invariant reads back: each gap's
    // first cell beside its two layers — a sub-gap's beside its two
    // sub-rows — in the frame the routers paint in.
    // @guarded-by: ledger/invariants.zig "the painted-ink invariant counts a run on a row no claim of its edge stands on"
    // In an RL piece layer g is the target side of gap g, so its near wall
    // is the arrival cell beside layer g and the rows count toward layer g+1.
    const walls = try a.alloc(gap_rows.GapWalls, rows.gaps.len);
    for (walls[0..v_sp_per_gap.len], 0..) |*w, g| {
        var below: i32 = std.math.minInt(i32);
        var above: i32 = std.math.maxInt(i32);
        if (g + 1 < lg.layers.len) {
            for (lg.layers[g]) |idx| below = @max(below, geom[idx].y + @as(i32, @intCast(geom[idx].h)));
            for (lg.layers[g + 1]) |idx| above = @min(above, geom[idx].y - 1);
        }
        w.* = if (graph.direction == .RL) .{ .far = above, .near = below } else .{ .far = below, .near = above };
    }
    for (rows.sub_gaps) |sgp| walls[sgp.gap] = .{ .far = layer_top[sgp.layer] + sgp.far, .near = layer_top[sgp.layer] + sgp.top - 1 };
    const node_of = try a.alloc(u32, lg.nodes.len);
    for (lg.nodes, node_of) |ln, *id| id.* = switch (ln) {
        .real => |nid| nid,
        .virtual => sg.SENTINEL,
    };

    mirror.applyDirection(NodeGeom, geom, graph.direction);

    const placements = try buildPlacements(a, graph, lg, geom, node_lines);
    const allocated_ports = try port_plan.allocate(a, graph, placements, derived, candidate_bundles, opts.rung);
    candidate_bundles.terminal_ports = allocated_ports.terminals;
    const edges_result = if (port_active)
        try routing.buildEdgesWithPlan(a, graph, lg, geom, placements, fans, candidate_bundles, allocated_ports, rows)
    else
        try routing.buildEdges(a, graph, lg, geom, placements, fans, rows);
    const edges_out = edges_result.edges;
    const clusters_out = try clusters.buildClusters(a, graph, placements, opts.node_padding);

    // Arm the back-edge return-rail width lever only for AUTHORED top-down flows; `!is_direction_rotated` excludes an LR seed's TD rotation so the lever never changes a rotated candidate's fit verdict. @guarded-by: layout/clusters_test.zig "the back-edge rail label lever fires for authored TD but not for a rotated TD"
    const rail_lever = (opts.spacing_scale > 0) and
        (graph.direction == .TD) and !opts.is_direction_rotated;
    const bbox = clusters.computeBbox(placements, edges_out, clusters_out, edges_result.polylines, edges_result.rails, rail_lever, opts.max_width);
    var diagnostics: std.ArrayListUnmanaged(sketch.Diagnostic) = .empty;
    if (bbox.w > opts.max_width) {
        try diagnostics.append(a, .{ .width_overflow = .{
            .excess = bbox.w - opts.max_width,
            .in_cluster = null,
        } });
    }
    if (opts.max_label_width != null) {
        for (lg.nodes, 0..) |ln, i| {
            const nid = switch (ln) {
                .real => |id| id,
                .virtual => continue,
            };
            const hard_segments = hardSegmentCount(realNode(graph, nid).label);
            if (node_lines[i].len > hard_segments) {
                try diagnostics.append(a, .{ .forced_label_wrap = .{ .node = nid } });
            }
        }
    }

    // Freeze the rails AFTER computeBbox's shift pass — their slices still alias the shifted mutable buffers before that point. @guarded-by: layout/fan_rail_test.zig "rail taps stay in sync with their target node's post-shift position"
    const rails_out = try a.alloc(sketch.Rail, edges_result.rails.len);
    for (edges_result.rails, rails_out) |b, *out| out.* = b.rail;

    // The plan this layout committed authorizes the bundle sets: a flat plan
    // always (a plan that selected no bundle authorizes none), a piece plan
    // once it selected one. The fan-derived sets are the candidate's only
    // record where no plan applied — a motif-packed candidate, whose
    // synthetic frames put it off the identity path, or a piece whose plan
    // selected nothing.
    const plan_realized = if (plan_ref) |p|
        p.scope == .flat or (p.scope == .piece and candidate_bundles.selected_bundles.len != 0)
    else
        false;
    const base_sets = if (plan_realized)
        ledger.bundlesFromPlan(a, candidate_bundles) catch edges_result.bundle_sets
    else
        edges_result.bundle_sets;
    var out = sketch.Sketch{
        .bbox = bbox,
        .direction = graph.direction,
        .nodes = placements,
        .clusters = clusters_out,
        .edges = edges_out,
        .rails = rails_out,
        .rail_claims = edges_result.rail_claims,
        .bundles = candidate_bundles,
        .closure = closure,
        // The gap account the invariant reads: what assignY placed against what the ledger holds.
        // @guarded-by: ledger/invariants.zig "the gap invariant counts a spacing the ledger did not ask for and a row no claim stands on"
        .gap_rows = try rows.records(a, v_sp_per_gap, walls, node_of),
        // Fan-derived sets PLUS the port shares read back off the final
        // polylines: the port plan can route several edges through one
        // perimeter port and records nothing, so the only declaration of that
        // legal ink sharing is the geometry itself. Appended, never
        // substituted (sketch_ports.appendPortShares).
        // @guarded-by: sketch_ports_test.zig "shared departure port groups its edges"
        .bundle_sets = sketch_ports.appendPortShares(a, base_sets, edges_out) catch base_sets,
        .diagnostics = try diagnostics.toOwnedSlice(a),
        .budget = .{ .max_width = opts.max_width, .rung = opts.rung },
    };
    sketch_bundles.stamp(a, &out);
    return out;
}

/// Edges whose ends sit more than one layer apart (they route through a
/// virtual node): the members a rail may hold at both ends.
fn longEdges(a: std.mem.Allocator, lg: sugiyama.LayeredGraph) error{OutOfMemory}![]const ledger.EdgeId {
    var out: std.ArrayListUnmanaged(ledger.EdgeId) = .empty;
    for (lg.nodes) |n| switch (n) {
        .virtual => |v| if (v.index == 0) try out.append(a, v.edge),
        .real => {},
    };
    return out.toOwnedSlice(a);
}

fn hasPortWork(bundles: ledger.RealizedBundles) bool {
    if (bundles.selected_bundles.len != 0) return true;
    for (bundles.memberships) |membership| {
        inline for ([2]?ledger.MembershipDisposition{ membership.source, membership.target }) |disposition| {
            if (disposition) |value| if (value == .independent) return true;
        }
    }
    return false;
}

fn addConstructionDiagnostics(report: *ledger.ClosureCounts, fans: []const fan_mod.Fan) void {
    for (fans) |fan| {
        if (fan.construction_deco_mixed) report.rail_deco_mixed += 1;
        if (fan.construction_style_mixed) report.rail_member_style_mixed += 1;
        if (fan.construction_star_violation) report.rail_star_violation += 1;
    }
}

fn hasPrivatePeers(fans: []const fan_mod.Fan) bool {
    for (fans) |f| for (f.peers) |peer| if (!peer.shared) return true;
    return false;
}

const sizeNodes = sizing.sizeNodes;
const realNode = sizing.realNode;

/// Number of author hard-break segments in `label` (one + the count of
/// `prim.LINE_BREAK` sentinels). Used to tell soft wrap apart from hard
/// breaks for the `forced_label_wrap` diagnostic.
fn hardSegmentCount(label: []const u8) usize {
    var n: usize = 1;
    for (label) |c| {
        if (c == prim.LINE_BREAK) n += 1;
    }
    return n;
}

fn computeLayerHeights(
    a: std.mem.Allocator,
    lg: sugiyama.LayeredGraph,
    geom: []NodeGeom,
    layer_count: u32,
) error{OutOfMemory}![]u32 {
    const layer_h = try a.alloc(u32, layer_count);
    @memset(layer_h, 0);
    for (lg.layers, 0..) |row, li| {
        const lu: u32 = @intCast(li);
        for (row) |idx| {
            geom[idx].layer = lu;
            if (geom[idx].h > layer_h[lu]) layer_h[lu] = geom[idx].h;
        }
    }
    return layer_h;
}

fn computeLayerSpacings(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    base: u32,
) error{OutOfMemory}![]u32 {
    if (lg.layers.len == 0) return try a.alloc(u32, 0);
    const gaps = try a.alloc(u32, lg.layers.len - 1);
    var li: usize = 0;
    while (li + 1 < lg.layers.len) : (li += 1) {
        gaps[li] = spacing.interLayerSpacing(graph, lg, @intCast(li), @intCast(li + 1), base);
    }
    return gaps;
}

const assignInitialX = cx_mod.assignInitialX;
const centerByBarycenter = cx_mod.centerByBarycenter;
const normalizeX = cx_mod.normalizeX;
const centersX = cx_mod.centersX;
const flushLeftRows = cx_mod.flushLeftRows;

const buildPlacements = sizing.buildPlacements;

test {
    _ = @import("layout/layout_test.zig");
    _ = @import("layout/layout_test2.zig");
}

test "construction diagnostics do not alias decoration and style" {
    const fans = [_]fan_mod.Fan{
        .{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &.{}, .construction_style_mixed = true },
        .{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &.{}, .construction_deco_mixed = true },
        .{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &.{}, .construction_deco_mixed = true, .construction_style_mixed = true },
        .{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &.{} },
    };
    var report: ledger.ClosureCounts = .{};
    addConstructionDiagnostics(&report, &fans);
    try std.testing.expectEqual(@as(u32, 2), report.rail_deco_mixed);
    try std.testing.expectEqual(@as(u32, 2), report.rail_member_style_mixed);
}
