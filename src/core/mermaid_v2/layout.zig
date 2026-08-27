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
const sketch_channels = @import("sketch_channels.zig");
const sugiyama = @import("layout/sugiyama.zig");
const crossing = @import("layout/crossing.zig");
const routing = @import("layout/routing.zig");
const clusters = @import("layout/clusters.zig");
const spacing = @import("layout/spacing.zig");
const fan_mod = @import("layout/fan.zig");
const fan_lanes = @import("layout/fan_lanes.zig");
const mirror = @import("layout/mirror.zig");
const cx_mod = @import("layout/x_assign.zig");
const sizing = @import("layout/sizing.zig");
const components = @import("layout/components.zig");
const rank_grid = @import("layout/rank_grid.zig");
const chain_wrap = @import("layout/chain_wrap.zig");
const decascade = @import("layout/decascade.zig");
const join_commit = @import("layout/join_commit.zig");
const options = @import("layout/options.zig");
const ports = @import("layout/ports.zig");
const port_plan = @import("layout/port_plan.zig");

/// A caller-imposed size override for one node, keyed by SemGraph NodeId.
/// Used by the cluster driver to size a "super-node" (a subgraph seen from
/// the outer flowchart) to the bounding box of its already-laid-out child,
/// since layout cannot derive that size from a label. Defined in
/// `layout/sizing.zig`; re-exported here for callers (e.g. budget.zig).
pub const FixedSize = sizing.FixedSize;

pub const LayoutOptions = options.LayoutOptions;
pub const Justify = options.Justify;

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
    // Parallel to `lg.nodes`: the display rows of each node, computed once
    // here and reused for box size + painting.
    const node_lines = try a.alloc([]const []const u8, total);

    const is_td = graph.direction == .TD;
    const fans: []fan_mod.Fan = if (is_td) try fan_mod.detect(a, graph, lg) else &.{};
    // Synthetic motif-pack clusters are outside the flat edge-id identity
    // path just like authored clusters; no original-input permit may affect
    // their geometry before post-layout realization applies the same gate.
    const candidate_flat = opts.join_permits_flat and graph.clusters.len == 0;
    // The closure law's report-only counts ride the Sketch to telemetry: the
    // registry tags name real events only if a production render can fire them.
    // guarded-by: layout_test2.zig "a production render carries the closure law's counts on its Sketch"
    var closure: ledger.ClosureCounts = .{};
    addConstructionDiagnostics(&closure, fans);
    var candidate_joins = try join_commit.buildReported(a, graph, opts.join_permits, candidate_flat, lg.reversed_edges, opts.disable_join_realization, &closure);
    const construction_private = hasPrivatePeers(fans);
    const port_active = hasPortWork(candidate_joins) or construction_private;
    const lane_plan = try port_plan.planLanes(a, graph, lg, candidate_joins);
    const derived = if (opts.join_permits) |plan| blk: {
        if (candidate_flat and port_active) {
            const all = ports.derive(a, graph, plan.*, candidate_joins, graph.direction, lg.reversed_edges) catch &.{};
            break :blk port_plan.withoutCoRealized(a, all, candidate_joins) catch all;
        }
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
    // Inter-layer spacing depends on flow direction (TD=2 rows, LR/RL=4 cols). guarded-by: layout/layout_test.zig "inter-layer gap is 2 rows for TD but 4 columns for LR (same graph, default v_spacing)"
    const v_base: u32 = switch (graph.direction) {
        .TD => opts.v_spacing,
        .BT => unreachable,
        .LR, .RL => 4,
    };
    const v_sp_per_gap = try computeLayerSpacings(a, graph, lg, v_base);

    // Detect decision fans (TD only) and reserve one extra inter-layer row
    // per fan so the rail row has somewhere to live. Unified detection
    // returns both fan-OUT and fan-IN entries.
    // X assignment precedes row reservation: `fan_lanes` groups collinear
    // rails by their placed columns, so coordinates must exist before we decide
    // how many rail rows each gap needs. Neither assignInitialX nor the
    // barycenter sweeps read geom.y, so running them ahead of assignY leaves x
    // byte-identical to the pre-reorder pipeline.
    //
    // Drift compaction fires only for natural TD; LR/RL and the rotation rung's is_direction_rotated flag both suppress it. guarded-by: layout/layout_test.zig "drift compaction fires on natural TD but is suppressed by is_direction_rotated, and never fires for LR"
    const compact_x = (graph.direction == .TD) and !opts.is_direction_rotated;

    assignInitialX(graph, geom, lg.nodes, lg.layers, opts.h_spacing, opts.spacing_scale);
    try centerByBarycenter(a, graph, geom, lg, opts.h_spacing, .down, compact_x, opts.spacing_scale);
    try centerByBarycenter(a, graph, geom, lg, opts.h_spacing, .up, compact_x, opts.spacing_scale);

    normalizeX(geom);

    // Third .down sweep: the 2-pass (.down, .up) barycenter does not converge on fan-IN cases; re-running .down re-centers the sink onto the now-stable sources. guarded-by: layout/fan_test.zig "5-source fan-IN sink recenters onto the exact mean of its sources"
    try centerByBarycenter(a, graph, geom, lg, opts.h_spacing, .down, compact_x, opts.spacing_scale);

    normalizeX(geom);

    // Two-sided fan lane separation: when >=2 fans in one gap would fuse their
    // rails into a single bus whose union has more than one source AND more
    // than one target, that bus speaks for a pivot none of its members shares,
    // so each trunk takes its own rail row via fans[].lane and every declared
    // edge stays traceable. Single trunks and pure fan-in|out stay lane 0.
    // guarded-by: layout/fan_lanes_test.zig "incomplete overlapping fans get separate lanes"
    if (fans.len > 0) try fan_lanes.assignLanes(NodeGeom, a, graph, lg, geom, fans, candidate_joins, &closure);

    // Reserve max(lane)+1 gap rows per fan gap (extraRowsPerGap reads fans[].lane).
    // The label-feasibility gate first clears `labeled` on fans whose on-run
    // candidate is doomed (will grid-wrap / no label can ever fit), so they
    // reserve no dead label rows. guarded-by: layout/fan_test.zig "label reservation gate clears doomed fans and keeps feasible ones"
    if (v_sp_per_gap.len > 0 and fans.len > 0) {
        // The fan's reserved gap rows are a LABEL reservation, not an ON-RUN
        // one: a `.beside` fan needs them just as much, because that is where
        // its labels sit — one per dropper, x-aligned with the dropper they
        // name. Dropping them for the beside twin made it ~3 rows shorter,
        // which the height tier then bought at the price of labels stranded on
        // the rail row next to a dropper they do not belong to. The policy axis
        // is a RASTER-form axis; both twins pay the same layout reservation.
        // guarded-by: select_test3.zig "the beside twin keeps the labeled fan's reserved rows"
        fan_mod.gateLabelReservations(NodeGeom, graph, fans, geom, opts.max_width, opts.h_spacing);
        const extras = try fan_mod.extraRowsPerGap(a, lg, fans);
        for (extras, 0..) |x, i| {
            if (i < v_sp_per_gap.len) v_sp_per_gap[i] += x;
        }
    }
    for (lane_plan.extra_rows, 0..) |extra, i| if (i < v_sp_per_gap.len) {
        v_sp_per_gap[i] += extra;
    };
    // Skip-corridor headroom (TD): reserves the extra gap row a ≥2-layer edge's target layer needs for a clean vertical descent. guarded-by: layout/layout_test.zig "a skip edge reserves exactly one extra gap row above its target layer, a plain chain reserves none"
    if (is_td and v_sp_per_gap.len > 0) {
        const extras = try routing.skipCorridorExtraRows(a, lg);
        for (extras, 0..) |x, i| {
            if (i < v_sp_per_gap.len) v_sp_per_gap[i] += x;
        }
    }
    // Terminal-approach headroom (TD): a bare inter-rank gap that receives an
    // OFFSET corner-fed forward terminal gets one extra row so the arrowhead's
    // base cell can be a straight collinear stroke instead of a corner. Reads
    // the ACCUMULATED gap width (after the fan/lane/skip folds above) and tops
    // up ONLY gaps still at the bare 2-row width — a widened gap is never
    // double-counted, and the add is bounded to at most +1 per boundary.
    // Suppressed on the switch_direction rotation probe (`is_direction_rotated`):
    // a rotated layout is authored non-TD, and adding a row inside the probe
    // perturbs its height score and can flip candidate selection (GUARD 2 —
    // price the row only where TD is the FINAL direction). Same gate as the
    // other direction-dependent TD levers (compact_x, back-edge rail width).
    // guarded-by: layout/layout_test.zig "an offset adjacent terminal in a bare TD gap reserves exactly one extra row; a column-aligned terminal reserves none"
    if (is_td and !opts.is_direction_rotated and v_sp_per_gap.len > 0) {
        const extras = try routing.terminalApproachExtraRows(NodeGeom, a, graph, lg, geom);
        for (extras, 0..) |x, i| {
            if (i < v_sp_per_gap.len and x > 0 and v_sp_per_gap[i] < 3)
                v_sp_per_gap[i] += 1;
        }
    }
    assignY(geom, lg.layers, layer_h, v_sp_per_gap);

    // Flush-left justification: a pure leftward shift, so it can only narrow or hold the bbox, never widen it. guarded-by: layout/x_assign_test.zig "flushLeftRows never widens the bounding box"
    // Shared width-pressure gate for the direction-preserving TD reflow levers
    // (flush-left, component-pack, rank-grid, de-cascade). `compact_x` already
    // implies TD-and-not-rotated; false on the natural rung (byte-identical).
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
    // component (internal trunks preserved, each component stays a contiguous
    // rect).
    // No-op for single-component graphs. guarded-by: layout/components_test.zig "packComponents leaves node geometry unchanged for a single connected component"
    if (td_pressure) {
        try components.packComponents(a, graph, geom, lg);
        normalizeX(geom);
    }

    // Wide fan wrapping (TD): a high-degree fan whose peers, in a single row,
    // would blow the width budget is re-flowed into a grid of stacked rows —
    // without it the budget ladder rotates the whole diagram to LR. Fan-OUT
    // wraps on any TD rung (internally budget-gated); fan-IN additionally
    // requires `td_pressure` (which implies `is_td`) so a fan-IN that already
    // fits its width stays byte-identical. See wrapWideFanOut / wrapWideFanIn.
    if (is_td and fans.len > 0) {
        fan_mod.wrapWideFanOut(NodeGeom, fans, geom, opts.max_width, opts.h_spacing, opts.v_spacing);
        if (td_pressure) fan_mod.wrapWideFanIn(NodeGeom, fans, geom, opts.max_width, opts.h_spacing, opts.v_spacing);
        normalizeX(geom);
    }

    // Lever B: rank-grid re-flows any over-wide Sugiyama LAYER into a stacked grid, pushing lower layers down; layers a wide fan-OUT already grid-wrapped are skipped since edges re-route from final geom. guarded-by: layout/rank_grid_test.zig "rank-grid leaves a wrapped fan-OUT layer as one row but still grids an over-wide multi-pivot sibling layer"
    if (td_pressure) {
        rank_grid.reflowWideRanks(NodeGeom, lg, geom, opts.max_width, opts.h_spacing, opts.v_spacing);
        normalizeX(geom);
    }

    // Lever D: TD single-node de-cascade — slide a drifted single-node chain
    // back to the margin as a rigid unit (no-op on natural). See decascade.zig.
    if (td_pressure) {
        try decascade.deCascade(a, graph, geom, lg);
        normalizeX(geom);
    }

    // Lever C: serpentine chain-wrap. Under width pressure (chain_wrap flag,
    // set only on the `chain_wrap` rung between `wrap_labels` and
    // `switch_direction`), fold a long LR/RL chain whose flow axis busts the
    // width budget into a multi-band snake — direction-preserving, tried before
    // the 90° rotation. Runs in INTERNAL pre-transpose coordinates (here, before
    // applyDirection): the flow axis is internal-y and maps to display width for
    // horizontal flows, so folding it relieves the overflow. A no-op for TD/BT
    // and when the flag is off, so fitting seeds / lower rungs stay
    // byte-identical. Forward + back edges re-route from the final geom
    // positions downstream (routing.buildEdges / back_edges.zig), so no rail is
    // synthesized here.
    if (opts.chain_wrap) {
        try chain_wrap.foldChain(NodeGeom, a, graph, lg, geom, opts.max_width, graph.direction, opts.chain_wrap_negotiated);
        normalizeX(geom);
    }

    if (fans.len > 0) fan_mod.assignRoles(fans, try centersX(a, geom));

    mirror.applyDirection(NodeGeom, geom, graph.direction);

    const placements = try buildPlacements(a, graph, lg, geom, node_lines);
    const allocated_ports = try port_plan.allocate(a, graph, placements, derived, candidate_joins, lane_plan, opts.rung);
    candidate_joins.terminal_ports = allocated_ports.terminals;
    const edges_result = if (port_active)
        try routing.buildEdgesWithPlan(a, graph, lg, geom, placements, fans, candidate_joins, allocated_ports, opts.chain_wrap)
    else
        try routing.buildEdges(a, graph, lg, geom, placements, fans, opts.chain_wrap);
    const edges_out = edges_result.edges;
    const clusters_out = try clusters.buildClusters(a, graph, placements, opts.node_padding);

    // Arm the back-edge return-rail width lever only for AUTHORED top-down flows; `!is_direction_rotated` excludes an LR seed's TD rotation probe so the lever never flips chain-wrap acceptance. guarded-by: layout/clusters_test.zig "the back-edge rail label lever fires for authored TD but not for a rotation-probe TD"
    const rail_lever = (opts.spacing_scale > 0) and
        (graph.direction == .TD) and !opts.is_direction_rotated;
    const bbox = clusters.computeBbox(placements, edges_out, clusters_out, edges_result.polylines, edges_result.busbars, rail_lever, opts.max_width);
    var diagnostics: std.ArrayListUnmanaged(sketch.Diagnostic) = .empty;
    if (bbox.w > opts.max_width) {
        try diagnostics.append(a, .{ .width_overflow = .{
            .excess = bbox.w - opts.max_width,
            .in_cluster = null,
        } });
    }
    // forced_label_wrap: a node whose painted line count exceeds its author
    // hard-segment count was soft-wrapped under budget pressure. Only the
    // wrap_labels rung can trigger this (max_label_width set).
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

    // Freeze the bus-bars AFTER computeBbox's shift pass — their slices still alias the shifted mutable buffers before that point. guarded-by: layout/fan_rail_test.zig "busbar taps stay in sync with their target node's post-shift position"
    const busbars_out = try a.alloc(sketch.Rail, edges_result.busbars.len);
    for (edges_result.busbars, busbars_out) |b, *out| out.* = b.busbar;

    // A discharged edge is rendered by a rail's crossbar, so owning an
    // EdgePath too would state its relation twice. Measured over the sketch
    // this call is finalizing — the artifact, never a re-derivation.
    const routed = try a.alloc(ledger.EdgeId, edges_out.len);
    for (edges_out, routed) |e, *slot| slot.* = e.id;
    closure.co_double_discharge = ledger.doubleDischarged(candidate_joins.co_realized, routed);

    var out = sketch.Sketch{
        .bbox = bbox,
        .direction = graph.direction, // BT was canonicalized to TD above; unreachable here
        .nodes = placements,
        .clusters = clusters_out,
        .edges = edges_out,
        .busbars = busbars_out,
        .rail_claims = edges_result.rail_claims,
        .joins = candidate_joins,
        .closure = closure,
        // Fan-derived sets PLUS the port shares read back off the final
        // polylines: the port plan can route several edges through one
        // perimeter port and records nothing, so the only declaration of that
        // legal ink sharing is the geometry itself. Appended, never
        // substituted (sketch_ports.appendPortShares).
        // guarded-by: sketch_ports_test.zig "shared departure port groups its edges"
        .co_sets = sketch_ports.appendPortShares(a, edges_result.co_sets, edges_out) catch edges_result.co_sets,
        .diagnostics = try diagnostics.toOwnedSlice(a),
        .budget = .{ .max_width = opts.max_width, .rung = opts.rung },
        .label_policy = opts.label_policy,
    };
    // The co-set list is final here, so this is where it becomes a roster: one
    // identity per channel, and every rail stamped with the one it rides.
    sketch_channels.stamp(a, &out);
    return out;
}

fn hasPortWork(joins: ledger.RealizedJoins) bool {
    if (joins.selected_joins.len != 0) return true;
    for (joins.memberships) |membership| {
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

// ===================================================================
// Sizing — see layout/sizing.zig
// ===================================================================

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

fn assignY(geom: []NodeGeom, layers: [][]u32, layer_h: []const u32, v_sp_per_gap: []const u32) void {
    var cursor: i32 = 0;
    for (layers, 0..) |row, li| {
        for (row) |idx| geom[idx].y = cursor;
        const gap: u32 = if (li < v_sp_per_gap.len) v_sp_per_gap[li] else 0;
        cursor += @as(i32, @intCast(layer_h[li])) + @as(i32, @intCast(gap));
    }
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

// ===================================================================
// X assignment — see layout/x_assign.zig
// ===================================================================

const assignInitialX = cx_mod.assignInitialX;
const centerByBarycenter = cx_mod.centerByBarycenter;
const normalizeX = cx_mod.normalizeX;
const centersX = cx_mod.centersX;
const flushLeftRows = cx_mod.flushLeftRows;

// ===================================================================
// Placements — see layout/sizing.zig (also owns realNode and the
// node_lines channel placements reuse).
// ===================================================================

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
