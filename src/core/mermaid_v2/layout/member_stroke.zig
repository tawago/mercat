//! member_stroke.zig — the ink a rail member owns beyond its tap.
//!
//! A tap that `continues` is one drop cell under (fan-OUT) or over
//! (fan-IN) the crossbar; the member's leaf lies beyond the next layer.
//! This file routes the member's own stroke from that tap to its far end:
//! the other rail's continuing tap when the member is selected at both
//! ends, else the far node's allocated port. The stroke paints the far
//! port and head when that end is private, and nothing at a rail end (the
//! rail's stem carries the head). Emitted before ordinary routing so every
//! later route clears it.
//!
//! Shape: leave the tap straight (the drop cell must be a plain vertical),
//! jog once on a gap row, arrive straight; when no jog row clears, run a
//! separate corridor column between two jogs (the skip corridor's own
//! search). A stroke that clears no gate in any shape is REFUSED — a
//! candidate the gates refused is never shipped, since its refusal names
//! ink that would lie collinear with a foreign run or enter a decoration
//! cell — and the caller drops that member from its rail: the theory's
//! per-member degradation. (A refused member keeps its bundle's shared
//! port; its private route then clears against the rail's stem like any
//! other, and goes unrouted when nothing clears.)
//!
//! Allowed imports (layout zone): std + sem_graph + sketch + siblings.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const routing = @import("routing.zig");
const rp = @import("routing_polyline.zig");
const rt = @import("routing_terminal.zig");
const route_clearance = @import("route_clearance.zig");
const fan_rail = @import("fan_rail.zig");
const port_plan = @import("port_plan.zig");
const sugiyama = @import("sugiyama.zig");
const gap_rows = @import("gap_rows.zig");

pub const Error = error{OutOfMemory};

/// A continuing tap whose member stroke found no clear route.
pub const Refusal = struct { rail: usize, edge: sg.EdgeId };

fn isIn(role: sketch.EdgeRole) bool {
    return role == .fan_in_dropper or role == .fan_in_rail;
}

/// The continuing tap for `edge` on a rail of the given polarity.
fn farTap(rails: []const fan_rail.Built, edge: sg.EdgeId, want_in: bool) ?sketch.Tap {
    for (rails) |built| {
        if (isIn(built.rail.role) != want_in) continue;
        for (built.rail.taps) |tap| if (tap.edge == edge and tap.continues) return tap;
    }
    return null;
}

/// Route every continuing tap's member stroke, appending to `out`/`polys`.
pub fn buildAll(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const routing.NodeGeom,
    placements: []const sketch.NodePlacement,
    rails: []const fan_rail.Built,
    bar_views: []const sketch.Rail,
    bundles: pb.RealizedBundles,
    allocated_ports: port_plan.Plan,
    /// Columns the back-edge return rails own (their runs are routed after
    /// the strokes and check no clearance): a stroke never runs down one.
    reserved_columns: []const i32,
    /// The gap row ledger: a stroke's jog prefers the row it claimed.
    rows: gap_rows.Ledger,
    out: *std.ArrayListUnmanaged(sketch.EdgePath),
    polys: *std.ArrayListUnmanaged([]sketch.Point),
) Error![]const Refusal {
    var refused: std.ArrayListUnmanaged(Refusal) = .empty;
    for (rails, 0..) |built, ri| {
        const fan_in = isIn(built.rail.role);
        for (built.rail.taps) |tap| {
            if (!tap.continues) continue;
            // A member selected at both ends is routed once, from its fan-OUT tap.
            if (fan_in and farTap(rails, tap.edge, false) != null) continue;
            const orig = routing.findGraphEdge(graph, tap.edge) orelse continue;
            const ep = allocated_ports.forEdge(orig.id) orelse continue;
            const src_p = routing.findPlacement(placements, orig.from);
            const dst_p = routing.findPlacement(placements, orig.to);

            var start: sketch.Point = undefined;
            var end: sketch.Point = undefined;
            var target_on_rail = false;
            var jog: i32 = undefined;
            if (!fan_in) {
                start = tap.at;
                if (farTap(rails, tap.edge, true)) |far| {
                    end = far.at;
                    target_on_rail = true;
                    jog = end.y - 2;
                } else {
                    end = rp.portPoint(dst_p, ep.target);
                    // The head sits on end.y-1 and its straight base cell on
                    // end.y-2; the jog takes the ledger row above them.
                    jog = end.y - 3 - (rows.rowOfEdge(orig.id, .exit) orelse 0);
                }
            } else {
                end = tap.at;
                start = rp.portPoint(src_p, ep.source);
                const virtuals = try rt.collectVirtuals(a, lg, orig.id);
                defer a.free(virtuals);
                jog = if (virtuals.len == 0)
                    start.y + 2
                else if (rows.rowOfEdge(orig.id, .entry)) |row|
                    geom[virtuals[0]].y - 3 - row
                else
                    geom[virtuals[0]].y - 1;
            }
            // A rail start keeps its drop cell straight (jog from two rows
            // down); a private port may bend on its first gap row, as the
            // ordinary skip-corridor route does — unless it is decorated,
            // when its departure cell holds the head and stays straight.
            // @guarded-by: port_plan_test.zig "a decorated long fan-in member's stroke leaves its departure cell straight"
            const lo = if (fan_in and orig.arrow_from == .none) start.y + 1 else start.y + 2;
            const hi = end.y - 2;
            const poly = (try route(a, orig, start, end, jog, lo, hi, out.items, bar_views, placements, allocated_ports, bundles, reserved_columns)) orelse {
                try refused.append(a, .{ .rail = ri, .edge = tap.edge });
                if (target_on_rail) {
                    for (rails, 0..) |other, oi| if (isIn(other.rail.role)) {
                        for (other.rail.taps) |t| if (t.edge == tap.edge and t.continues) try refused.append(a, .{ .rail = oi, .edge = tap.edge });
                    };
                }
                continue;
            };
            var port_to = ep.target;
            if (!target_on_rail) port_to = rp.reconcileTerminalSide(poly, dst_p, ep.target);
            try out.append(a, .{
                .id = orig.id,
                .from = orig.from,
                .to = orig.to,
                .polyline = poly,
                .port_from = ep.source,
                .port_to = port_to,
                .arrow_from = routing.mapArrow(orig.arrow_from),
                .arrow_to = routing.mapArrow(orig.arrow_to),
                .label = orig.label,
                .kind = orig.kind,
                .role = .member_stroke,
            });
            try polys.append(a, poly);
        }
    }
    return refused.toOwnedSlice(a);
}

/// Straight when the columns agree; otherwise one jog on `jog`, clamped to
/// `[lo, hi]` so both approaches keep a straight cell. Tries the preferred
/// row first, then its neighbours, then a two-jog corridor column; ships the
/// first that clears, or null when none does.
/// @guarded-by: member_stroke_test.zig "a long member whose stroke clears nowhere leaves its rail instead of shipping a refused stroke"
pub fn route(
    a: std.mem.Allocator,
    orig: sg.Edge,
    start: sketch.Point,
    end: sketch.Point,
    jog: i32,
    lo: i32,
    hi: i32,
    existing: []const sketch.EdgePath,
    bar_views: []const sketch.Rail,
    placements: []const sketch.NodePlacement,
    allocated_ports: port_plan.Plan,
    bundles: pb.RealizedBundles,
    reserved_columns: []const i32,
) Error!?[]sketch.Point {
    if (start.x == end.x) {
        const poly = try a.alloc(sketch.Point, 2);
        poly[0] = start;
        poly[1] = end;
        if (!ownsReserved(poly, reserved_columns) and try clears(a, orig, poly, existing, bar_views, placements, allocated_ports, bundles)) return poly;
        return null;
    }
    if (lo > hi) return null;
    const preferred = @min(@max(jog, lo), hi);
    var delta: i32 = 0;
    while (delta <= hi - lo) : (delta += 1) {
        for ([_]i32{ preferred - delta, preferred + delta }) |row| {
            if (row < lo or row > hi) continue;
            if (delta == 0 and row != preferred) continue;
            const poly = try a.alloc(sketch.Point, 4);
            poly[0] = start;
            poly[1] = .{ .x = start.x, .y = row };
            poly[2] = .{ .x = end.x, .y = row };
            poly[3] = end;
            if (!ownsReserved(poly, reserved_columns) and try clears(a, orig, poly, existing, bar_views, placements, allocated_ports, bundles)) return poly;
        }
    }
    // Two jogs around a corridor column the boxes leave clear.
    if (hi - lo >= 2) {
        const corridor = sketch.clearLine(false, end.x, lo, hi, placements, orig.from, orig.to, .{ .margin = true });
        if (corridor != start.x and corridor != end.x) {
            const poly = try a.alloc(sketch.Point, 6);
            poly[0] = start;
            poly[1] = .{ .x = start.x, .y = lo };
            poly[2] = .{ .x = corridor, .y = lo };
            poly[3] = .{ .x = corridor, .y = hi };
            poly[4] = .{ .x = end.x, .y = hi };
            poly[5] = end;
            if (!ownsReserved(poly, reserved_columns) and try clears(a, orig, poly, existing, bar_views, placements, allocated_ports, bundles)) return poly;
        }
    }
    return null;
}

/// True iff a vertical segment of `poly` runs down a reserved column.
fn ownsReserved(poly: []const sketch.Point, reserved: []const i32) bool {
    var i: usize = 0;
    while (i + 1 < poly.len) : (i += 1) {
        if (poly[i].x != poly[i + 1].x or poly[i].y == poly[i + 1].y) continue;
        for (reserved) |x| if (x == poly[i].x) return true;
    }
    return false;
}

/// The stroke's own rail cells are legal by construction; the stretch
/// between them must clear every gate an ordinary route clears.
fn clears(
    a: std.mem.Allocator,
    orig: sg.Edge,
    poly: []const sketch.Point,
    existing: []const sketch.EdgePath,
    bar_views: []const sketch.Rail,
    placements: []const sketch.NodePlacement,
    allocated_ports: port_plan.Plan,
    bundles: pb.RealizedBundles,
) Error!bool {
    const start = poly[0];
    const end = poly[poly.len - 1];
    var inner: std.ArrayListUnmanaged(sketch.Point) = .empty;
    defer inner.deinit(a);
    try inner.append(a, .{ .x = start.x, .y = start.y + 1 });
    for (poly[1 .. poly.len - 1]) |p| try inner.append(a, p);
    try inner.append(a, .{ .x = end.x, .y = end.y - 1 });
    // Box termination holds with or without a plan: a stroke through a
    // foreign box is refused even where the plan-aware gates stand down.
    if (try route_clearance.blocked(a, orig.id, inner.items, existing, bundles, placements, orig.from, orig.to)) return false;
    // Rail ink is another owner's: a stroke may cross a rail's run, never
    // lie along it or on its stem or drops (`route_clearance.ridesRail`,
    // one of the gates below).
    return route_clearance.polylineClears(a, orig.id, inner.items, existing, bar_views, placements, allocated_ports.edges, bundles, orig.from, orig.to);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("member_stroke_test.zig");
}
