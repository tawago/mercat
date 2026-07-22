const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const mermaid_v2 = @import("../mermaid_v2/entry.zig");
const render_sequence = @import("sequence/render.zig");
const render_class = @import("class/render.zig");
const render_er = @import("er/render.zig");
const render_state = @import("state/render.zig");

// Re-export types for external consumers
pub const RenderOptions = types.RenderOptions;
pub const RenderResult = types.RenderResult;

const DiagramType = types.DiagramType;

/// Main entry point for rendering mermaid diagrams.
///
/// Flowcharts are routed unconditionally through the mermaid_v2 pipeline
/// (the legacy `flowchart/` tree was removed in W10 cutover). Other
/// diagram types continue to use their existing renderers.
pub fn render(allocator: Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    const diagram_type = DiagramType.fromSource(source);

    return switch (diagram_type) {
        .flowchart => renderFlowchartV2(allocator, source, options),
        .sequence => render_sequence.renderSequence(allocator, source, options) catch |err| fallback(source, @errorName(err)),
        .class_diagram => render_class.renderClassDiagram(allocator, source, options) catch |err| fallback(source, @errorName(err)),
        .er => render_er.renderERDiagram(allocator, source, options) catch |err| fallback(source, @errorName(err)),
        .state => render_state.renderStateDiagram(allocator, source, options) catch |err| fallback(source, @errorName(err)),
        .unsupported => fallback(source, "Unsupported diagram type"),
    };
}

/// Render a mermaid diagram or return fallback
pub fn renderOrFallback(allocator: Allocator, source: []const u8, options: RenderOptions) RenderResult {
    return render(allocator, source, options) catch {
        return fallback(source, "Render failed");
    };
}

/// Check if source is a mermaid diagram
pub fn isMermaidBlock(source: []const u8) bool {
    return DiagramType.fromSource(source) != .unsupported;
}

fn renderFlowchartV2(allocator: Allocator, source: []const u8, options: RenderOptions) RenderResult {
    const v2_opts = mermaid_v2.RenderOptions{
        .max_width = options.max_width,
        .unicode_mode = options.unicode_mode,
        .subgraph_edges = options.subgraph_edges,
    };
    const v2_result = mermaid_v2.render(allocator, source, v2_opts) catch |err| {
        return fallback(source, @errorName(err));
    };
    return .{
        .output = v2_result.output,
        .width = v2_result.width,
        .height = v2_result.height,
        .is_fallback = v2_result.is_fallback,
        .fallback_reason = v2_result.fallback_reason,
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
