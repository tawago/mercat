//! The mermaid API: one call renders any diagram source mercat draws.

const std = @import("std");
const detect = @import("detect.zig");
const flowchart = @import("flowchart/entry.zig");
const sequence = @import("sequence/render.zig");
const class = @import("class/render.zig");
const er = @import("er/render.zig");
const state = @import("state/render.zig");

pub const SubgraphEdges = @import("prim").SubgraphEdges;

pub const Options = struct {
    max_width: u32 = 120,
    subgraph_edges: SubgraphEdges = .bridge,
};

pub const Result = union(enum) {
    /// The drawing, allocated with the caller's allocator.
    drawn: []const u8,
    /// Nothing drawn: the caller shows the source, under a `<PARSE ERROR: banner>` line when a
    /// banner is set (only flowchart failures carry one).
    not_drawn: struct { banner: ?[]const u8 = null },
};

pub fn render(allocator: std.mem.Allocator, source: []const u8, options: Options) Result {
    const drawn = switch (detect.Kind.fromSource(source)) {
        .flowchart => return renderFlowchart(allocator, source, options),
        .sequence => sequence.render(allocator, source, options.max_width),
        .class_diagram => class.render(allocator, source, options.max_width),
        .er => er.render(allocator, source, options.max_width),
        .state => state.render(allocator, source, options.max_width),
        .unsupported => return .{ .not_drawn = .{} },
    } catch return .{ .not_drawn = .{} };
    return if (drawn) |text| .{ .drawn = text } else .{ .not_drawn = .{} };
}

fn renderFlowchart(allocator: std.mem.Allocator, source: []const u8, options: Options) Result {
    const result = flowchart.render(allocator, source, .{
        .max_width = options.max_width,
        .subgraph_edges = options.subgraph_edges,
    }) catch return .{ .not_drawn = .{} };
    if (result.is_fallback) return .{ .not_drawn = .{ .banner = result.fallback_reason } };
    return .{ .drawn = result.output };
}
