const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sketch_clearance = @import("../sketch_clearance.zig");
const pb = @import("../base/ledger.zig");
const route_clearance = @import("route_clearance.zig");
const port_plan = @import("port_plan.zig");

pub const Error = error{OutOfMemory};

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
    if (hi - lo >= 2) {
        const corridor = sketch_clearance.clearLine(false, end.x, lo, hi, placements, orig.from, orig.to, .{ .margin = true });
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

fn ownsReserved(poly: []const sketch.Point, reserved: []const i32) bool {
    var i: usize = 0;
    while (i + 1 < poly.len) : (i += 1) {
        if (poly[i].x != poly[i + 1].x or poly[i].y == poly[i + 1].y) continue;
        for (reserved) |x| if (x == poly[i].x) return true;
    }
    return false;
}

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
    if (try route_clearance.blocked(a, orig.id, inner.items, existing, bundles, placements, orig.from, orig.to)) return false;
    return route_clearance.polylineClears(a, orig.id, inner.items, existing, bar_views, placements, allocated_ports.edges, bundles, orig.from, orig.to);
}

test {
    std.testing.refAllDecls(@This());
}
