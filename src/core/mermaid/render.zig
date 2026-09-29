const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const flowchart = @import("flowchart/entry.zig");
const render_sequence = @import("sequence/render.zig");
const render_class = @import("class/render.zig");
const render_er = @import("er/render.zig");
const render_state = @import("state/render.zig");

pub const RenderOptions = types.RenderOptions;
pub const RenderResult = types.RenderResult;

const DiagramType = types.DiagramType;

pub fn render(allocator: Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    const diagram_type = DiagramType.fromSource(source);

    return switch (diagram_type) {
        .flowchart => renderFlowchart(allocator, source, options),
        .sequence => render_sequence.renderSequence(allocator, source, options) catch |err| fallback(source, @errorName(err)),
        .class_diagram => render_class.renderClassDiagram(allocator, source, options) catch |err| fallback(source, @errorName(err)),
        .er => render_er.renderERDiagram(allocator, source, options) catch |err| fallback(source, @errorName(err)),
        .state => render_state.renderStateDiagram(allocator, source, options) catch |err| fallback(source, @errorName(err)),
        .unsupported => fallback(source, "Unsupported diagram type"),
    };
}

fn renderFlowchart(allocator: Allocator, source: []const u8, options: RenderOptions) RenderResult {
    const flowchart_options = flowchart.RenderOptions{
        .max_width = options.max_width,
        .unicode_mode = options.unicode_mode,
        .subgraph_edges = options.subgraph_edges,
    };
    const flowchart_result = flowchart.render(allocator, source, flowchart_options) catch |err| {
        return fallback(source, @errorName(err));
    };
    return .{
        .output = flowchart_result.output,
        .width = flowchart_result.width,
        .height = flowchart_result.height,
        .is_fallback = flowchart_result.is_fallback,
        .fallback_reason = flowchart_result.fallback_reason,
    };
}

fn fallback(source: []const u8, reason: []const u8) RenderResult {
    return .{
        .output = source,
        .width = 0,
        .height = 0,
        .is_fallback = true,
        .fallback_reason = reason,
    };
}
