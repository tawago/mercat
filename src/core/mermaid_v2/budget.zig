const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");
const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const coords = @import("layout.zig");
const recurse = @import("recurse.zig");
const types = @import("budget_types.zig");

pub const Rung = enum(u8) {
    natural = 0,
    tight = 1,
    wrap_labels = 2,
    switch_direction = 3,
    truncate = 4,
};

pub const LadderResult = struct {
    sketch: sketch.Sketch,
    final_rung: Rung,
    attempts: u8,
};

pub fn run(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
) !LadderResult {
    var attempts: u8 = 0;
    var rung_idx: u8 = 0;
    while (rung_idx <= @intFromEnum(Rung.truncate)) : (rung_idx += 1) {
        const rung: Rung = @enumFromInt(rung_idx);
        const attempt = try tryRung(arena, graph, bundle_permits, max_width, rung);
        attempts += 1;

        if (attempt.accepted) {
            return LadderResult{
                .sketch = attempt.sketch,
                .final_rung = rung,
                .attempts = attempts,
            };
        }
    }
    unreachable;
}

fn layoutRung(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    rung: Rung,
) !sketch.Sketch {
    var opts = optionsFor(rung, max_width);
    opts.bundle_permits = bundle_permits;
    return recurse.layoutPieces(arena, rotateForRung(graph, rung), opts);
}

const RungAttempt = struct { sketch: sketch.Sketch, accepted: bool };

fn tryRung(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    rung: Rung,
) !RungAttempt {
    const result = try layoutRung(arena, graph, bundle_permits, max_width, rung);
    return .{
        .sketch = result,
        .accepted = ladderAccepts(rung, result),
    };
}

fn ladderAccepts(rung: Rung, result: sketch.Sketch) bool {
    if (rung == .switch_direction) {
        return !hasWidthOverflow(result.diagnostics);
    }
    return rung == .truncate or !hasWidthOverflow(result.diagnostics);
}

pub const Candidate = types.Candidate;
pub const Transform = types.Transform;
pub const EnumerateResult = types.EnumerateResult;

pub fn enumerate(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
) !EnumerateResult {
    var candidates: std.ArrayList(Candidate) = .empty;
    var incumbent: ?LadderResult = null;
    var attempts: u8 = 0;
    var rung_idx: u8 = 0;
    while (rung_idx <= @intFromEnum(Rung.truncate)) : (rung_idx += 1) {
        const rung: Rung = @enumFromInt(rung_idx);
        if (incumbent == null) {
            const attempt = try tryRung(arena, graph, bundle_permits, max_width, rung);
            attempts += 1;
            try candidates.append(arena, .{ .rung = rung, .sketch = attempt.sketch, .accepted = attempt.accepted });
            if (attempt.accepted) {
                incumbent = .{ .sketch = attempt.sketch, .final_rung = rung, .attempts = attempts };
            }
        } else {
            const result = layoutRung(arena, graph, bundle_permits, max_width, rung) catch continue;
            try candidates.append(arena, .{ .rung = rung, .sketch = result, .accepted = false });
        }
    }
    return .{
        // @guarded-by: budget_test.zig "enumerate/run always resolve an incumbent across degenerate graphs and widths"
        .incumbent = incumbent.?,
        .candidates = try candidates.toOwnedSlice(arena),
    };
}

pub fn runForced(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    rung: Rung,
) !LadderResult {
    const result = try layoutRung(arena, graph, bundle_permits, max_width, rung);
    return .{ .sketch = result, .final_rung = rung, .attempts = 1 };
}

/// @guarded-by: select_test.zig "bridge variants: the real-raster score decides, and flips when the counts flip"
pub fn runBridgeVariant(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    rung: Rung,
    build: prim.BridgeBuild,
) !LadderResult {
    var opts = optionsFor(rung, max_width);
    opts.bundle_permits = bundle_permits;
    opts.bridge_build = build;
    return .{ .sketch = try recurse.layoutPieces(arena, rotateForRung(graph, rung), opts), .final_rung = rung, .attempts = 1 };
}

fn optionsFor(rung: Rung, max_width: u32) coords.LayoutOptions {
    const defaults: coords.LayoutOptions = .{};
    return switch (rung) {
        .natural => .{
            .max_width = max_width,
            .h_spacing = defaults.h_spacing,
            .v_spacing = defaults.v_spacing,
            .node_padding = defaults.node_padding,
            .rung = @intFromEnum(rung),
            .justify = .center,
            .spacing_scale = 0,
        },
        .tight => .{
            .max_width = max_width,
            .h_spacing = halveAtLeastOne(defaults.h_spacing),
            .v_spacing = halveAtLeastOne(defaults.v_spacing),
            .node_padding = defaults.node_padding,
            .rung = @intFromEnum(rung),
            .justify = .flush_left,
            .spacing_scale = 1,
        },
        .wrap_labels => .{
            .max_width = max_width,
            .h_spacing = halveAtLeastOne(defaults.h_spacing),
            .v_spacing = halveAtLeastOne(defaults.v_spacing),
            .node_padding = defaults.node_padding,
            .rung = @intFromEnum(rung),
            .max_label_width = max_width -| (2 + 2 * defaults.node_padding),
            .justify = .flush_left,
            .spacing_scale = 1,
        },
        .switch_direction => .{
            .max_width = max_width,
            .h_spacing = halveAtLeastOne(defaults.h_spacing),
            .v_spacing = halveAtLeastOne(defaults.v_spacing),
            .node_padding = defaults.node_padding,
            .rung = @intFromEnum(rung),
            .is_direction_rotated = true,
            .justify = .flush_left,
            .spacing_scale = 1,
        },
        .truncate => .{
            .max_width = max_width,
            .h_spacing = halveAtLeastOne(defaults.h_spacing),
            .v_spacing = halveAtLeastOne(defaults.v_spacing),
            .node_padding = if (defaults.node_padding == 0) 0 else defaults.node_padding - 1,
            .rung = @intFromEnum(rung),
            .justify = .flush_left,
            .spacing_scale = 1,
        },
    };
}

fn halveAtLeastOne(v: u32) u32 {
    const h = v / 2;
    return if (h < 1) 1 else h;
}

fn rotateForRung(graph: sem_graph.SemGraph, rung: Rung) sem_graph.SemGraph {
    if (rung != .switch_direction) return graph;
    var copy = graph;
    copy.direction = prim.rotatedDirection(graph.direction);
    return copy;
}

pub fn hasWidthOverflow(diagnostics: []const sketch.Diagnostic) bool {
    for (diagnostics) |d| {
        switch (d) {
            .width_overflow => return true,
            else => {},
        }
    }
    return false;
}

test {
    _ = @import("budget_test.zig");
}

test "halveAtLeastOne clamps to 1" {
    try std.testing.expectEqual(@as(u32, 2), halveAtLeastOne(4));
    try std.testing.expectEqual(@as(u32, 1), halveAtLeastOne(1));
    try std.testing.expectEqual(@as(u32, 1), halveAtLeastOne(0));
}

test "rotateForRung only fires on switch_direction" {
    const g: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &.{},
        .edges = &.{},
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    try std.testing.expectEqual(sem_graph.Direction.TD, rotateForRung(g, .natural).direction);
    try std.testing.expectEqual(sem_graph.Direction.TD, rotateForRung(g, .tight).direction);
    try std.testing.expectEqual(sem_graph.Direction.LR, rotateForRung(g, .switch_direction).direction);
    try std.testing.expectEqual(sem_graph.Direction.TD, rotateForRung(g, .truncate).direction);

    var g2 = g;
    g2.direction = .BT;
    try std.testing.expectEqual(sem_graph.Direction.RL, rotateForRung(g2, .switch_direction).direction);
}
