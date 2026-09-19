const std = @import("std");
const sketch = @import("../sketch.zig");

pub const Violation = struct {
    kind: Kind,
    message: []const u8,

    pub const Kind = enum {
        path_through_interior,
        bbox_overflow,
        edge_unrouted,
    };
};

pub const ValidationResult = union(enum) {
    ok,
    failed: []const Violation,
};

pub const Counts = struct {
    path_through_interior: u32 = 0,
    bbox_overflow: u32 = 0,
    edge_unrouted: u32 = 0,
};

pub fn counts(vr: ValidationResult, s: sketch.Sketch) Counts {
    var c: Counts = .{};
    switch (vr) {
        .ok => {},
        .failed => |violations| for (violations) |v| switch (v.kind) {
            .path_through_interior => c.path_through_interior += 1,
            .bbox_overflow => c.bbox_overflow += 1,
            .edge_unrouted => c.edge_unrouted += 1,
        },
    }
    if (s.bbox.w > s.budget.max_width) c.bbox_overflow += 1;
    return c;
}

pub fn validate(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
) !ValidationResult {
    var violations: std.ArrayList(Violation) = .empty;
    errdefer violations.deinit(allocator);

    try checkUnrouted(allocator, s, &violations);
    try checkPathInteriors(allocator, s, &violations);
    try checkRails(allocator, s, &violations);
    try checkBboxBudget(allocator, s, &violations);

    if (violations.items.len == 0) {
        violations.deinit(allocator);
        return .ok;
    }
    const owned = try violations.toOwnedSlice(allocator);
    return .{ .failed = owned };
}

fn emit(
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    kind: Violation.Kind,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    try violations.append(allocator, .{ .kind = kind, .message = msg });
}

/// @guarded-by: validate_test.zig "an edge with no polyline counts as unrouted"
pub fn checkUnrouted(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    violations: *std.ArrayList(Violation),
) !void {
    for (s.edges) |edge| {
        if (edge.polyline.len >= 2 or edge.kind == .invisible) continue;
        try emit(allocator, violations, .edge_unrouted, "edge {d} ({d} -> {d}) has no polyline; unrouted", .{ edge.id, edge.from, edge.to });
    }
}

pub fn checkPathInteriors(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    violations: *std.ArrayList(Violation),
) !void {
    for (s.edges) |edge| {
        if (edge.polyline.len < 2) continue;

        var seg_idx: usize = 0;
        while (seg_idx + 1 < edge.polyline.len) : (seg_idx += 1) {
            const a = edge.polyline[seg_idx];
            const b = edge.polyline[seg_idx + 1];

            for (s.nodes) |node| {
                // @guarded-by: validate_test.zig "checkPathInteriors exempts a segment adjacent to its own edge's endpoint but flags a genuine cross by an unrelated edge"
                const is_first_seg = seg_idx == 0;
                const is_last_seg = seg_idx + 2 == edge.polyline.len;
                if (is_first_seg and node.id == edge.from) continue;
                if (is_last_seg and node.id == edge.to) continue;

                if (segmentCrossesInterior(a, b, node.rect)) {
                    try emit(allocator, violations, .path_through_interior, "edge {d} segment ({d},{d})->({d},{d}) crosses interior of node {d}", .{ edge.id, a.x, a.y, b.x, b.y, node.id });
                }
            }
        }
    }
}

pub fn checkRails(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    violations: *std.ArrayList(Violation),
) !void {
    for (s.rails) |rail| {
        for (s.nodes) |node| {
            var si: usize = 0;
            while (si + 1 < rail.stem.len) : (si += 1) {
                if (si == 0 and node.id == rail.pivot) continue;
                if (segmentCrossesInterior(rail.stem[si], rail.stem[si + 1], node.rect)) {
                    try emit(allocator, violations, .path_through_interior, "rail stem segment ({d},{d})->({d},{d}) crosses interior of node {d}", .{ rail.stem[si].x, rail.stem[si].y, rail.stem[si + 1].x, rail.stem[si + 1].y, node.id });
                }
            }
            if (segmentCrossesInterior(rail.crossbar[0], rail.crossbar[1], node.rect)) {
                try emit(allocator, violations, .path_through_interior, "rail crossbar ({d},{d})->({d},{d}) crosses interior of node {d}", .{ rail.crossbar[0].x, rail.crossbar[0].y, rail.crossbar[1].x, rail.crossbar[1].y, node.id });
            }
            for (rail.taps) |tap| {
                if (node.id == tap.node) continue;
                if (segmentCrossesInterior(tap.at, tap.landing, node.rect)) {
                    try emit(allocator, violations, .path_through_interior, "rail tap for edge {d} ({d},{d})->({d},{d}) crosses interior of node {d}", .{ tap.edge, tap.at.x, tap.at.y, tap.landing.x, tap.landing.y, node.id });
                }
            }
        }
    }
}

/// @guarded-by: validate_test.zig "bbox overflow is informational, not a validation failure"
pub fn checkBboxBudget(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    violations: *std.ArrayList(Violation),
) !void {
    _ = allocator;
    _ = violations;
    if (s.bbox.w > s.budget.max_width) {
        const excess = s.bbox.w - s.budget.max_width;
        std.log.debug("mermaid_v2/validate: bbox width {d} exceeds budget {d} by {d} (clipped at paint)", .{ s.bbox.w, s.budget.max_width, excess });
    }
}

fn segmentCrossesInterior(a: sketch.Point, b: sketch.Point, r: sketch.Rect) bool {
    if (r.w < 3 or r.h < 3) return false;
    const left = r.x;
    const right_inc = r.right() - 1;
    const top = r.y;
    const bottom_inc = r.bottom() - 1;

    if (pointInInterior(a, r) or pointInInterior(b, r)) return true;

    if (a.x == b.x) {
        const x = a.x;
        if (x <= left or x >= right_inc) return false;
        const y0 = @min(a.y, b.y);
        const y1 = @max(a.y, b.y);
        return y0 < bottom_inc and y1 > top;
    }
    if (a.y == b.y) {
        const y = a.y;
        if (y <= top or y >= bottom_inc) return false;
        const x0 = @min(a.x, b.x);
        const x1 = @max(a.x, b.x);
        return x0 < right_inc and x1 > left;
    }

    // @guarded-by: validate_test.zig "checkPathInteriors' diagonal fallback is a conservative bbox-overlap test, not a precise line-rect intersection"
    const sx0 = @min(a.x, b.x);
    const sx1 = @max(a.x, b.x);
    const sy0 = @min(a.y, b.y);
    const sy1 = @max(a.y, b.y);
    return sx0 < right_inc and sx1 > left and sy0 < bottom_inc and sy1 > top;
}

fn pointInInterior(p: sketch.Point, r: sketch.Rect) bool {
    if (r.w < 3 or r.h < 3) return false;
    return p.x > r.x and p.x < r.right() - 1 and
        p.y > r.y and p.y < r.bottom() - 1;
}

test {
    _ = @import("validate_test.zig");
}
