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

    pub fn bridgeBuild(t: Transform) prim.BridgeBuild {
        return switch (t) {
            .raw, .motif_pack => .plain,
            .bridge_dodged => .dodged,
            .bridge_railed => .railed,
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
    return candidates[firstFitIndex(candidates)];
}

pub fn firstFitIndex(candidates: []const Candidate) usize {
    for (candidates, 0..) |c, i| {
        if (c.transform != .raw) continue;
        if (c.rung == .truncate or !hasWidthOverflow(c.sketch.diagnostics)) return i;
    }
    unreachable;
}

/// `graph` laid out at `rung` and recorded under `transform`.
pub fn run(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    rung: Rung,
    transform: Transform,
) !Candidate {
    var opts = optionsFor(rung, max_width);
    opts.bundle_permits = bundle_permits;
    opts.bridge_build = transform.bridgeBuild();
    const g = rotateForRung(graph, rung);
    var s = try recurse.layoutPieces(arena, g, opts);
    if (hasWidthOverflow(s.diagnostics)) {
        opts.label_room = false;
        s = try recurse.layoutPieces(arena, g, opts);
    }
    return .{ .rung = rung, .sketch = s, .transform = transform };
}

pub fn runForced(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    rung: Rung,
) !Candidate {
    return run(arena, graph, bundle_permits, max_width, rung, .raw);
}

fn optionsFor(rung: Rung, max_width: u32) coords.LayoutOptions {
    const defaults: coords.LayoutOptions = .{};
    var opts: coords.LayoutOptions = .{
        .max_width = max_width,
        .rung = @intFromEnum(rung),
        .justify = .center,
        .spacing_scale = 0,
    };
    if (rung == .natural) return opts;

    opts.h_spacing = halveAtLeastOne(defaults.h_spacing);
    opts.v_spacing = halveAtLeastOne(defaults.v_spacing);
    opts.justify = .flush_left;
    opts.spacing_scale = 1;
    switch (rung) {
        .natural, .tight => {},
        .wrap_labels => opts.max_label_width = max_width -| (2 + 2 * defaults.node_padding),
        .switch_direction => opts.is_direction_rotated = true,
        .truncate => opts.node_padding = if (defaults.node_padding == 0) 0 else defaults.node_padding - 1,
    }
    return opts;
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

test "each rung past natural tightens spacing and adds only its own distinguishing option" {
    const natural = optionsFor(.natural, 40);
    try std.testing.expectEqual(@as(?u32, null), natural.max_label_width);
    try std.testing.expect(!natural.is_direction_rotated);
    for (std.enums.values(Rung)) |rung| {
        const o = optionsFor(rung, 40);
        try std.testing.expectEqual(@as(u32, 40), o.max_width);
        try std.testing.expectEqual(@intFromEnum(rung), o.rung);
        if (rung == .natural) continue;
        try std.testing.expect(o.h_spacing < natural.h_spacing and o.h_spacing >= 1);
        try std.testing.expect(o.v_spacing < natural.v_spacing and o.v_spacing >= 1);
        try std.testing.expect(o.spacing_scale > natural.spacing_scale);
        try std.testing.expectEqual(rung == .wrap_labels, o.max_label_width != null);
        try std.testing.expectEqual(rung == .switch_direction, o.is_direction_rotated);
        try std.testing.expectEqual(rung == .truncate, o.node_padding < natural.node_padding);
    }
    const wrap = optionsFor(.wrap_labels, 40).max_label_width.?;
    try std.testing.expect(wrap > 0 and wrap < 40);
}
