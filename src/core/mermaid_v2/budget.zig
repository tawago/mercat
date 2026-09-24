const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");
const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const coords = @import("layout.zig");
const recurse = @import("recurse.zig");

pub const Rung = enum(u8) {
    natural = 0,
    tight = 1,
    wrap_labels = 2,
    switch_direction = 3,
    truncate = 4,
};

/// One laid-out option: the rung whose options produced it, and the transform applied to the graph first.
pub const Candidate = struct {
    rung: Rung,
    sketch: sketch.Sketch,
    transform: Transform = .raw,
};

pub const Transform = enum {
    raw,
    motif_pack,
    bridge_dodged,
    bridge_railed,

    pub fn appliesTo(t: Transform, d: sem_graph.Direction) bool {
        return switch (t) {
            .raw, .bridge_dodged, .bridge_railed => true,
            .motif_pack => d == .TD or d == .BT,
        };
    }

    pub fn rungs(t: Transform) []const Rung {
        return switch (t) {
            .raw => std.enums.values(Rung),
            .motif_pack => &.{ .natural, .tight, .truncate },
            .bridge_dodged, .bridge_railed => &.{},
        };
    }
};

/// Lays the graph out once per rung, in rung order.
pub fn enumerate(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
) ![]const Candidate {
    const rungs = Transform.raw.rungs();
    const out = try arena.alloc(Candidate, rungs.len);
    for (rungs, out) |rung, *c| c.* = try runForced(arena, graph, bundle_permits, max_width, rung);
    return out;
}

/// The first raw candidate, in rung order, that fits the width; truncate is accepted as it is.
pub fn firstFit(candidates: []const Candidate) Candidate {
    for (candidates) |c| {
        if (c.transform != .raw) continue;
        if (c.rung == .truncate or !hasWidthOverflow(c.sketch.diagnostics)) return c;
    }
    unreachable;
}

pub fn runForced(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    rung: Rung,
) !Candidate {
    var opts = optionsFor(rung, max_width);
    opts.bundle_permits = bundle_permits;
    return .{ .rung = rung, .sketch = try recurse.layoutPieces(arena, rotateForRung(graph, rung), opts) };
}

pub fn runBridgeVariant(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    rung: Rung,
    build: prim.BridgeBuild,
) !sketch.Sketch {
    var opts = optionsFor(rung, max_width);
    opts.bundle_permits = bundle_permits;
    opts.bridge_build = build;
    return recurse.layoutPieces(arena, rotateForRung(graph, rung), opts);
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
