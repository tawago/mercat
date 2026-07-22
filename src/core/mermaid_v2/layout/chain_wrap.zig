//! Lever C — serpentine chain-wrap for `layout.zig`: folds Sugiyama layers
//! along the flow axis into bands so LR/RL chains trade width for height
//! while preserving direction. Runs in INTERNAL pre-`applyDirection` coords
//! (y = flow axis, x = cross axis); no-op for TD/BT (that class of overflow
//! is owned by Lever B / edge levers instead). Greedy one-pass: measures
//! layer extents, breaks bands at budget, repositions node geom in place.
//! `negotiated=true` swaps the fixed `FLOW_RAIL_MARGIN` for measured
//! back-edge gutter demand (`bandMargin`). Imports (layout/ zone): `std`,
//! `../sem_graph.zig`, `sugiyama.zig`, `lanes.zig`; NodeGeom supplied via
//! comptime `G`.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const lanes = @import("lanes.zig");

/// Gap (in internal cells) inserted between two bands along the cross axis so
/// the carriage-return edge has a clear lane and adjacent bands' boxes never
/// touch. After the LR/RL transpose this becomes vertical whitespace between
/// the snake's rows.
const BAND_CROSS_GAP: i32 = 3;

/// Flow-axis safety margin (cells) shaved off the break budget for edge
/// chrome (carriage-return arrowhead, back-edge rail) the greedy node-extent
/// measurement can't see ahead of routing; a fixed function of the budget,
/// never of any seed identity. // guarded-by: chain_wrap.zig "negotiated fold: measured 1-lane margin admits the layer the blind margin rejects"
const FLOW_RAIL_MARGIN: i32 = 2;

/// Negotiated mode: the natural (unstacked) chrome one straddling back-edge
/// rail wants just past the band content — the flow-axis analogue of
/// back_edges' RAIL_PAD. One cell; stacked lanes step outward from it.
const NEGOTIATED_RAIL_BASE: i32 = 1;

/// Negotiated mode: gap between stacked rail lanes (mirrors back_edges'
/// RAIL_STACK_GAP so the fold reserves what the router will actually pack).
const NEGOTIATED_STACK_GAP: i32 = 1;

/// One back-edge's flow-axis extent in LAYER-INDEX space: the min/max layer
/// of its two endpoints. Pub so tests can hand-build span sets.
pub const BackSpan = struct { lo: u32, hi: u32 };

/// Layer spans of every reversed (cycle-closing) edge of `graph`, mirroring
/// how back_edges.zig builds its rail Items (lo/hi = spanned layer range)
/// but WITHOUT importing routing: reversal is read off `lg.reversed_edges`
/// directly. Self-loops are skipped (routed as lollipops, never rails).
fn collectBackSpans(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
) error{OutOfMemory}![]const BackSpan {
    if (lg.reversed_edges.len == 0) return &.{};
    // Layer of each flat node index, from the layer lists themselves (G is
    // not required to expose a `layer` field).
    const layer_of = try a.alloc(u32, lg.nodes.len);
    defer a.free(layer_of);
    for (lg.layers, 0..) |layer, li| {
        for (layer) |idx| layer_of[idx] = @intCast(li);
    }
    var spans: std.ArrayListUnmanaged(BackSpan) = .empty;
    for (graph.edges) |e| {
        if (e.from == e.to) continue;
        if (!isReversedEdge(lg, e.id)) continue;
        const si = lg.real_index.get(e.from) orelse continue;
        const di = lg.real_index.get(e.to) orelse continue;
        const sl = layer_of[si];
        const dl = layer_of[di];
        try spans.append(a, .{ .lo = @min(sl, dl), .hi = @max(sl, dl) });
    }
    return spans.toOwnedSlice(a);
}

fn isReversedEdge(lg: sugiyama.LayeredGraph, eid: sg.EdgeId) bool {
    for (lg.reversed_edges) |r| {
        if (r == eid) return true;
    }
    return false;
}

/// MEASURED flow-axis reservation for a hypothetical band covering layers
/// [first, last] (inclusive): every back-edge span overlapping the band
/// demands one rail lane of chrome (base = NEGOTIATED_RAIL_BASE);
/// `lanes.gutter` packs them (span-disjoint demands share a lane) and the
/// outermost lane position IS the reservation. Zero when nothing straddles
/// the band — that is the negotiated win over the blind FLOW_RAIL_MARGIN.
pub fn bandMargin(
    a: std.mem.Allocator,
    spans: []const BackSpan,
    first: u32,
    last: u32,
) error{OutOfMemory}!i32 {
    var demands: std.ArrayListUnmanaged(lanes.Demand) = .empty;
    defer demands.deinit(a);
    for (spans) |sp| {
        if (sp.hi < first or sp.lo > last) continue; // disjoint from band
        try demands.append(a, .{ .lo = sp.lo, .hi = sp.hi, .base = NEGOTIATED_RAIL_BASE });
    }
    const g = try lanes.gutter(a, demands.items, NEGOTIATED_STACK_GAP);
    return g.outermost;
}

/// Fold the layer stack of `lg` into a multi-band serpentine so the flow axis
/// fits within `budget`. `geom` is parallel to `lg.nodes`; `G` must expose
/// `x: i32, y: i32, w: u32, h: u32` fields (NodeGeom). `dir` is the SemGraph's
/// DECLARED direction (BT is already canonicalized to TD by the caller before
/// this point, so only TD/LR/RL are seen here). `negotiated` selects the
/// measured per-band gutter reservation (see header); false keeps the blind
/// FLOW_RAIL_MARGIN path byte-identical.
///
/// No-op (geom untouched) when:
///   * the direction is vertical (TD) — folding the flow axis does not relieve
///     a width overflow there; that is a wide-rank / rail problem (Lever B),
///   * the whole chain already fits the budget along the flow axis, or
///   * there is only one layer (nothing to fold).
///
/// Mutates `geom` in place. Emits no rails: forward and back edges re-route
/// from the final geom positions downstream.
pub fn foldChain(
    comptime G: type,
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []G,
    budget: u32,
    dir: sg.Direction,
    negotiated: bool,
) error{OutOfMemory}!void {
    if (dir != .LR and dir != .RL) return;
    if (lg.layers.len < 2) return;

    // Per-layer flow-axis extent, gap read straight from geom (respects fan / skip-corridor headroom `assignY` baked in). // guarded-by: chain_wrap.zig "fold preserves irregular fan/skip-corridor gaps within a band (not renormalized)"
    var layer_top: [256]i32 = undefined;
    var layer_bot: [256]i32 = undefined;
    const nl = lg.layers.len;
    if (nl > layer_top.len) return; // pathologically deep; leave untouched.
    for (lg.layers, 0..) |layer, li| {
        var top: i32 = std.math.maxInt(i32);
        var bot: i32 = std.math.minInt(i32);
        for (layer) |idx| {
            const g = geom[idx];
            if (g.y < top) top = g.y;
            const b = g.y + @as(i32, @intCast(g.h));
            if (b > bot) bot = b;
        }
        if (top == std.math.maxInt(i32)) {
            // Empty layer (no nodes): collapse to a zero-extent band slot.
            top = if (li == 0) 0 else layer_bot[li - 1];
            bot = top;
        }
        layer_top[li] = top;
        layer_bot[li] = bot;
    }

    const chain_span: i32 = layer_bot[nl - 1] - layer_top[0];
    if (chain_span <= @as(i32, @intCast(budget))) return; // already fits.

    // Greedy band assignment: sweep layers, breaking to a new band whenever the
    // running band extent would exceed budget; a single layer wider than budget overflows irreducibly, alone. // guarded-by: chain_wrap.zig "a single layer wider than the budget stays alone in its own band"
    var band_of: [256]u32 = undefined;
    var band_count: u32 = 0;
    var band_start_top: i32 = layer_top[0];
    // Negotiated mode measures each candidate band's actual back-edge gutter
    // demand; the blind path shaves the fixed FLOW_RAIL_MARGIN off every band.
    const back_spans: ?[]const BackSpan = if (negotiated)
        try collectBackSpans(a, graph, lg)
    else
        null;
    {
        var li: usize = 0;
        var band_first_layer: u32 = 0;
        while (li < nl) : (li += 1) {
            const this_bot = layer_bot[li];
            const extent_if_kept = this_bot - band_start_top;
            const is_first_in_band = (li == 0) or (band_of[li - 1] != band_count);
            if (!is_first_in_band) {
                // Margin for the band as it would stand INCLUDING this layer; a band's first layer is never broken away. // guarded-by: chain_wrap.zig "a band's first layer is never evicted by the margin check"
                const margin: i32 = if (back_spans) |spans|
                    try bandMargin(a, spans, band_first_layer, @intCast(li))
                else
                    FLOW_RAIL_MARGIN;
                if (extent_if_kept > @as(i32, @intCast(budget)) - margin) {
                    // Carriage-return: this layer opens a new band.
                    band_count += 1;
                    band_start_top = layer_top[li];
                    band_first_layer = @intCast(li);
                }
            }
            band_of[li] = band_count;
        }
        band_count += 1; // band_count was a 0-based max index; make it a count.
    }
    if (band_count < 2) return; // everything fit in one band after all.

    // Per-band flow origin (the internal-y of each band's first layer, used to
    // rebase that band's layers to start at the band's cross row) and per-band
    // cross extent (max box width across the band, to stack bands without
    // overlap along the cross axis).
    var band_origin: [256]i32 = undefined;
    var band_cross_extent: [256]i32 = undefined;
    @memset(band_cross_extent[0..band_count], 0);
    {
        var li: usize = 0;
        var prev_band: i32 = -1;
        while (li < nl) : (li += 1) {
            const b = band_of[li];
            if (@as(i32, @intCast(b)) != prev_band) {
                band_origin[b] = layer_top[li];
                prev_band = @intCast(b);
            }
        }
    }
    // Cross extent per band = rightmost real box edge − leftmost, over every
    // node in the band's layers.
    {
        var li: usize = 0;
        while (li < nl) : (li += 1) {
            const b = band_of[li];
            for (lg.layers[li]) |idx| {
                const g = geom[idx];
                const right = g.x + @as(i32, @intCast(g.w));
                if (right > band_cross_extent[b]) band_cross_extent[b] = right;
            }
        }
    }

    // Per-band cross base: band 0 sits at 0; a single forward prefix sum pushes each later band past the previous bands' widest cross extent plus a gap lane. // guarded-by: chain_wrap.zig "band_cross_base prefix sum stays exact across many bands (no unbounded growth)"
    var band_cross_base: [256]i32 = undefined;
    band_cross_base[0] = 0;
    {
        var b: u32 = 1;
        while (b < band_count) : (b += 1) {
            band_cross_base[b] = band_cross_base[b - 1] +
                band_cross_extent[b - 1] + BAND_CROSS_GAP;
        }
    }

    // Re-place every node. Flow axis (y): band-local cursor = node's current y
    // minus its band origin. Cross axis (x): shift by the band's cross base.
    {
        var li: usize = 0;
        while (li < nl) : (li += 1) {
            const b = band_of[li];
            const origin = band_origin[b];
            const cross_base = band_cross_base[b];
            for (lg.layers[li]) |idx| {
                geom[idx].y = geom[idx].y - origin;
                geom[idx].x = geom[idx].x + cross_base;
            }
        }
    }
}

// ====================================================================
// Tests (chained from entry.zig's test block)
// ====================================================================

const testing = std.testing;

test "bandMargin: nonzero only for bands a back-edge span straddles" {
    const a = testing.allocator;
    const spans = [_]BackSpan{.{ .lo = 1, .hi = 4 }};
    // Straddled band: one lane at the 1-cell chrome base.
    try testing.expectEqual(@as(i32, 1), try bandMargin(a, &spans, 0, 2));
    // Band beyond the span: ZERO reservation (blind mode pays 2 regardless).
    try testing.expectEqual(@as(i32, 0), try bandMargin(a, &spans, 5, 6));
    // Two OVERLAPPING spans stack into two lanes (outermost = 2)...
    const two = [_]BackSpan{ .{ .lo = 1, .hi = 4 }, .{ .lo = 2, .hi = 3 } };
    try testing.expectEqual(@as(i32, 2), try bandMargin(a, &two, 0, 5));
    // ...while span-DISJOINT ones share a single lane.
    const disjoint = [_]BackSpan{ .{ .lo = 0, .hi = 1 }, .{ .lo = 3, .hi = 4 } };
    try testing.expectEqual(@as(i32, 1), try bandMargin(a, &disjoint, 0, 5));
}

const TestGeom = struct { x: i32 = 0, y: i32 = 0, w: u32 = 0, h: u32 = 0 };

fn mkNode(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}

fn mkEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

/// Internal-frame geometry for the fold tests: layer li occupies flow rows
/// [10*li, 10*li + 9), every box 5 cells wide on the cross axis at x = 0.
fn seedGeom(lg: sugiyama.LayeredGraph, geom: []TestGeom) void {
    for (lg.layers, 0..) |layer, li| {
        for (layer) |idx| {
            geom[idx] = .{ .x = 0, .y = @as(i32, @intCast(li)) * 10, .w = 5, .h = 9 };
        }
    }
}

test "negotiated fold: measured 1-lane margin admits the layer the blind margin rejects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // LR chain A→B→C→D→E→F with one long back-edge E→B (layer span [1,4]).
    const nodes = [_]sg.Node{
        mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C"),
        mkNode(3, "D"), mkNode(4, "E"), mkNode(5, "F"),
    };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 1), mkEdge(1, 1, 2), mkEdge(2, 2, 3),
        mkEdge(3, 3, 4), mkEdge(4, 4, 5), mkEdge(5, 4, 1),
    };
    const g = sg.SemGraph{
        .direction = .LR,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), lg.layers.len);

    // Chain flow span = 59 busts budget 40 in both modes, so both fold; the
    // break POINT is what the negotiation moves. Layer D closes band 0 at
    // extent 39: blind rejects it (39 > 40 − FLOW_RAIL_MARGIN = 38) while the
    // measured margin — ONE straddling rail lane — admits it (39 ≤ 40 − 1).
    const d_idx = lg.real_index.get(3).?;
    const e_idx = lg.real_index.get(4).?;

    const geom_neg = try a.alloc(TestGeom, lg.nodes.len);
    seedGeom(lg, geom_neg);
    try foldChain(TestGeom, a, g, lg, geom_neg, 40, .LR, true);
    try testing.expectEqual(@as(i32, 0), geom_neg[d_idx].x); // D stays in band 0
    try testing.expect(geom_neg[e_idx].x > 0); // E opens band 1

    const geom_blind = try a.alloc(TestGeom, lg.nodes.len);
    seedGeom(lg, geom_blind);
    try foldChain(TestGeom, a, g, lg, geom_blind, 40, .LR, false);
    try testing.expect(geom_blind[d_idx].x > 0); // blind margin evicts D
}

test "fold preserves irregular fan/skip-corridor gaps within a band (not renormalized)" {
    // Claim: the gap `foldChain` reads between consecutive layers is whatever
    // assignY already baked in (e.g. extra headroom for a fan or skip
    // corridor) — never a fixed/typical spacing constant. Give three layers
    // in the same band non-uniform pre-fold gaps (6, then 11 cells — as if
    // the second gap holds fan headroom the first doesn't) and assert both
    // gaps survive the fold exactly, merely translated by a constant origin.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C"), mkNode(3, "D") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 2), mkEdge(2, 2, 3) };
    const g = sg.SemGraph{ .direction = .LR, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), lg.layers.len);

    var geom = try a.alloc(TestGeom, lg.nodes.len);
    const n0 = lg.real_index.get(0).?;
    const n1 = lg.real_index.get(1).?;
    const n2 = lg.real_index.get(2).?;
    const n3 = lg.real_index.get(3).?;
    // top/bot: 0..109/109..124/135..144, gap0=6, gap1=11 (irregular).
    geom[n0] = .{ .x = 0, .y = 100, .w = 5, .h = 9 };
    geom[n1] = .{ .x = 0, .y = 115, .w = 5, .h = 9 };
    geom[n2] = .{ .x = 0, .y = 135, .w = 5, .h = 9 };
    geom[n3] = .{ .x = 0, .y = 163, .w = 5, .h = 9 };
    // budget=50 (margin 2) splits into band0={A,B,C} band1={D}: layers 0-2
    // extent (44) fits budget-margin (48); adding D (extent 72) does not.
    try foldChain(TestGeom, a, g, lg, geom, 50, .LR, false);

    try testing.expectEqual(@as(i32, 0), geom[n0].x); // A,B,C share band 0
    try testing.expectEqual(@as(i32, 0), geom[n1].x);
    try testing.expectEqual(@as(i32, 0), geom[n2].x);
    try testing.expect(geom[n3].x > 0); // D folded into band 1

    const gap0 = geom[n1].y - (geom[n0].y + @as(i32, @intCast(geom[n0].h)));
    const gap1 = geom[n2].y - (geom[n1].y + @as(i32, @intCast(geom[n1].h)));
    try testing.expectEqual(@as(i32, 6), gap0); // pre-fold gap preserved exactly
    try testing.expectEqual(@as(i32, 11), gap1); // pre-fold gap preserved exactly
}

test "a single layer wider than the budget stays alone in its own band" {
    // Claim: a layer whose own flow-axis extent already exceeds the budget
    // can't be split (band membership is per-layer, never per-node) and is
    // never merged with a neighbour either — it overflows irreducibly, alone.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 2) };
    const g = sg.SemGraph{ .direction = .LR, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    var geom = try a.alloc(TestGeom, lg.nodes.len);
    const n0 = lg.real_index.get(0).?;
    const n1 = lg.real_index.get(1).?;
    const n2 = lg.real_index.get(2).?;
    geom[n0] = .{ .x = 0, .y = 0, .w = 5, .h = 9 };
    geom[n1] = .{ .x = 0, .y = 20, .w = 7, .h = 60 }; // h=60 alone dwarfs budget=50
    geom[n2] = .{ .x = 0, .y = 100, .w = 3, .h = 9 };
    try foldChain(TestGeom, a, g, lg, geom, 50, .LR, false);

    // Three distinct cross-axis shifts == three distinct bands: B neither
    // merges with A nor with C, and its own oversized extent is untouched
    // (h unchanged — no forced shrink/split to make it fit).
    try testing.expectEqual(@as(i32, 0), geom[n0].x);
    try testing.expect(geom[n1].x > geom[n0].x);
    try testing.expect(geom[n2].x > geom[n1].x);
    try testing.expectEqual(@as(u32, 60), geom[n1].h);
}

test "a band's first layer is never evicted by the margin check" {
    // Claim: the margin check (line ~184) is only ever consulted for a layer
    // that would EXTEND an already-open band; a layer that opens a new band
    // is admitted unconditionally regardless of its own size. Reuse the
    // oversized-layer setup: B's own extent (60) alone busts budget-margin
    // (50-2=48) yet B still becomes the sole content of its band (not
    // rejected, not causing the fold to error or drop it).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 2) };
    const g = sg.SemGraph{ .direction = .LR, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    var geom = try a.alloc(TestGeom, lg.nodes.len);
    const n1 = lg.real_index.get(1).?;
    geom[lg.real_index.get(0).?] = .{ .x = 0, .y = 0, .w = 5, .h = 9 };
    geom[n1] = .{ .x = 0, .y = 20, .w = 7, .h = 60 };
    geom[lg.real_index.get(2).?] = .{ .x = 0, .y = 100, .w = 3, .h = 9 };
    try foldChain(TestGeom, a, g, lg, geom, 50, .LR, false);

    // B is present, and rebased so its own top becomes its band's y origin —
    // proof the fold accepted it as a band's first layer rather than
    // evicting/erroring on an extent (60) that would fail the margin test.
    try testing.expectEqual(@as(i32, 0), geom[n1].y);
    try testing.expectEqual(@as(u32, 60), geom[n1].h);
}

test "band_cross_base prefix sum stays exact across many bands (no unbounded growth)" {
    // Claim: band_cross_base is a single running prefix sum
    // (base[b] = base[b-1] + extent[b-1] + BAND_CROSS_GAP), not e.g. a fixed
    // per-band stride or something that grows super-linearly. Force 5 layers
    // each into its own band (budget tiny relative to per-layer height) with
    // distinct widths, then check every resulting x shift against the
    // formula computed independently from the known widths.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C"), mkNode(3, "D"), mkNode(4, "E") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 2), mkEdge(2, 2, 3), mkEdge(3, 3, 4) };
    const g = sg.SemGraph{ .direction = .LR, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), lg.layers.len);

    var geom = try a.alloc(TestGeom, lg.nodes.len);
    const widths = [_]u32{ 5, 7, 3, 9, 4 };
    var idxs: [5]u32 = undefined;
    var li: usize = 0;
    while (li < 5) : (li += 1) {
        idxs[li] = lg.real_index.get(@intCast(li)).?;
        // h=60 (>> budget) forces every layer alone into its own band.
        geom[idxs[li]] = .{ .x = 0, .y = @as(i32, @intCast(li)) * 100, .w = widths[li], .h = 60 };
    }
    try foldChain(TestGeom, a, g, lg, geom, 10, .LR, false);

    var expected_base: i32 = 0;
    li = 0;
    while (li < 5) : (li += 1) {
        try testing.expectEqual(expected_base, geom[idxs[li]].x);
        expected_base += @as(i32, @intCast(widths[li])) + BAND_CROSS_GAP;
    }
}
