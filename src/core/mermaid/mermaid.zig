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
    const kind = detect.Kind.fromSource(source);
    const fit = switch (kind) {
        .flowchart => return renderFlowchart(allocator, source, options),
        .sequence => sequence.render(allocator, source, options.max_width),
        .class_diagram => class.render(allocator, source, options.max_width),
        .er => er.render(allocator, source, options.max_width),
        .state => state.render(allocator, source, options.max_width),
        .unsupported => return .{ .not_drawn = .{} },
    } catch return .{ .not_drawn = .{} };
    return switch (fit) {
        .drawn => |text| .{ .drawn = text },
        .too_wide => |width| blk: {
            std.log.warn("mermaid: {s} diagram not drawn: width {d} > budget {d}", .{ kindName(kind), width, options.max_width });
            break :blk .{ .not_drawn = .{} };
        },
    };
}

fn kindName(kind: detect.Kind) []const u8 {
    return switch (kind) {
        .sequence => "sequence",
        .class_diagram => "class",
        .er => "er",
        .state => "state",
        .flowchart, .unsupported => unreachable,
    };
}

fn renderFlowchart(allocator: std.mem.Allocator, source: []const u8, options: Options) Result {
    const result = flowchart.render(allocator, source, .{
        .max_width = options.max_width,
        .subgraph_edges = options.subgraph_edges,
    }) catch return .{ .not_drawn = .{} };
    if (result.is_fallback) return .{ .not_drawn = .{ .banner = result.fallback_reason } };
    return .{ .drawn = result.output };
}
