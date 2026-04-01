const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const parser = @import("parser.zig");
const layout_mod = @import("layout.zig");
const canvas_mod = @import("canvas.zig");
const routing_mod = @import("routing.zig");
const compaction_mod = @import("compaction.zig");

// Re-export types for external consumers
pub const RenderOptions = types.RenderOptions;
pub const RenderResult = types.RenderResult;

const Graph = types.Graph;
const Node = types.Node;
const Edge = types.Edge;
const Direction = types.Direction;
const NodeShape = types.NodeShape;
const EdgeStyle = types.EdgeStyle;
const Point = types.Point;
const Rect = types.Rect;
const BoxChars = types.BoxChars;
const LineChars = types.LineChars;
const Arrows = types.Arrows;
const DiagramType = types.DiagramType;
const SequenceDiagram = types.SequenceDiagram;
const CompactionHints = types.CompactionHints;
const Participant = types.Participant;
const Message = types.Message;
const SequenceArrowType = types.SequenceArrowType;
const ClassDiagram = types.ClassDiagram;
const Class = types.Class;
const ClassMember = types.ClassMember;
const ClassRelation = types.ClassRelation;
const ClassRelationType = types.ClassRelationType;
const Visibility = types.Visibility;
const ERDiagram = types.ERDiagram;
const Entity = types.Entity;
const ERRelation = types.ERRelation;
const Cardinality = types.Cardinality;
const StateDiagram = types.StateDiagram;
const State = types.State;
const StateType = types.StateType;
const StateTransition = types.StateTransition;

const Canvas = canvas_mod.Canvas;
const Priority = canvas_mod.Priority;
const Layout = layout_mod.Layout;
const StateLayout = layout_mod.StateLayout;
const EdgeRouter = routing_mod.EdgeRouter;
const CompactionController = compaction_mod.CompactionController;
const Parser = parser.Parser;

/// Main entry point for rendering mermaid diagrams
pub fn render(allocator: Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    const diagram_type = DiagramType.fromSource(source);

    // Check for unsupported diagram types
    if (diagram_type == .unsupported) {
        return .{
            .output = source,
            .width = 0,
            .height = 0,
            .is_fallback = true,
            .fallback_reason = "Unsupported diagram type",
        };
    }

    // Route to appropriate renderer
    if (diagram_type == .sequence) {
        return renderSequence(allocator, source, options) catch |err| {
            return .{
                .output = source,
                .width = 0,
                .height = 0,
                .is_fallback = true,
                .fallback_reason = @errorName(err),
            };
        };
    }

    if (diagram_type == .class_diagram) {
        return renderClassDiagram(allocator, source, options) catch |err| {
            return .{
                .output = source,
                .width = 0,
                .height = 0,
                .is_fallback = true,
                .fallback_reason = @errorName(err),
            };
        };
    }

    if (diagram_type == .er) {
        return renderERDiagram(allocator, source, options) catch |err| {
            return .{
                .output = source,
                .width = 0,
                .height = 0,
                .is_fallback = true,
                .fallback_reason = @errorName(err),
            };
        };
    }

    if (diagram_type == .state) {
        return renderStateDiagram(allocator, source, options) catch |err| {
            return .{
                .output = source,
                .width = 0,
                .height = 0,
                .is_fallback = true,
                .fallback_reason = @errorName(err),
            };
        };
    }

    if (diagram_type != .flowchart) {
        return .{
            .output = source,
            .width = 0,
            .height = 0,
            .is_fallback = true,
            .fallback_reason = "Diagram type not yet supported",
        };
    }

    return renderFlowchart(allocator, source, options) catch |err| {
        return .{
            .output = source,
            .width = 0,
            .height = 0,
            .is_fallback = true,
            .fallback_reason = @errorName(err),
        };
    };
}

fn renderFlowchart(allocator: Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    const controller = CompactionController.init(options);
    var last_result = RenderResult{
        .output = source,
        .width = 0,
        .height = 0,
        .is_fallback = true,
        .fallback_reason = "Diagram too wide for terminal",
    };

    for (compaction_mod.flowchart_levels) |level| {
        const hints = controller.flowchartHints(level) orelse continue;
        const result = try renderFlowchartWithOptions(allocator, source, hints.render_options);
        if (!result.is_fallback) return result;
        last_result = result;
    }

    return last_result;
}

fn renderFlowchartWithOptions(allocator: Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    // Parse the diagram
    var graph = try Parser.parse(allocator, source);
    defer graph.deinit();

    if (graph.node_order.items.len == 0) {
        return .{
            .output = "",
            .width = 0,
            .height = 0,
            .is_fallback = false,
            .fallback_reason = null,
        };
    }

    // Run layout algorithm
    var layout = Layout.init(allocator, &graph, options);
    defer layout.deinit();
    try layout.run();

    var router = try EdgeRouter.init(allocator, &graph);
    defer router.deinit();

    // Calculate canvas bounds
    const bounds = calculateBounds(&graph);

    // Check if diagram fits
    if (bounds.width > options.max_width) {
        return .{
            .output = source,
            .width = bounds.width,
            .height = bounds.height,
            .is_fallback = true,
            .fallback_reason = "Diagram too wide for terminal",
        };
    }

    // Apply offsets to all node positions
    for (graph.node_order.items) |id| {
        if (graph.getNodeMut(id)) |node| {
            if (node.x) |*x| x.* += bounds.offset_x;
            if (node.y) |*y| y.* += bounds.offset_y;
        }
    }

    // Create canvas
    var canvas = try Canvas.init(allocator, bounds.width, bounds.height);
    defer canvas.deinit();

    // Draw subgraphs first (background)
    for (graph.subgraphs.items) |*sg| {
        try drawSubgraph(&canvas, sg, &graph, options);
    }

    // Draw edges, grouping vertical fan-out by source node for branching
    {
        // Track which source nodes have been drawn as a group
        var grouped = std.StringHashMap(void).init(allocator);
        defer grouped.deinit();

        for (graph.edges.items, 0..) |*edge, i| {
            // If this source was already handled as a group, skip
            if (grouped.contains(edge.from)) continue;

            // Count edges from this source
            var count: usize = 0;
            for (graph.edges.items) |e| {
                if (std.mem.eql(u8, e.from, edge.from)) count += 1;
            }

            if (count > 1 and !graph.direction.isHorizontal()) {
                // Draw as a branching group (shared stem + branch bar)
                try drawEdgeGroup(allocator, &canvas, edge.from, &graph, &router, options);
                try grouped.put(edge.from, {});
            } else {
                try drawEdge(allocator, &canvas, edge, &graph, &router, options, i);
            }
        }
    }

    // Draw nodes on top
    for (graph.node_order.items) |id| {
        if (graph.getNode(id)) |node| {
            drawNode(&canvas, node, options);
        }
    }

    // Convert to string
    const output = try canvas.toString(allocator);

    return .{
        .output = output,
        .width = bounds.width,
        .height = bounds.height,
        .is_fallback = false,
        .fallback_reason = null,
    };
}

// =====================================================
// Sequence Diagram Rendering
// =====================================================

fn renderSequence(allocator: Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    // Parse the diagram
    var diagram = try Parser.parseSequence(allocator, source);
    defer diagram.deinit();

    const controller = CompactionController.init(options);
    var last_result = RenderResult{
        .output = source,
        .width = 0,
        .height = 0,
        .is_fallback = true,
        .fallback_reason = "Diagram too wide for terminal",
    };

    for (compaction_mod.sequence_levels) |level| {
        const hints = controller.sequenceHints(level, diagram.direction, diagram.direction_explicit) orelse continue;
        const result = try renderSequenceWithHints(allocator, source, &diagram, hints);
        if (!result.is_fallback) return result;
        last_result = result;
    }

    return last_result;
}

fn renderSequenceWithHints(allocator: Allocator, source: []const u8, diagram: *SequenceDiagram, hints: CompactionHints) !RenderResult {
    const direction = hints.sequence_direction orelse diagram.direction;
    return switch (direction) {
        .LR => renderSequenceLR(allocator, source, diagram, hints),
        else => renderSequenceTB(allocator, source, diagram, hints),
    };
}

fn renderSequenceTB(allocator: Allocator, source: []const u8, diagram: *SequenceDiagram, hints: CompactionHints) !RenderResult {
    const options = hints.render_options;
    if (diagram.participants.items.len == 0) {
        return .{
            .output = "",
            .width = 0,
            .height = 0,
            .is_fallback = false,
            .fallback_reason = null,
        };
    }

    // Layout constants
    const participant_height: u32 = 3;
    const normal_row_height: u32 = 2;
    const self_msg_row_height: u32 = 4; // Extra height for self-message loop
    const min_participant_spacing: u32 = hints.sequence_participant_spacing;
    const padding: u32 = hints.sequence_padding;
    const self_msg_loop_width: u32 = 4;
    const self_msg_text_offset: u32 = 2;

    // Layout constants for notes
    const note_row_height: u32 = 3; // Box around note text

    // Find max self-message text length and count total height needed
    var max_self_msg_text_len: u32 = 0;
    var total_message_height: u32 = 0;
    for (diagram.messages.items) |msg| {
        if (msg.is_self_message) {
            const text_len: u32 = @intCast(msg.text.len);
            if (text_len > max_self_msg_text_len) {
                max_self_msg_text_len = text_len;
            }
            total_message_height += self_msg_row_height;
        } else {
            total_message_height += normal_row_height;
        }
    }
    // Add height for notes
    total_message_height += @intCast(diagram.notes.items.len * note_row_height);

    // Calculate participant widths and positions
    var total_width: u32 = padding;
    for (diagram.participants.items) |*p| {
        const name = p.displayName();
        p.box_width = @intCast(name.len + 4); // padding around name
        if (p.box_width < 8) p.box_width = 8; // minimum width
        p.x = @intCast(total_width);
        total_width += p.box_width + min_participant_spacing;
    }
    total_width = total_width - min_participant_spacing + padding;

    // Add extra width for self-message text if needed
    if (max_self_msg_text_len > 0) {
        total_width += self_msg_loop_width + self_msg_text_offset + max_self_msg_text_len;
    }

    // Add extra width for notes (right_of notes need space on the right)
    var max_note_width: u32 = 0;
    for (diagram.notes.items) |note| {
        if (note.position == .right_of) {
            const note_width: u32 = @intCast(note.text.len + 6); // box padding
            if (note_width > max_note_width) max_note_width = note_width;
        }
    }
    total_width += max_note_width;

    // Check width limit
    if (total_width > options.max_width) {
        return .{
            .output = source,
            .width = total_width,
            .height = 0,
            .is_fallback = true,
            .fallback_reason = "Diagram too wide for terminal",
        };
    }

    // Calculate height: header + messages + footer space
    const total_height: u32 = participant_height + total_message_height + 2;

    // Create canvas
    var canvas = try Canvas.init(allocator, total_width, total_height);
    defer canvas.deinit();

    // Draw participant boxes at top
    for (diagram.participants.items) |*p| {
        drawParticipantBox(&canvas, p, 0, options);
    }

    // Draw lifelines
    const lifeline_start: i32 = @intCast(participant_height);
    const lifeline_end: i32 = @intCast(total_height - 1);
    for (diagram.participants.items) |*p| {
        const center_x = (p.x orelse 0) + @as(i32, @intCast(p.box_width / 2));
        drawLifeline(&canvas, center_x, lifeline_start, lifeline_end, options);
    }

    // Track activation state per participant (start y-position, -1 if not active)
    const max_participants = 16;
    var activation_start_y: [max_participants]i32 = .{-1} ** max_participants;

    // Draw elements (messages, notes, activations) in order
    var current_y: i32 = @intCast(participant_height + 1);
    for (diagram.elements.items) |element| {
        switch (element) {
            .message => |msg| {
                drawSequenceMessage(&canvas, &msg, diagram, current_y, options);
                if (msg.is_self_message) {
                    current_y += @intCast(self_msg_row_height);
                } else {
                    current_y += @intCast(normal_row_height);
                }
            },
            .note => |note| {
                drawSequenceNote(&canvas, &note, diagram, current_y, options);
                current_y += @intCast(note_row_height);
            },
            .activation => |act| {
                if (diagram.getParticipantIndex(act.participant)) |idx| {
                    if (idx < max_participants) {
                        if (act.is_activate) {
                            // Start tracking activation at the previous row (where message arrived)
                            activation_start_y[idx] = current_y - 1;
                        } else {
                            // End activation - draw the box
                            const start_y = activation_start_y[idx];
                            if (start_y >= 0) {
                                if (diagram.getParticipant(act.participant)) |p| {
                                    drawActivationBox(&canvas, p, start_y, current_y - 1, options);
                                }
                                activation_start_y[idx] = -1;
                            }
                        }
                    }
                }
            },
        }
    }

    // Convert to string
    const output = try canvas.toString(allocator);

    return .{
        .output = output,
        .width = total_width,
        .height = total_height,
        .is_fallback = false,
        .fallback_reason = null,
    };
}

fn renderSequenceLR(allocator: Allocator, source: []const u8, diagram: *SequenceDiagram, hints: CompactionHints) !RenderResult {
    const options = hints.render_options;
    if (diagram.participants.items.len == 0) {
        return .{
            .output = "",
            .width = 0,
            .height = 0,
            .is_fallback = false,
            .fallback_reason = null,
        };
    }

    const participant_height: u32 = 3;
    const participant_spacing: u32 = hints.sequence_participant_spacing;
    const padding: u32 = hints.sequence_padding;
    const min_box_width: u32 = 8;
    const min_column_width: u32 = @max(hints.sequence_participant_spacing + 4, 6);

    var max_box_width: u32 = min_box_width;
    for (diagram.participants.items) |*p| {
        p.box_width = @intCast(p.displayName().len + 4);
        if (p.box_width < min_box_width) p.box_width = min_box_width;
        if (p.box_width > max_box_width) max_box_width = p.box_width;
    }
    for (diagram.participants.items) |*p| {
        p.box_width = max_box_width;
    }

    var total_height: u32 = padding;
    for (diagram.participants.items) |*p| {
        p.x = @intCast(padding);
        p.y = @intCast(total_height);
        total_height += participant_height + participant_spacing;
    }
    total_height = total_height - participant_spacing + padding;

    var total_width: u32 = max_box_width + padding * 2 + 2;
    for (diagram.elements.items) |element| {
        total_width += switch (element) {
            .message => |msg| blk: {
                const text_len: u32 = @intCast(processedLabelLen(msg.text));
                const extra: u32 = if (msg.is_self_message) 8 else 6;
                break :blk @max(text_len + extra, min_column_width);
            },
            .note => |note| @max(@as(u32, @intCast(processedLabelLen(note.text))) + 6, min_column_width),
            .activation => 2,
        };
    }
    total_width += padding;

    if (total_width > options.max_width) {
        return .{
            .output = source,
            .width = total_width,
            .height = total_height,
            .is_fallback = true,
            .fallback_reason = "Diagram too wide for terminal",
        };
    }

    var canvas = try Canvas.init(allocator, total_width, total_height);
    defer canvas.deinit();

    for (diagram.participants.items) |*p| {
        drawParticipantBox(&canvas, p, p.y orelse 0, options);
    }

    const lifeline_start_x: i32 = @intCast(padding + max_box_width);
    const lifeline_end_x: i32 = @intCast(total_width - padding - 1);
    for (diagram.participants.items) |*p| {
        drawLifelineHorizontal(&canvas, (p.y orelse 0) + 1, lifeline_start_x, lifeline_end_x, options);
    }

    const max_participants = 16;
    var activation_start_x: [max_participants]i32 = .{-1} ** max_participants;
    var current_x: i32 = lifeline_start_x + 2;

    for (diagram.elements.items) |element| {
        switch (element) {
            .message => |msg| {
                current_x += drawSequenceMessageLR(&canvas, &msg, diagram, current_x, options);
            },
            .note => |note| {
                current_x += drawSequenceNoteLR(&canvas, &note, diagram, current_x, options);
            },
            .activation => |act| {
                if (diagram.getParticipantIndex(act.participant)) |idx| {
                    if (idx < max_participants) {
                        if (act.is_activate) {
                            activation_start_x[idx] = current_x - 1;
                        } else {
                            const start_x = activation_start_x[idx];
                            if (start_x >= 0) {
                                if (diagram.getParticipant(act.participant)) |p| {
                                    drawActivationBoxLR(&canvas, p, start_x, current_x - 1, options);
                                }
                                activation_start_x[idx] = -1;
                            }
                        }
                    }
                }
                current_x += 2;
            },
        }
    }

    const output = try canvas.toString(allocator);
    return .{
        .output = output,
        .width = total_width,
        .height = total_height,
        .is_fallback = false,
        .fallback_reason = null,
    };
}

fn drawParticipantBox(canvas: *Canvas, participant: *const Participant, y: i32, options: RenderOptions) void {
    const x = participant.x orelse 0;
    const w = participant.box_width;
    const name = participant.displayName();

    const rect = Rect{
        .x = x,
        .y = y,
        .width = w,
        .height = 3,
    };

    // Draw box
    const box_style = if (options.unicode_mode) types.unicode_rounded else types.ascii_box;
    canvas.drawBox(rect, box_style, .node_border);

    // Draw name centered
    canvas.drawTextCentered(rect, name, .node_text);
}

fn drawLifeline(canvas: *Canvas, x: i32, y_start: i32, y_end: i32, options: RenderOptions) void {
    const char: u21 = if (options.unicode_mode) LineChars.vertical_dotted else '|';
    canvas.drawVerticalLine(x, y_start, y_end, char, .edge);
}

fn drawLifelineHorizontal(canvas: *Canvas, y: i32, x_start: i32, x_end: i32, options: RenderOptions) void {
    const char: u21 = if (options.unicode_mode) LineChars.horizontal_dotted else '-';
    canvas.drawHorizontalLine(y, x_start, x_end, char, .edge);
}

fn drawActivationBox(canvas: *Canvas, participant: *const Participant, y_start: i32, y_end: i32, options: RenderOptions) void {
    const center_x = (participant.x orelse 0) + @as(i32, @intCast(participant.box_width / 2));
    const box_half_width: i32 = 1;

    // Draw a narrow box around the lifeline
    const left = center_x - box_half_width;
    const right = center_x + box_half_width;

    // Draw box borders
    const box_style = if (options.unicode_mode) types.unicode_square else types.ascii_box;

    // Top border
    canvas.setChar(left, y_start, box_style.top_left, .node_border);
    canvas.setChar(center_x, y_start, box_style.horizontal, .node_border);
    canvas.setChar(right, y_start, box_style.top_right, .node_border);

    // Bottom border
    canvas.setChar(left, y_end, box_style.bottom_left, .node_border);
    canvas.setChar(center_x, y_end, box_style.horizontal, .node_border);
    canvas.setChar(right, y_end, box_style.bottom_right, .node_border);

    // Side borders
    var y = y_start + 1;
    while (y < y_end) : (y += 1) {
        canvas.setChar(left, y, box_style.vertical, .node_border);
        canvas.setChar(right, y, box_style.vertical, .node_border);
    }
}

fn drawActivationBoxLR(canvas: *Canvas, participant: *const Participant, x_start: i32, x_end: i32, options: RenderOptions) void {
    const center_y = (participant.y orelse 0) + 1;
    const top = center_y - 1;
    const bottom = center_y + 1;
    const box_style = if (options.unicode_mode) types.unicode_square else types.ascii_box;

    canvas.setChar(x_start, top, box_style.top_left, .node_border);
    canvas.setChar(x_end, top, box_style.top_right, .node_border);
    canvas.setChar(x_start, bottom, box_style.bottom_left, .node_border);
    canvas.setChar(x_end, bottom, box_style.bottom_right, .node_border);

    if (x_end - x_start > 1) {
        canvas.drawHorizontalLine(top, x_start + 1, x_end - 1, box_style.horizontal, .node_border);
        canvas.drawHorizontalLine(bottom, x_start + 1, x_end - 1, box_style.horizontal, .node_border);
    }

    canvas.setChar(x_start, center_y, box_style.vertical, .node_border);
    canvas.setChar(x_end, center_y, box_style.vertical, .node_border);
}

fn drawSequenceMessage(canvas: *Canvas, msg: *const Message, diagram: *const SequenceDiagram, y: i32, options: RenderOptions) void {
    const from_idx = diagram.getParticipantIndex(msg.from) orelse return;
    const to_idx = diagram.getParticipantIndex(msg.to) orelse return;

    const from_p = &diagram.participants.items[from_idx];
    const to_p = &diagram.participants.items[to_idx];

    const from_x = (from_p.x orelse 0) + @as(i32, @intCast(from_p.box_width / 2));
    const to_x = (to_p.x orelse 0) + @as(i32, @intCast(to_p.box_width / 2));

    // Process message text to handle <br/> tags
    var text_buf: [256]u8 = undefined;
    const text = processLabel(msg.text, &text_buf);

    // Handle self-message
    if (msg.is_self_message) {
        drawSelfMessage(canvas, from_x, y, text, options);
        return;
    }

    // Determine direction and draw arrow
    const left_x = @min(from_x, to_x);
    const right_x = @max(from_x, to_x);
    const going_right = to_x > from_x;

    // Draw the arrow line
    const line_char: u21 = if (msg.arrow_type.isDashed())
        LineChars.horizontal_dotted
    else
        LineChars.horizontal;

    canvas.drawHorizontalLine(y, left_x + 1, right_x - 1, line_char, .edge);

    // Draw arrowhead
    if (msg.arrow_type.hasArrowhead()) {
        const arrow_char: u21 = if (options.unicode_mode)
            (if (going_right) Arrows.right_thin else Arrows.left_thin)
        else
            (if (going_right) '>' else '<');
        canvas.setChar(to_x, y, arrow_char, .edge);
    }

    // Draw message text above the line
    const text_len: i32 = @intCast(text.len);
    const mid_x = left_x + @divFloor(right_x - left_x - text_len, 2);
    if (text_len > 0 and mid_x >= 0) {
        canvas.drawText(mid_x, y - 1, text, .edge_label);
    }
}

fn drawSequenceMessageLR(canvas: *Canvas, msg: *const Message, diagram: *const SequenceDiagram, x: i32, options: RenderOptions) i32 {
    const from_idx = diagram.getParticipantIndex(msg.from) orelse return 2;
    const to_idx = diagram.getParticipantIndex(msg.to) orelse return 2;

    const from_p = &diagram.participants.items[from_idx];
    const to_p = &diagram.participants.items[to_idx];
    const from_y = (from_p.y orelse 0) + 1;
    const to_y = (to_p.y orelse 0) + 1;

    var text_buf: [256]u8 = undefined;
    const text = processLabel(msg.text, &text_buf);
    const used_width: i32 = @intCast(@max(text.len + 6, 8));

    if (msg.is_self_message) {
        drawSelfMessageLR(canvas, from_y, x, text, options);
        return @intCast(@max(text.len + 8, 8));
    }

    const top_y = @min(from_y, to_y);
    const bottom_y = @max(from_y, to_y);
    const going_down = to_y > from_y;
    const line_char: u21 = if (msg.arrow_type.isDashed()) LineChars.vertical_dotted else LineChars.vertical;

    if (bottom_y - top_y > 1) {
        canvas.drawVerticalLine(x, top_y + 1, bottom_y - 1, line_char, .edge);
    }

    if (msg.arrow_type.hasArrowhead()) {
        const arrow_char: u21 = if (options.unicode_mode)
            (if (going_down) Arrows.down_thin else Arrows.up_thin)
        else
            (if (going_down) 'v' else '^');
        canvas.setChar(x, to_y, arrow_char, .edge);
    }

    if (text.len > 0) {
        canvas.drawText(x + 2, top_y, text, .edge_label);
    }

    return used_width;
}

fn drawSelfMessage(canvas: *Canvas, x: i32, y: i32, text: []const u8, options: RenderOptions) void {
    // Self message: a small loop on the right side
    //    ─┐
    //     │ message
    //    ◀┘
    const loop_width: i32 = 4;

    // Top horizontal
    const h_char: u21 = if (options.unicode_mode) LineChars.horizontal else '-';
    canvas.drawHorizontalLine(y - 1, x + 1, x + loop_width, h_char, .edge);

    // Top-right corner
    const corner_tr: u21 = if (options.unicode_mode) LineChars.corner_sw else '+';
    canvas.setChar(x + loop_width, y - 1, corner_tr, .edge);

    // Vertical
    const v_char: u21 = if (options.unicode_mode) LineChars.vertical else '|';
    canvas.setChar(x + loop_width, y, v_char, .edge);

    // Bottom-right corner
    const corner_br: u21 = if (options.unicode_mode) LineChars.corner_nw else '+';
    canvas.setChar(x + loop_width, y + 1, corner_br, .edge);

    // Bottom horizontal
    canvas.drawHorizontalLine(y + 1, x + 1, x + loop_width - 1, h_char, .edge);

    // Arrow back
    const arrow: u21 = if (options.unicode_mode) Arrows.left_thin else '<';
    canvas.setChar(x, y + 1, arrow, .edge);

    // Text next to the loop
    if (text.len > 0) {
        canvas.drawText(x + loop_width + 2, y, text, .edge_label);
    }
}

fn drawSelfMessageLR(canvas: *Canvas, y: i32, x: i32, text: []const u8, options: RenderOptions) void {
    const v_char: u21 = if (options.unicode_mode) LineChars.vertical else '|';
    const h_char: u21 = if (options.unicode_mode) LineChars.horizontal else '-';
    const corner_bl: u21 = if (options.unicode_mode) LineChars.corner_ne else '+';
    const corner_br: u21 = if (options.unicode_mode) LineChars.corner_nw else '+';

    canvas.drawVerticalLine(x, y + 1, y + 3, v_char, .edge);
    canvas.setChar(x, y + 3, corner_bl, .edge);
    canvas.drawHorizontalLine(y + 3, x + 1, x + 3, h_char, .edge);
    canvas.setChar(x + 3, y + 3, corner_br, .edge);
    canvas.setChar(x + 3, y, if (options.unicode_mode) Arrows.up_thin else '^', .edge);

    if (text.len > 0) {
        canvas.drawText(x + 5, y + 1, text, .edge_label);
    }
}

fn drawSequenceNote(canvas: *Canvas, note: *const types.SequenceNote, diagram: *const SequenceDiagram, y: i32, options: RenderOptions) void {
    // Process note text
    var text_buf: [256]u8 = undefined;
    const text = processLabel(note.text, &text_buf);

    // Get participant positions
    const p1_idx = diagram.getParticipantIndex(note.participant1) orelse return;
    const p1 = &diagram.participants.items[p1_idx];
    const p1_center = (p1.x orelse 0) + @as(i32, @intCast(p1.box_width / 2));

    // Calculate note box position and size
    const text_len: i32 = @intCast(text.len);
    const box_width: i32 = text_len + 4; // padding
    var box_x: i32 = undefined;

    switch (note.position) {
        .right_of => {
            // Note to the right of participant
            box_x = p1_center + 2;
        },
        .left_of => {
            // Note to the left of participant
            box_x = p1_center - box_width - 2;
        },
        .over => {
            if (note.participant2) |p2_id| {
                // Note over two participants - center between them
                if (diagram.getParticipantIndex(p2_id)) |p2_idx| {
                    const p2 = &diagram.participants.items[p2_idx];
                    const p2_center = (p2.x orelse 0) + @as(i32, @intCast(p2.box_width / 2));
                    const mid = @divFloor(p1_center + p2_center, 2);
                    box_x = mid - @divFloor(box_width, 2);
                } else {
                    box_x = p1_center - @divFloor(box_width, 2);
                }
            } else {
                // Note over single participant - center over it
                box_x = p1_center - @divFloor(box_width, 2);
            }
        },
    }

    // Draw note box
    const box_style = if (options.unicode_mode) types.unicode_rounded else types.ascii_box;
    const rect = Rect{
        .x = box_x,
        .y = y,
        .width = @intCast(box_width),
        .height = 3,
    };
    canvas.drawBox(rect, box_style, .edge_label);

    // Draw note text
    canvas.drawText(box_x + 2, y + 1, text, .edge_label);
}

fn drawSequenceNoteLR(canvas: *Canvas, note: *const types.SequenceNote, diagram: *const SequenceDiagram, x: i32, options: RenderOptions) i32 {
    var text_buf: [256]u8 = undefined;
    const text = processLabel(note.text, &text_buf);
    const box_width: i32 = @intCast(text.len + 4);

    const p1_idx = diagram.getParticipantIndex(note.participant1) orelse return 4;
    const p1 = &diagram.participants.items[p1_idx];
    var box_y = (p1.y orelse 0);

    if (note.participant2) |p2_id| {
        if (diagram.getParticipantIndex(p2_id)) |p2_idx| {
            const p2 = &diagram.participants.items[p2_idx];
            box_y = @divFloor((p1.y orelse 0) + (p2.y orelse 0), 2);
        }
    } else {
        switch (note.position) {
            .left_of => box_y -= 2,
            .right_of => box_y += 2,
            .over => {},
        }
    }

    const box_style = if (options.unicode_mode) types.unicode_rounded else types.ascii_box;
    const rect = Rect{ .x = x, .y = box_y, .width = @intCast(box_width), .height = 3 };
    canvas.drawBox(rect, box_style, .edge_label);
    canvas.drawText(x + 2, box_y + 1, text, .edge_label);
    return box_width + 2;
}

fn calculateBounds(graph: *const Graph) struct { width: u32, height: u32, offset_x: i32, offset_y: i32 } {
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = 0;
    var max_y: i32 = 0;

    var it = graph.nodes.valueIterator();
    while (it.next()) |node| {
        if (node.x) |x| {
            if (x < min_x) min_x = x;
            const right = x + @as(i32, @intCast(node.width));
            if (right > max_x) max_x = right;
        }
        if (node.y) |y| {
            if (y < min_y) min_y = y;
            const bottom = y + @as(i32, @intCast(node.height));
            if (bottom > max_y) max_y = bottom;
        }
    }

    // Add padding for subgraphs
    const subgraph_padding: i32 = if (graph.subgraphs.items.len > 0) 3 else 0;
    min_x -= subgraph_padding;
    min_y -= subgraph_padding;
    max_x += subgraph_padding;
    max_y += subgraph_padding;

    // Calculate offset to shift all coordinates (if min is negative or we need padding)
    const offset_x: i32 = if (min_x < 0) -min_x else 0;
    const offset_y: i32 = if (min_y < 0) -min_y else 0;

    return .{
        .width = @intCast(@max(max_x + offset_x, 1)),
        .height = @intCast(@max(max_y + offset_y, 1)),
        .offset_x = offset_x,
        .offset_y = offset_y,
    };
}

/// Process label to handle HTML entities like <br/>
fn processLabel(label: []const u8, buf: []u8) []const u8 {
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < label.len and out_idx < buf.len) {
        // Check for <br/> or <br> tags
        if (i + 4 < label.len and std.mem.eql(u8, label[i .. i + 4], "<br>")) {
            buf[out_idx] = ' ';
            out_idx += 1;
            i += 4;
        } else if (i + 5 <= label.len and std.mem.eql(u8, label[i .. i + 5], "<br/>")) {
            buf[out_idx] = ' ';
            out_idx += 1;
            i += 5;
        } else {
            buf[out_idx] = label[i];
            out_idx += 1;
            i += 1;
        }
    }
    return buf[0..out_idx];
}

fn processedLabelLen(label: []const u8) usize {
    var buf: [256]u8 = undefined;
    return processLabel(label, &buf).len;
}

fn drawWrappedTextCentered(canvas: *Canvas, rect: Rect, raw_label: []const u8, options: RenderOptions, top_inset: i32) void {
    var storage: [8][128]u8 = undefined;
    var lines: [8][]const u8 = undefined;
    const line_count = wrapLabelLines(raw_label, options.max_label_width, &storage, &lines);
    if (line_count == 0) return;

    const box_height: i32 = @intCast(rect.height);
    const content_height = @max(box_height - 2 - top_inset, 1);
    const start_y = rect.y + 1 + top_inset + @divFloor(content_height - @as(i32, @intCast(line_count)), 2);

    for (lines[0..line_count], 0..) |line, idx| {
        const line_len: i32 = @intCast(line.len);
        const x = rect.x + @divFloor(@as(i32, @intCast(rect.width)) - line_len, 2);
        canvas.drawText(x, start_y + @as(i32, @intCast(idx)), line, .node_text);
    }
}

fn wrapLabelLines(raw_label: []const u8, max_label_width: ?u32, storage: *[8][128]u8, out_lines: *[8][]const u8) usize {
    var processed_buf: [256]u8 = undefined;
    const processed = processLabel(raw_label, &processed_buf);
    const wrap_width: usize = if (max_label_width) |w| @intCast(@max(w, 1)) else processed.len;

    var line_count: usize = 0;
    var line_len: usize = 0;
    var i: usize = 0;

    while (i < processed.len and line_count < out_lines.len) {
        while (i < processed.len and processed[i] == ' ' and line_len == 0) : (i += 1) {}
        if (i >= processed.len) break;

        var word_end = i;
        while (word_end < processed.len and processed[word_end] != ' ') : (word_end += 1) {}
        const word = processed[i..word_end];

        if (line_len > 0 and line_len + 1 + word.len > wrap_width) {
            out_lines[line_count] = storage[line_count][0..line_len];
            line_count += 1;
            line_len = 0;
            if (line_count >= out_lines.len) break;
        }

        if (word.len > wrap_width and wrap_width > 0) {
            var consumed: usize = 0;
            while (consumed < word.len and line_count < out_lines.len) {
                if (line_len > 0) {
                    out_lines[line_count] = storage[line_count][0..line_len];
                    line_count += 1;
                    line_len = 0;
                    if (line_count >= out_lines.len) break;
                }

                const chunk_len = @min(wrap_width, word.len - consumed);
                @memcpy(storage[line_count][0..chunk_len], word[consumed .. consumed + chunk_len]);
                out_lines[line_count] = storage[line_count][0..chunk_len];
                line_count += 1;
                consumed += chunk_len;
            }
        } else {
            if (line_len > 0) {
                storage[line_count][line_len] = ' ';
                line_len += 1;
            }
            @memcpy(storage[line_count][line_len .. line_len + word.len], word);
            line_len += word.len;
        }

        i = word_end;
        while (i < processed.len and processed[i] == ' ') : (i += 1) {}
    }

    if (line_len > 0 and line_count < out_lines.len) {
        out_lines[line_count] = storage[line_count][0..line_len];
        line_count += 1;
    }

    return line_count;
}

fn drawNode(canvas: *Canvas, node: *const Node, options: RenderOptions) void {
    const x = node.x orelse return;
    const y = node.y orelse return;

    const rect = Rect{
        .x = x,
        .y = y,
        .width = node.width,
        .height = node.height,
    };

    // Handle special shapes
    if (options.unicode_mode) {
        switch (node.shape) {
            .diamond => {
                drawDiamondNode(canvas, rect, node.label, options);
                return;
            },
            .circle => {
                drawCircleNode(canvas, rect, node.label, options);
                return;
            },
            .cylinder => {
                drawCylinderNode(canvas, rect, node.label, options);
                return;
            },
            .stadium => {
                drawStadiumNode(canvas, rect, node.label, options);
                return;
            },
            else => {},
        }
    }

    // Get box style based on shape
    const box_style = node.shape.getBoxChars(options.unicode_mode);

    // Draw node box
    canvas.drawBox(rect, box_style, .node_border);

    drawWrappedTextCentered(canvas, rect, node.label, options, 0);
}

/// Draw diamond/decision node:      ¯
///                               < TEXT >
///                                  _
fn drawDiamondNode(canvas: *Canvas, rect: Rect, label: []const u8, options: RenderOptions) void {
    const x = rect.x;
    const y = rect.y;
    const w: i32 = @intCast(rect.width);
    const h: i32 = @intCast(rect.height);
    const mid_y = y + @divFloor(h, 2);
    const mid_x = x + @divFloor(w, 2);

    // Draw < on left, > on right
    canvas.setChar(x, mid_y, '<', .node_border);
    canvas.setChar(x + w - 1, mid_y, '>', .node_border);

    // Draw single macron at top center, single underscore at bottom center
    if (h >= 3) {
        canvas.setChar(mid_x, y, 0x00AF, .node_border); // ¯ (macron)
        canvas.setChar(mid_x, y + h - 1, '_', .node_border); // _
    }

    drawWrappedTextCentered(canvas, rect, label, options, 0);
}

/// Draw circle node:  ⏜
///                   ( TEXT )
///                    ⏝
fn drawCircleNode(canvas: *Canvas, rect: Rect, label: []const u8, options: RenderOptions) void {
    const x = rect.x;
    const y = rect.y;
    const w: i32 = @intCast(rect.width);
    const h: i32 = @intCast(rect.height);
    const mid_y = y + @divFloor(h, 2);
    const mid_x = x + @divFloor(w, 2);

    // Draw curved top ⏜
    canvas.setChar(mid_x, y, 0x23DC, .node_border);

    // Draw sides ( )
    canvas.setChar(x, mid_y, '(', .node_border);
    canvas.setChar(x + w - 1, mid_y, ')', .node_border);

    // Draw curved bottom ⏝
    canvas.setChar(mid_x, y + h - 1, 0x23DD, .node_border);

    drawWrappedTextCentered(canvas, rect, label, options, 0);
}

/// Draw cylinder/database node with two lines on top to show depth
///  ╭──────────╮
///  │──────────│
///  │ Database │
///  ╰──────────╯
fn drawCylinderNode(canvas: *Canvas, rect: Rect, label: []const u8, options: RenderOptions) void {
    const x = rect.x;
    const y = rect.y;
    const w: i32 = @intCast(rect.width);
    const h: i32 = @intCast(rect.height);

    // Top border with curved corners
    canvas.setChar(x, y, 0x256D, .node_border); // ╭
    canvas.setChar(x + w - 1, y, 0x256E, .node_border); // ╮

    var col = x + 1;
    while (col < x + w - 1) : (col += 1) {
        canvas.setChar(col, y, 0x2500, .node_border); // ─ top line
    }

    // Second line (inside) to show cylinder depth
    canvas.setChar(x, y + 1, 0x2502, .node_border); // │
    canvas.setChar(x + w - 1, y + 1, 0x2502, .node_border); // │
    col = x + 1;
    while (col < x + w - 1) : (col += 1) {
        canvas.setChar(col, y + 1, 0x2500, .node_border); // ─ second line (cylinder cap)
    }

    // Vertical sides (below the cap)
    var row = y + 2;
    while (row < y + h - 1) : (row += 1) {
        canvas.setChar(x, row, 0x2502, .node_border); // │
        canvas.setChar(x + w - 1, row, 0x2502, .node_border); // │
    }

    // Bottom border with curved corners
    canvas.setChar(x, y + h - 1, 0x2570, .node_border); // ╰
    canvas.setChar(x + w - 1, y + h - 1, 0x256F, .node_border); // ╯
    col = x + 1;
    while (col < x + w - 1) : (col += 1) {
        canvas.setChar(col, y + h - 1, 0x2500, .node_border); // ─
    }

    drawWrappedTextCentered(canvas, rect, label, options, 1);
}

/// Draw stadium node: 〔 TEXT 〕
fn drawStadiumNode(canvas: *Canvas, rect: Rect, label: []const u8, options: RenderOptions) void {
    const x = rect.x;
    const y = rect.y;
    const w: i32 = @intCast(rect.width);
    const h: i32 = @intCast(rect.height);
    const mid_y = y + @divFloor(h, 2);

    // Top and bottom lines
    var col = x + 1;
    while (col < x + w - 1) : (col += 1) {
        canvas.setChar(col, y, 0x2500, .node_border); // ─
        canvas.setChar(col, y + h - 1, 0x2500, .node_border); // ─
    }

    // Curved brackets on sides 〔 〕
    canvas.setChar(x, mid_y, 0x3014, .node_border); // 〔
    canvas.setChar(x + w - 1, mid_y, 0x3015, .node_border); // 〕

    // Vertical parts of sides (if height > 1)
    if (h >= 3) {
        var row = y + 1;
        while (row < y + h - 1) : (row += 1) {
            if (row != mid_y) {
                canvas.setChar(x, row, 0x2502, .node_border); // │
                canvas.setChar(x + w - 1, row, 0x2502, .node_border); // │
            }
        }
    }

    // Corners
    canvas.setChar(x, y, 0x256D, .node_border); // ╭
    canvas.setChar(x + w - 1, y, 0x256E, .node_border); // ╮
    canvas.setChar(x, y + h - 1, 0x2570, .node_border); // ╰
    canvas.setChar(x + w - 1, y + h - 1, 0x256F, .node_border); // ╯

    drawWrappedTextCentered(canvas, rect, label, options, 0);
}

fn drawEdge(allocator: Allocator, canvas: *Canvas, edge: *const Edge, graph: *const Graph, router: *const EdgeRouter, options: RenderOptions, edge_index: usize) !void {
    const from_node = graph.getNode(edge.from) orelse return;
    const to_node = graph.getNode(edge.to) orelse return;

    // Ensure both nodes have coordinates
    if (from_node.x == null or from_node.y == null) return;
    if (to_node.x == null or to_node.y == null) return;

    // Count edges from this node to distribute exit points
    var edge_count: i32 = 0;
    var this_edge_index: i32 = 0;
    for (graph.edges.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.from, edge.from)) {
            if (i == edge_index) {
                this_edge_index = edge_count;
            }
            edge_count += 1;
        }
    }

    // Calculate connection points on node boundaries with offset for multiple edges
    const direction = graph.direction;
    const start = getExitPointOffset(from_node, direction, this_edge_index, edge_count);
    const end = getEntryPoint(to_node, direction);

    // Generate path between nodes
    var path: std.ArrayList(Point) = .empty;
    defer path.deinit(allocator);

    try generatePath(allocator, &path, start, end, direction, router, edge.from, edge.to);

    // Draw the path
    if (path.items.len >= 2) {
        canvas.drawPath(path.items, edge.style, .edge);

        // Draw arrow at end
        if (edge.arrow_end != .none) {
            const arrow_pos = path.items[path.items.len - 1];
            const prev_pos = path.items[path.items.len - 2];
            drawArrowHead(canvas, prev_pos, arrow_pos, options.unicode_mode);
        }

        // Draw arrow at start (for bidirectional)
        if (edge.arrow_start != .none) {
            const arrow_pos = path.items[0];
            const next_pos = path.items[1];
            drawArrowHead(canvas, next_pos, arrow_pos, options.unicode_mode);
        }

        // Draw edge label if present
        if (edge.label) |label| {
            drawEdgeLabel(canvas, path.items, label, graph.direction);
        }
    }
}

/// Draw multiple edges from the same vertical-flow source node using a shared stem
/// and a horizontal branch bar, then individual paths to each destination.
fn drawEdgeGroup(allocator: Allocator, canvas: *Canvas, from_id: []const u8, graph: *const Graph, _router: *const EdgeRouter, options: RenderOptions) !void {
    _ = _router;
    const from_node = graph.getNode(from_id) orelse return;
    if (from_node.x == null or from_node.y == null) return;

    // Collect all edges from this source
    var group_edges: std.ArrayList(*const Edge) = .empty;
    defer group_edges.deinit(allocator);
    for (graph.edges.items) |*edge| {
        if (std.mem.eql(u8, edge.from, from_id)) {
            try group_edges.append(allocator, edge);
        }
    }
    if (group_edges.items.len == 0) return;

    const direction = graph.direction;
    // Single center exit point from the source node
    const stem_start = getExitPoint(from_node, direction);

    // For TB/TD: stem goes down, branch bar is horizontal
    // For BT: stem goes up, branch bar is horizontal
    // Compute branch row: one row above all destination entry points
    // (or one step from stem start if there's more space)
    var min_entry_y: i32 = std.math.maxInt(i32);
    var max_entry_y: i32 = std.math.minInt(i32);
    for (group_edges.items) |edge| {
        const to_node = graph.getNode(edge.to) orelse continue;
        if (to_node.x == null or to_node.y == null) continue;
        const entry = getEntryPoint(to_node, direction);
        if (entry.y < min_entry_y) min_entry_y = entry.y;
        if (entry.y > max_entry_y) max_entry_y = entry.y;
    }
    const branch_y: i32 = if (direction == .BT) blk: {
        // BT: stem goes up, branch bar above stem start
        const candidate = if (max_entry_y != std.math.minInt(i32)) max_entry_y + 1 else stem_start.y - 1;
        break :blk @max(candidate, stem_start.y - 1);
    } else blk: {
        // TB/TD: stem goes down, branch bar below stem start but above entry points
        const candidate = if (min_entry_y != std.math.maxInt(i32)) min_entry_y - 1 else stem_start.y + 1;
        break :blk @max(candidate, stem_start.y + 1);
    };
    const stem_x = stem_start.x;

    // Draw vertical stem from node to branch row
    canvas.drawVerticalLine(stem_x, stem_start.y, branch_y, LineChars.vertical, .edge);

    // Collect destination entry points
    var dest_xs: std.ArrayList(i32) = .empty;
    defer dest_xs.deinit(allocator);
    for (group_edges.items) |edge| {
        const to_node = graph.getNode(edge.to) orelse continue;
        if (to_node.x == null or to_node.y == null) continue;
        const entry = getEntryPoint(to_node, direction);
        try dest_xs.append(allocator, entry.x);
    }

    if (dest_xs.items.len == 0) return;

    // Sort dest_xs so we draw the branch bar left-to-right
    std.sort.pdq(i32, dest_xs.items, {}, std.sort.asc(i32));

    const bar_left = @min(stem_x, dest_xs.items[0]);
    const bar_right = @max(stem_x, dest_xs.items[dest_xs.items.len - 1]);

    // Draw horizontal branch bar
    canvas.drawHorizontalLine(branch_y, bar_left, bar_right, LineChars.horizontal, .edge);

    // Place junction characters on the branch bar
    for (dest_xs.items) |dx| {
        if (dx == stem_x) continue; // stem junction handled below
        const junc: u21 = if (direction == .BT) LineChars.tee_up else LineChars.tee_down;
        canvas.setChar(dx, branch_y, junc, .edge);
    }
    // Stem meets branch bar - use tee pointing into the bar
    {
        const stem_junc: u21 = if (direction == .BT) LineChars.tee_up else LineChars.tee_down;
        canvas.setChar(stem_x, branch_y, stem_junc, .edge);
    }

    // Draw individual paths from branch points to destinations
    for (group_edges.items) |edge| {
        const to_node = graph.getNode(edge.to) orelse continue;
        if (to_node.x == null or to_node.y == null) continue;
        const entry = getEntryPoint(to_node, direction);
        const branch_start = Point{ .x = entry.x, .y = branch_y };

        // Draw vertical segment from just past branch bar to destination entry point
        // (don't include branch_y itself so tee characters aren't overwritten)
        const seg_start: i32 = if (direction == .BT) branch_y - 1 else branch_y + 1;
        if ((direction == .BT and seg_start >= entry.y) or (direction != .BT and seg_start <= entry.y)) {
            canvas.drawVerticalLine(entry.x, seg_start, entry.y, LineChars.vertical, .edge);
        }

        // Draw arrowhead at destination using direction-aware anchor point
        if (edge.arrow_end != .none) {
            const arrow_from: Point = switch (direction) {
                .BT => .{ .x = entry.x, .y = entry.y + 1 },
                else => .{ .x = entry.x, .y = entry.y - 1 },
            };
            drawArrowHead(canvas, arrow_from, entry, options.unicode_mode);
        }

        // Draw edge label if present
        if (edge.label) |label| {
            const seg = [_]Point{ branch_start, entry };
            drawEdgeLabel(canvas, &seg, label, direction);
        }
    }
}

fn getExitPoint(node: *const Node, direction: Direction) Point {
    return getExitPointOffset(node, direction, 0, 1);
}

fn getExitPointOffset(node: *const Node, direction: Direction, edge_idx: i32, edge_count: i32) Point {
    const x = node.x orelse 0;
    const y = node.y orelse 0;
    const w: i32 = @intCast(node.width);
    const h: i32 = @intCast(node.height);

    // Calculate offset for multiple edges from same node
    // Spread edges across the exit side of the node
    const spread: i32 = if (edge_count > 1) blk: {
        // Use the dimension perpendicular to flow direction
        const size = if (direction.isHorizontal()) h else w;
        // Calculate position for this edge index (0, 1, 2, ...)
        // Spread evenly across the available space
        const step = @divFloor(size, edge_count + 1);
        break :blk step * (edge_idx + 1) - @divFloor(size, 2);
    } else 0;

    return switch (direction) {
        .LR => .{ .x = x + w, .y = y + @divFloor(h, 2) + spread },
        .RL => .{ .x = x - 1, .y = y + @divFloor(h, 2) + spread },
        .TD, .TB => .{ .x = x + @divFloor(w, 2) + spread, .y = y + h },
        .BT => .{ .x = x + @divFloor(w, 2) + spread, .y = y - 1 },
    };
}

fn getEntryPoint(node: *const Node, direction: Direction) Point {
    const x = node.x orelse 0;
    const y = node.y orelse 0;
    const w: i32 = @intCast(node.width);
    const h: i32 = @intCast(node.height);

    return switch (direction) {
        .LR => .{ .x = x - 1, .y = y + @divFloor(h, 2) },
        .RL => .{ .x = x + w, .y = y + @divFloor(h, 2) },
        .TD, .TB => .{ .x = x + @divFloor(w, 2), .y = y - 1 },
        .BT => .{ .x = x + @divFloor(w, 2), .y = y + h },
    };
}

fn generatePath(
    allocator: Allocator,
    path: *std.ArrayList(Point),
    start: Point,
    end: Point,
    direction: Direction,
    router: *const EdgeRouter,
    from_id: []const u8,
    to_id: []const u8,
) !void {
    try router.buildPath(allocator, path, start, end, direction, from_id, to_id);
}

fn drawArrowHead(canvas: *Canvas, from: Point, to: Point, unicode_mode: bool) void {
    const dx = to.x - from.x;
    const dy = to.y - from.y;

    const arrow_char: u21 = if (unicode_mode) blk: {
        if (@abs(dx) > @abs(dy)) {
            break :blk if (dx > 0) Arrows.right_thin else Arrows.left_thin;
        } else {
            break :blk if (dy > 0) Arrows.down_thin else Arrows.up_thin;
        }
    } else blk: {
        if (@abs(dx) > @abs(dy)) {
            break :blk if (dx > 0) Arrows.right_ascii else Arrows.left_ascii;
        } else {
            break :blk if (dy > 0) Arrows.down_ascii else Arrows.up_ascii;
        }
    };

    canvas.setChar(to.x, to.y, arrow_char, .edge);
}

/// Draw T-junction where edge exits a node (like mermaid-ascii)
fn drawBoxStart(canvas: *Canvas, start: Point, direction: Direction, unicode_mode: bool) void {
    if (!unicode_mode) return; // ASCII mode doesn't have T-junctions

    const Junctions = types.Junctions;

    // Draw T-junction on the node border where edge exits
    const junction_char: u21 = switch (direction) {
        .LR => Junctions.tee_right, // ├ edge goes right
        .RL => Junctions.tee_left, // ┤ edge goes left
        .TD, .TB => Junctions.tee_down, // ┬ edge goes down
        .BT => Junctions.tee_up, // ┴ edge goes up
    };

    // Position is one step back from start (on the node border)
    const border_pos: Point = switch (direction) {
        .LR => .{ .x = start.x - 1, .y = start.y },
        .RL => .{ .x = start.x + 1, .y = start.y },
        .TD, .TB => .{ .x = start.x, .y = start.y - 1 },
        .BT => .{ .x = start.x, .y = start.y + 1 },
    };

    // Use node_text priority so it overwrites the node border
    canvas.setChar(border_pos.x, border_pos.y, junction_char, .node_text);
}

fn drawEdgeLabel(canvas: *Canvas, path: []const Point, label: []const u8, direction: Direction) void {
    if (path.len < 2) return;

    // Find midpoint of the path
    const start = path[0];
    const end = path[path.len - 1];
    const mid_x = @divFloor(start.x + end.x, 2);
    const mid_y = @divFloor(start.y + end.y, 2);

    const label_len: i32 = @intCast(label.len);

    // Position label centered on the edge, replacing edge line chars
    if (direction.isHorizontal()) {
        // Draw label on the edge line, centered between nodes
        const label_x = mid_x - @divFloor(label_len, 2);
        // Draw spaces before and after to clear edge chars, then the label
        if (label_x > 0) {
            canvas.setChar(label_x - 1, mid_y, ' ', .edge_label);
        }
        canvas.drawText(label_x, mid_y, label, .edge_label);
        canvas.setChar(label_x + label_len, mid_y, ' ', .edge_label);
    } else {
        // For vertical edges, draw label to the right
        const label_x = mid_x + 2;
        canvas.drawText(label_x, mid_y, label, .edge_label);
    }
}

fn drawSubgraph(canvas: *Canvas, subgraph: *types.Subgraph, graph: *const Graph, options: RenderOptions) !void {
    // Calculate bounding box of contained nodes
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);

    for (subgraph.node_ids.items) |node_id| {
        if (graph.getNode(node_id)) |node| {
            const x = node.x orelse continue;
            const y = node.y orelse continue;
            const w: i32 = @intCast(node.width);
            const h: i32 = @intCast(node.height);

            if (x < min_x) min_x = x;
            if (y < min_y) min_y = y;
            if (x + w > max_x) max_x = x + w;
            if (y + h > max_y) max_y = y + h;
        }
    }

    if (min_x == std.math.maxInt(i32)) return;

    // Add padding around subgraph
    const padding: i32 = 2;
    min_x -= padding;
    min_y -= padding;
    max_x += padding;
    max_y += padding;

    // Store calculated bounds
    subgraph.x = min_x;
    subgraph.y = min_y;
    subgraph.width = @intCast(max_x - min_x);
    subgraph.height = @intCast(max_y - min_y);

    // Draw subgraph border
    const box_style = if (options.unicode_mode) types.unicode_square else types.ascii_box;
    canvas.drawBox(.{
        .x = min_x,
        .y = min_y,
        .width = subgraph.width.?,
        .height = subgraph.height.?,
    }, box_style, .subgraph);

    // Draw subgraph label at top
    if (subgraph.label) |label| {
        canvas.drawText(min_x + 2, min_y, label, .subgraph);
    }
}

// =====================================================
// Class Diagram Rendering
// =====================================================

fn renderClassDiagram(allocator: Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    // Parse the diagram
    var diagram = try Parser.parseClassDiagram(allocator, source);
    defer diagram.deinit();

    if (diagram.class_order.items.len == 0) {
        return .{
            .output = "",
            .width = 0,
            .height = 0,
            .is_fallback = false,
            .fallback_reason = null,
        };
    }

    // Layout constants
    const class_padding: u32 = 2;
    const min_class_width: u32 = 16;
    const horizontal_spacing: u32 = 6;
    const vertical_spacing: u32 = 2;
    const header_height: u32 = 3;
    const separator_height: u32 = 1;

    // Calculate class sizes and determine layout
    var max_width: u32 = 0;
    var class_heights: std.ArrayList(u32) = .empty;
    defer class_heights.deinit(allocator);
    var class_widths: std.ArrayList(u32) = .empty;
    defer class_widths.deinit(allocator);

    for (diagram.class_order.items) |class_name| {
        if (diagram.getClassMut(class_name)) |class| {
            // Calculate width
            var width: u32 = @intCast(class_name.len + class_padding * 2);
            for (class.members.items) |m| {
                const member_len: u32 = @intCast(m.name.len + 2); // +2 for visibility and space
                if (member_len + class_padding * 2 > width) {
                    width = member_len + class_padding * 2;
                }
            }
            if (width < min_class_width) width = min_class_width;
            class.width = width;
            try class_widths.append(allocator, width);

            // Calculate height
            var attr_count: u32 = 0;
            var method_count: u32 = 0;
            for (class.members.items) |m| {
                if (m.is_method) {
                    method_count += 1;
                } else {
                    attr_count += 1;
                }
            }
            // Height = header + separator + attributes + separator + methods (minimum 1 line each section)
            const attr_section = if (attr_count > 0) attr_count else 1;
            const method_section = if (method_count > 0) method_count else 1;
            const height = header_height + separator_height + attr_section + separator_height + method_section + 1;
            class.height = height;
            try class_heights.append(allocator, height);
        }
    }

    // Simple layout: arrange classes in a grid
    const classes_per_row: u32 = 3;
    var current_x: i32 = 1;
    var current_y: i32 = 1;
    var row_height: u32 = 0;
    var col: u32 = 0;

    for (diagram.class_order.items) |class_name| {
        if (diagram.getClassMut(class_name)) |class| {
            class.x = current_x;
            class.y = current_y;

            if (class.height > row_height) row_height = class.height;

            current_x += @intCast(class.width + horizontal_spacing);
            col += 1;

            if (col >= classes_per_row) {
                const x_end: u32 = @intCast(current_x);
                if (x_end > max_width) max_width = x_end;
                current_x = 1;
                current_y += @intCast(row_height + vertical_spacing);
                row_height = 0;
                col = 0;
            }
        }
    }

    // Finalize dimensions
    const total_width: u32 = if (max_width > 0) max_width else @intCast(current_x);
    const total_height: u32 = @intCast(current_y + @as(i32, @intCast(row_height)) + 2);

    // Check width limit
    if (total_width > options.max_width) {
        return .{
            .output = source,
            .width = total_width,
            .height = total_height,
            .is_fallback = true,
            .fallback_reason = "Diagram too wide for terminal",
        };
    }

    // Create canvas
    var canvas = try Canvas.init(allocator, total_width, total_height);
    defer canvas.deinit();

    // Draw classes
    for (diagram.class_order.items) |class_name| {
        if (diagram.getClass(class_name)) |class| {
            drawClassBox(&canvas, class, options);
        }
    }

    // Draw relations
    for (diagram.relations.items) |*rel| {
        drawClassRelation(&canvas, rel, &diagram, options);
    }

    // Convert to string
    const output = try canvas.toString(allocator);

    return .{
        .output = output,
        .width = total_width,
        .height = total_height,
        .is_fallback = false,
        .fallback_reason = null,
    };
}

fn drawClassBox(canvas: *Canvas, class: *const Class, options: RenderOptions) void {
    const x = class.x orelse return;
    const y = class.y orelse return;
    const w: i32 = @intCast(class.width);
    const h: i32 = @intCast(class.height);

    const box_style = if (options.unicode_mode) types.unicode_square else types.ascii_box;

    // Draw outer box
    canvas.drawBox(.{
        .x = x,
        .y = y,
        .width = class.width,
        .height = class.height,
    }, box_style, .node_border);

    // Draw class name centered in header
    const name_len: i32 = @intCast(class.name.len);
    const name_x = x + @divFloor(w - name_len, 2);
    canvas.drawText(name_x, y + 1, class.name, .node_text);

    // Draw separator under header
    const sep_y = y + 2;
    canvas.setChar(x, sep_y, LineChars.tee_right, .node_border);
    var col = x + 1;
    while (col < x + w - 1) : (col += 1) {
        canvas.setChar(col, sep_y, LineChars.horizontal, .node_border);
    }
    canvas.setChar(x + w - 1, sep_y, LineChars.tee_left, .node_border);

    // Draw attributes
    var row = sep_y + 1;
    for (class.members.items) |m| {
        if (!m.is_method) {
            var buf: [64]u8 = undefined;
            const vis_char = m.visibility.toChar();
            var member_str: []const u8 = undefined;
            if (vis_char) |vc| {
                buf[0] = vc;
                const copy_len = @min(m.name.len, buf.len - 1);
                @memcpy(buf[1 .. 1 + copy_len], m.name[0..copy_len]);
                member_str = buf[0 .. 1 + copy_len];
            } else {
                member_str = m.name;
            }
            canvas.drawText(x + 1, row, member_str, .node_text);
            row += 1;
        }
    }

    // Draw separator between attributes and methods
    if (row < y + h - 2) {
        canvas.setChar(x, row, LineChars.tee_right, .node_border);
        col = x + 1;
        while (col < x + w - 1) : (col += 1) {
            canvas.setChar(col, row, LineChars.horizontal, .node_border);
        }
        canvas.setChar(x + w - 1, row, LineChars.tee_left, .node_border);
        row += 1;
    }

    // Draw methods
    for (class.members.items) |m| {
        if (m.is_method and row < y + h - 1) {
            var buf: [64]u8 = undefined;
            const vis_char = m.visibility.toChar();
            var member_str: []const u8 = undefined;
            if (vis_char) |vc| {
                buf[0] = vc;
                const copy_len = @min(m.name.len, buf.len - 1);
                @memcpy(buf[1 .. 1 + copy_len], m.name[0..copy_len]);
                member_str = buf[0 .. 1 + copy_len];
            } else {
                member_str = m.name;
            }
            canvas.drawText(x + 1, row, member_str, .node_text);
            row += 1;
        }
    }
}

fn drawClassRelation(canvas: *Canvas, rel: *const ClassRelation, diagram: *const ClassDiagram, options: RenderOptions) void {
    const from_class = diagram.getClass(rel.from) orelse return;
    const to_class = diagram.getClass(rel.to) orelse return;

    const from_x = from_class.x orelse return;
    const from_y = from_class.y orelse return;
    const to_x = to_class.x orelse return;
    const to_y = to_class.y orelse return;

    // Calculate center points
    const from_cx = from_x + @as(i32, @intCast(from_class.width / 2));
    const from_cy = from_y + @as(i32, @intCast(from_class.height / 2));
    const to_cx = to_x + @as(i32, @intCast(to_class.width / 2));
    const to_cy = to_y + @as(i32, @intCast(to_class.height / 2));

    // Determine connection points on class boundaries
    var start_x: i32 = from_cx;
    var start_y: i32 = from_y + @as(i32, @intCast(from_class.height));
    var end_x: i32 = to_cx;
    var end_y: i32 = to_y;

    // Horizontal connection if on same row
    if (@abs(from_cy - to_cy) < @as(i32, @intCast(from_class.height))) {
        if (to_x > from_x) {
            start_x = from_x + @as(i32, @intCast(from_class.width));
            start_y = from_cy;
            end_x = to_x;
            end_y = to_cy;
        } else {
            start_x = from_x;
            start_y = from_cy;
            end_x = to_x + @as(i32, @intCast(to_class.width));
            end_y = to_cy;
        }
    }

    // Draw the line
    const line_char: u21 = if (rel.relation_type == .dependency or rel.relation_type == .realization)
        LineChars.horizontal_dotted
    else
        LineChars.horizontal;

    if (start_y == end_y) {
        // Horizontal line
        const left = @min(start_x, end_x);
        const right = @max(start_x, end_x);
        canvas.drawHorizontalLine(start_y, left + 1, right - 1, line_char, .edge);
    } else {
        // Vertical line with corner
        const mid_y = @divFloor(start_y + end_y, 2);
        const v_char: u21 = if (rel.relation_type == .dependency or rel.relation_type == .realization)
            LineChars.vertical_dotted
        else
            LineChars.vertical;

        // Draw vertical from start
        canvas.drawVerticalLine(start_x, start_y, mid_y, v_char, .edge);
        // Draw horizontal
        const left = @min(start_x, end_x);
        const right = @max(start_x, end_x);
        canvas.drawHorizontalLine(mid_y, left, right, line_char, .edge);
        // Draw vertical to end
        canvas.drawVerticalLine(end_x, mid_y, end_y, v_char, .edge);
    }

    // Draw arrow/symbol at end based on relation type
    const arrow_info = rel.relation_type.getArrowChars(options.unicode_mode);
    if (arrow_info.end.len > 0) {
        canvas.drawText(end_x, end_y - 1, arrow_info.end, .edge);
    }
}

// =====================================================
// ER Diagram Rendering
// =====================================================

fn renderERDiagram(allocator: Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    // Parse the diagram
    var diagram = try Parser.parseERDiagram(allocator, source);
    defer diagram.deinit();

    if (diagram.entity_order.items.len == 0) {
        return .{
            .output = "",
            .width = 0,
            .height = 0,
            .is_fallback = false,
            .fallback_reason = null,
        };
    }

    // Layout constants
    const entity_padding: u32 = 2;
    const min_entity_width: u32 = 12;
    const entity_height: u32 = 3;
    const horizontal_spacing: u32 = 8;
    const vertical_spacing: u32 = 3;

    // Calculate entity sizes
    for (diagram.entity_order.items) |entity_name| {
        if (diagram.getEntityMut(entity_name)) |entity| {
            var width: u32 = @intCast(entity_name.len + entity_padding * 2);
            if (width < min_entity_width) width = min_entity_width;
            entity.width = width;
            entity.height = entity_height;
        }
    }

    // Simple layout: arrange entities in a row
    var current_x: i32 = 1;
    const y: i32 = 1;

    for (diagram.entity_order.items) |entity_name| {
        if (diagram.getEntityMut(entity_name)) |entity| {
            entity.x = current_x;
            entity.y = y;
            current_x += @intCast(entity.width + horizontal_spacing);
        }
    }

    // Calculate total dimensions
    const total_width: u32 = @intCast(@max(current_x, 1));
    var total_height: u32 = entity_height + vertical_spacing + 2;

    // Add height for relation labels
    total_height += @intCast(diagram.relations.items.len * 2);

    // Check width limit
    if (total_width > options.max_width) {
        return .{
            .output = source,
            .width = total_width,
            .height = total_height,
            .is_fallback = true,
            .fallback_reason = "Diagram too wide for terminal",
        };
    }

    // Create canvas
    var canvas = try Canvas.init(allocator, total_width, total_height);
    defer canvas.deinit();

    // Draw entities
    for (diagram.entity_order.items) |entity_name| {
        if (diagram.getEntity(entity_name)) |entity| {
            drawEntityBox(&canvas, entity, options);
        }
    }

    // Draw relations
    for (diagram.relations.items) |*rel| {
        drawERRelation(&canvas, rel, &diagram, options);
    }

    // Convert to string
    const output = try canvas.toString(allocator);

    return .{
        .output = output,
        .width = total_width,
        .height = total_height,
        .is_fallback = false,
        .fallback_reason = null,
    };
}

fn drawEntityBox(canvas: *Canvas, entity: *const Entity, options: RenderOptions) void {
    const x = entity.x orelse return;
    const y = entity.y orelse return;
    const w: i32 = @intCast(entity.width);

    const box_style = if (options.unicode_mode) types.unicode_square else types.ascii_box;

    // Draw box
    canvas.drawBox(.{
        .x = x,
        .y = y,
        .width = entity.width,
        .height = entity.height,
    }, box_style, .node_border);

    // Draw entity name centered
    const name_len: i32 = @intCast(entity.name.len);
    const name_x = x + @divFloor(w - name_len, 2);
    canvas.drawText(name_x, y + 1, entity.name, .node_text);
}

fn drawERRelation(canvas: *Canvas, rel: *const ERRelation, diagram: *const ERDiagram, options: RenderOptions) void {
    const from_entity = diagram.getEntity(rel.from) orelse return;
    const to_entity = diagram.getEntity(rel.to) orelse return;

    const from_x = from_entity.x orelse return;
    const from_y = from_entity.y orelse return;
    const to_x = to_entity.x orelse return;
    const to_y = to_entity.y orelse return;

    // Calculate connection points (right side of from, left side of to)
    const start_x = from_x + @as(i32, @intCast(from_entity.width));
    const start_y = from_y + @as(i32, @intCast(from_entity.height / 2));
    const end_x = to_x;
    const end_y = to_y + @as(i32, @intCast(to_entity.height / 2));

    // Draw the connecting line
    const line_char: u21 = if (options.unicode_mode) LineChars.horizontal else '-';

    if (start_y == end_y) {
        // Simple horizontal line
        canvas.drawHorizontalLine(start_y, start_x, end_x, line_char, .edge);
    } else {
        // Line with corners
        const mid_x = @divFloor(start_x + end_x, 2);
        const v_char: u21 = if (options.unicode_mode) LineChars.vertical else '|';

        canvas.drawHorizontalLine(start_y, start_x, mid_x, line_char, .edge);
        canvas.drawVerticalLine(mid_x, @min(start_y, end_y), @max(start_y, end_y), v_char, .edge);
        canvas.drawHorizontalLine(end_y, mid_x, end_x, line_char, .edge);
    }

    // Draw cardinality symbols
    // Left side (from)
    const left_card = rel.from_cardinality.toStringLeft(options.unicode_mode);
    canvas.drawText(start_x + 1, start_y, left_card, .edge_label);

    // Right side (to)
    const right_card = rel.to_cardinality.toStringRight(options.unicode_mode);
    canvas.drawText(end_x - @as(i32, @intCast(right_card.len)) - 1, end_y, right_card, .edge_label);

    // Draw label in the middle if present
    if (rel.label) |label| {
        const mid_x = @divFloor(start_x + end_x, 2);
        const label_len: i32 = @intCast(label.len);
        canvas.drawText(mid_x - @divFloor(label_len, 2), start_y + 1, label, .edge_label);
    }
}

// =====================================================
// Public API
// =====================================================

/// Render a mermaid diagram or return fallback
pub fn renderOrFallback(allocator: Allocator, source: []const u8, options: RenderOptions) RenderResult {
    return render(allocator, source, options) catch {
        return .{
            .output = source,
            .width = 0,
            .height = 0,
            .is_fallback = true,
            .fallback_reason = "Render failed",
        };
    };
}

/// Check if source is a mermaid diagram
pub fn isMermaidBlock(source: []const u8) bool {
    const diagram_type = DiagramType.fromSource(source);
    return diagram_type != .unsupported;
}

// =====================================================
// State Diagram Rendering
// =====================================================

fn renderStateDiagram(allocator: Allocator, source: []const u8, options: RenderOptions) !RenderResult {
    // Parse the diagram
    var diagram = try Parser.parseStateDiagram(allocator, source);
    defer diagram.deinit();

    if (diagram.state_order.items.len == 0) {
        return .{
            .output = "",
            .width = 0,
            .height = 0,
            .is_fallback = false,
            .fallback_reason = null,
        };
    }

    // Run layout algorithm
    var layout = StateLayout.init(allocator, &diagram, options);
    defer layout.deinit();
    try layout.run();

    // Calculate canvas bounds
    const bounds = layout.getBounds();
    const padding: u32 = 2;

    // Check if there are back-edges that need routing space (right side)
    var has_back_edge = false;
    var max_back_edge_label_len: usize = 0;
    for (diagram.transitions.items) |transition| {
        const from_state = diagram.getState(transition.from) orelse continue;
        const to_state = diagram.getState(transition.to) orelse continue;
        const from_y = from_state.y orelse continue;
        const to_y = to_state.y orelse continue;
        if (to_y < from_y) {
            has_back_edge = true;
            if (transition.label) |label| {
                if (label.len > max_back_edge_label_len) {
                    max_back_edge_label_len = label.len;
                }
            }
        }
    }

    // Check if there are skip-edges that need routing space (left side)
    // Skip edges are forward edges that span more than one layer
    var has_skip_edge = false;
    var max_skip_edge_label_len: usize = 0;
    for (diagram.transitions.items) |transition| {
        const from_state = diagram.getState(transition.from) orelse continue;
        const to_state = diagram.getState(transition.to) orelse continue;
        const from_layer = from_state.layer orelse continue;
        const to_layer = to_state.layer orelse continue;
        const from_x = from_state.x orelse continue;
        const to_x = to_state.x orelse continue;
        // Skip edge: forward edge spanning multiple layers with aligned centers
        const from_center = from_x + @as(i32, @intCast(from_state.width / 2));
        const to_center = to_x + @as(i32, @intCast(to_state.width / 2));
        if (to_layer > from_layer + 1 and from_center == to_center) {
            has_skip_edge = true;
            if (transition.label) |label| {
                if (label.len > max_skip_edge_label_len) {
                    max_skip_edge_label_len = label.len;
                }
            }
        }
    }

    // Add extra width for back-edge routing (route column + label space) on right
    const back_edge_width: u32 = if (has_back_edge) 4 + @as(u32, @intCast(max_back_edge_label_len)) else 0;
    // Add extra width for skip-edge routing on left
    const skip_edge_width: u32 = if (has_skip_edge) 5 + @as(u32, @intCast(max_skip_edge_label_len)) else 0;
    const canvas_width = bounds.width + padding * 2 + back_edge_width + skip_edge_width;
    const canvas_height = bounds.height + padding * 2;

    // Check if diagram fits
    if (canvas_width > options.max_width) {
        return .{
            .output = source,
            .width = canvas_width,
            .height = canvas_height,
            .is_fallback = true,
            .fallback_reason = "Diagram too wide for terminal",
        };
    }

    // Apply padding offset (including skip edge routing space on left)
    const left_offset = padding + skip_edge_width;
    for (diagram.state_order.items) |id| {
        if (diagram.getStateMut(id)) |state| {
            if (state.x) |*x| x.* += @intCast(left_offset);
            if (state.y) |*y| y.* += @intCast(padding);
        }
    }

    // Create canvas
    var canvas = try Canvas.init(allocator, canvas_width, canvas_height);
    defer canvas.deinit();

    // Draw transitions first (background)
    for (diagram.transitions.items, 0..) |*transition, idx| {
        drawStateTransition(&canvas, transition, &diagram, options, idx);
    }

    // Draw states on top
    for (diagram.state_order.items) |id| {
        if (diagram.getState(id)) |state| {
            drawState(&canvas, state, options);
        }
    }

    // Convert to string
    const output = try canvas.toString(allocator);

    return .{
        .output = output,
        .width = canvas_width,
        .height = canvas_height,
        .is_fallback = false,
        .fallback_reason = null,
    };
}

fn drawState(canvas: *Canvas, state: *const State, options: RenderOptions) void {
    const x = state.x orelse return;
    const y = state.y orelse return;

    switch (state.state_type) {
        .start => {
            // Draw filled circle for start state: ●
            if (options.unicode_mode) {
                canvas.setChar(x + 1, y, 0x25CF, .node_text); // ●
            } else {
                canvas.setChar(x, y, '(', .node_border);
                canvas.setChar(x + 1, y, '*', .node_text);
                canvas.setChar(x + 2, y, ')', .node_border);
            }
        },
        .end => {
            // Draw circled dot for end state: ◎
            if (options.unicode_mode) {
                canvas.setChar(x + 1, y, 0x25CE, .node_text); // ◎
            } else {
                canvas.setChar(x, y, '(', .node_border);
                canvas.setChar(x + 1, y, 'o', .node_text);
                canvas.setChar(x + 2, y, ')', .node_border);
            }
        },
        .choice => {
            // Draw diamond for choice state
            const rect = Rect{
                .x = x,
                .y = y,
                .width = state.width,
                .height = state.height,
            };
            const label = state.label orelse state.id;
            drawDiamondNode(canvas, rect, label, options);
        },
        .fork, .join => {
            // Draw horizontal bar for fork/join
            const h_char: u21 = if (options.unicode_mode) LineChars.horizontal_thick else '=';
            var i: i32 = 0;
            while (i < @as(i32, @intCast(state.width))) : (i += 1) {
                canvas.setChar(x + i, y, h_char, .node_border);
            }
        },
        .regular, .composite => {
            // Draw rounded box for regular state
            const rect = Rect{
                .x = x,
                .y = y,
                .width = state.width,
                .height = state.height,
            };
            const label = state.label orelse state.id;

            // Use rounded corners for states
            const box_style = if (options.unicode_mode) types.unicode_rounded else types.ascii_box;
            canvas.drawBox(rect, box_style, .node_border);
            canvas.drawTextCentered(rect, label, .node_text);
        },
    }
}

fn drawStateTransition(canvas: *Canvas, transition: *const StateTransition, diagram: *const StateDiagram, options: RenderOptions, transition_idx: usize) void {
    const from_state = diagram.getState(transition.from) orelse return;
    const to_state = diagram.getState(transition.to) orelse return;

    const from_x = from_state.x orelse return;
    const from_y = from_state.y orelse return;
    const to_x = to_state.x orelse return;
    const to_y = to_state.y orelse return;

    const h_char: u21 = if (options.unicode_mode) LineChars.horizontal else '-';
    const v_char: u21 = if (options.unicode_mode) LineChars.vertical else '|';
    const arrow_down: u21 = if (options.unicode_mode) Arrows.down else 'v';
    _ = if (options.unicode_mode) Arrows.up else '^'; // arrow_up - reserved for future use

    // Calculate connection points
    const from_center_x = from_x + @as(i32, @intCast(from_state.width / 2));
    const from_bottom = from_y + @as(i32, @intCast(from_state.height));
    const to_center_x = to_x + @as(i32, @intCast(to_state.width / 2));
    const to_bottom = to_y + @as(i32, @intCast(to_state.height));

    // Determine if this is a back-edge (going up to earlier layer)
    const is_back_edge = to_y < from_y;

    // Count transitions between the same pair of states (for label positioning)
    var transition_count: u32 = 0;
    var my_index: u32 = 0;
    const state_a = if (is_back_edge) transition.to else transition.from;
    const state_b = if (is_back_edge) transition.from else transition.to;
    for (diagram.transitions.items, 0..) |t, idx| {
        // Check if this transition is between the same pair of states
        const t_is_back = blk: {
            const t_from = diagram.getState(t.from) orelse continue;
            const t_to = diagram.getState(t.to) orelse continue;
            const t_from_y = t_from.y orelse continue;
            const t_to_y = t_to.y orelse continue;
            break :blk t_to_y < t_from_y;
        };
        const t_state_a = if (t_is_back) t.to else t.from;
        const t_state_b = if (t_is_back) t.from else t.to;

        if (std.mem.eql(u8, t_state_a, state_a) and std.mem.eql(u8, t_state_b, state_b)) {
            if (idx == transition_idx) {
                my_index = transition_count;
            }
            transition_count += 1;
        }
    }

    if (is_back_edge) {
        // Back edge: straight vertical line going UP, parallel to forward edges
        // Position within box boundaries (right side of center, but inside the wider box)
        const wider_width = @max(from_state.width, to_state.width);
        const center_x = @max(from_center_x, to_center_x);
        const edge_x = center_x + @as(i32, @intCast(wider_width / 4));

        const from_top = from_y;
        const arrow_y = to_bottom; // Arrow at top, pointing UP into target

        // Calculate label position: middle of line, offset by index
        const line_middle = @divTrunc(to_bottom + from_top, 2);
        const label_offset = @as(i32, @intCast(my_index)) - @as(i32, @intCast(transition_count / 2));
        const label_y = line_middle + label_offset;

        // Draw vertical lines on every row
        var y = to_bottom;
        while (y < from_top) : (y += 1) {
            if (y == arrow_y) {
                // Arrow pointing up at top (just below target)
                const arrow_up: u21 = if (options.unicode_mode) 0x25B3 else '^'; // △
                canvas.setChar(edge_x, y, arrow_up, .edge);
            } else {
                canvas.setChar(edge_x, y, v_char, .edge);
            }
        }

        // Draw label on same row as │, to the right
        if (transition.label) |label| {
            var i: usize = 0;
            while (i < label.len) : (i += 1) {
                canvas.setChar(edge_x + 1 + @as(i32, @intCast(i)), label_y, label[i], .edge_label);
            }
        }
    } else if (from_center_x == to_center_x) {
        // Check if this is a "skip edge" - spans multiple layers with intermediate states
        // A skip edge needs to route around the side to avoid overlapping with intermediate nodes
        const from_layer = from_state.layer orelse 0;
        const to_layer = to_state.layer orelse 0;
        const is_skip_edge = to_layer > from_layer + 1;

        if (is_skip_edge) {
            // Skip edge: route around the LEFT side of the diagram
            // Path: down from source → corner → left → vertical down → corner → right → arrow up to target

            // Find the leftmost x coordinate of all states to route around them
            var min_x: i32 = from_x;
            for (diagram.state_order.items) |id| {
                if (diagram.getState(id)) |state| {
                    if (state.x) |sx| {
                        if (sx < min_x) min_x = sx;
                    }
                }
            }

            // Route column is to the left of all nodes (with some padding)
            const route_x = min_x - 3;
            const corner_se: u21 = if (options.unicode_mode) LineChars.corner_se else '+'; // ┌
            const corner_ne: u21 = if (options.unicode_mode) LineChars.corner_ne else '+'; // └

            // Start: exit from left side of source node
            const exit_y = from_y + @as(i32, @intCast(from_state.height / 2));
            const enter_y = to_y + @as(i32, @intCast(to_state.height / 2));

            // Draw horizontal from source to route column
            var hx = route_x;
            while (hx < from_x) : (hx += 1) {
                if (hx == route_x) {
                    canvas.setChar(hx, exit_y, corner_se, .edge); // ┌ at start
                } else {
                    canvas.setChar(hx, exit_y, h_char, .edge);
                }
            }

            // Draw vertical down along route column
            var vy = exit_y + 1;
            while (vy < enter_y) : (vy += 1) {
                canvas.setChar(route_x, vy, v_char, .edge);
            }

            // Draw corner at bottom of route column
            canvas.setChar(route_x, enter_y, corner_ne, .edge); // └

            // Draw horizontal from route column to target
            hx = route_x + 1;
            const target_entry_x = to_x;
            while (hx < target_entry_x) : (hx += 1) {
                if (hx == target_entry_x - 1) {
                    // Arrow pointing right at entry
                    const arrow_right: u21 = if (options.unicode_mode) Arrows.right else '>';
                    canvas.setChar(hx, enter_y, arrow_right, .edge);
                } else {
                    canvas.setChar(hx, enter_y, h_char, .edge);
                }
            }

            // Draw label along the vertical segment
            if (transition.label) |label| {
                const label_y = @divTrunc(exit_y + enter_y, 2);
                var i: usize = 0;
                while (i < label.len) : (i += 1) {
                    canvas.setChar(route_x + 1 + @as(i32, @intCast(i)), label_y, label[i], .edge_label);
                }
            }
        } else {
            // Regular forward edge: straight vertical line down
            const arrow_y = to_y - 1;

            // Calculate label position: middle of line, offset by index
            const line_middle = @divTrunc(from_bottom + to_y, 2);
            const label_offset = @as(i32, @intCast(my_index)) - @as(i32, @intCast(transition_count / 2));
            const label_y = line_middle + label_offset;

            // Draw vertical lines on every row
            var y = from_bottom;
            while (y < to_y) : (y += 1) {
                if (y == arrow_y) {
                    canvas.setChar(from_center_x, y, arrow_down, .edge);
                } else {
                    canvas.setChar(from_center_x, y, v_char, .edge);
                }
            }

            // Draw label on same row as │, to the left
            if (transition.label) |label| {
                var label_x = from_center_x - @as(i32, @intCast(label.len)) - 1;
                if (label_x < 0) {
                    label_x = 0;
                }
                var i: usize = 0;
                while (i < label.len) : (i += 1) {
                    canvas.setChar(label_x + @as(i32, @intCast(i)), label_y, label[i], .edge_label);
                }
            }
        }
    } else {
        // Forward edge but not aligned: route down, horizontal, down
        const mid_y = from_bottom + 1;

        // Down from source
        canvas.setChar(from_center_x, from_bottom, v_char, .edge);

        // Horizontal segment with corners
        const min_x = @min(from_center_x, to_center_x);
        const max_x = @max(from_center_x, to_center_x);
        var hx = min_x;
        while (hx <= max_x) : (hx += 1) {
            if (hx == from_center_x) {
                // Corner turning from vertical
                const corner: u21 = if (to_center_x > from_center_x)
                    (if (options.unicode_mode) 0x2514 else '+') // └
                else
                    (if (options.unicode_mode) 0x2518 else '+'); // ┘
                canvas.setChar(hx, mid_y, corner, .edge);
            } else if (hx == to_center_x) {
                // Corner turning down
                const corner: u21 = if (to_center_x > from_center_x)
                    (if (options.unicode_mode) 0x2510 else '+') // ┐
                else
                    (if (options.unicode_mode) 0x250C else '+'); // ┌
                canvas.setChar(hx, mid_y, corner, .edge);
            } else {
                canvas.setChar(hx, mid_y, h_char, .edge);
            }
        }

        // Down to target
        var y = mid_y + 1;
        while (y < to_y) : (y += 1) {
            if (y == to_y - 1) {
                canvas.setChar(to_center_x, y, arrow_down, .edge);
            } else {
                canvas.setChar(to_center_x, y, v_char, .edge);
            }
        }

        // Draw label
        if (transition.label) |label| {
            const label_x = @divTrunc(from_center_x + to_center_x, 2) - @as(i32, @intCast(label.len / 2));
            const label_y = mid_y;
            var i: usize = 0;
            while (i < label.len) : (i += 1) {
                canvas.setChar(label_x + @as(i32, @intCast(i)), label_y, label[i], .edge_label);
            }
        }
    }
}

test "render simple flowchart" {
    const testing = std.testing;

    const source =
        \\graph LR
        \\    A[Start] --> B[End]
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    try testing.expect(result.output.len > 0);
    try testing.expect(result.width > 0);
    try testing.expect(result.height > 0);

    // Output should contain our node labels
    try testing.expect(std.mem.indexOf(u8, result.output, "Start") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "End") != null);
}

test "render vertical flowchart" {
    const testing = std.testing;

    const source =
        \\graph TD
        \\    A[Top] --> B[Bottom]
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    try testing.expect(std.mem.indexOf(u8, result.output, "Top") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "Bottom") != null);
}

test "fallback for unsupported diagram" {
    const testing = std.testing;

    const source =
        \\pie
        \\    "A" : 30
        \\    "B" : 70
    ;

    const result = try render(testing.allocator, source, .{});

    try testing.expect(result.is_fallback);
    try testing.expectEqualStrings("Unsupported diagram type", result.fallback_reason.?);
}

test "render with edge labels" {
    const testing = std.testing;

    const source =
        \\graph LR
        \\    A -->|Yes| B
        \\    A -->|No| C
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    // Labels should appear in output
    try testing.expect(std.mem.indexOf(u8, result.output, "Yes") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "No") != null);
}

// =====================================================
// Sequence Diagram Tests
// =====================================================

test "render simple sequence diagram" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    Alice->>Bob: Hello Bob
        \\    Bob-->>Alice: Hi Alice
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    try testing.expect(result.output.len > 0);
    try testing.expect(result.width > 0);
    try testing.expect(result.height > 0);

    // Output should contain participant names
    try testing.expect(std.mem.indexOf(u8, result.output, "Alice") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "Bob") != null);

    // Output should contain message text
    try testing.expect(std.mem.indexOf(u8, result.output, "Hello Bob") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "Hi Alice") != null);
}

test "render sequence diagram with explicit participants" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    participant A as Alice
        \\    participant B as Bob
        \\    A->>B: Hello
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    // Should show alias names, not IDs
    try testing.expect(std.mem.indexOf(u8, result.output, "Alice") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "Bob") != null);
}

test "render sequence diagram in LR direction" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    direction LR
        \\    participant U as User
        \\    participant B as Backend
        \\    U->>B: Request
        \\    B-->>U: Response
    ;

    const result = try render(testing.allocator, source, .{ .max_width = 80 });
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    try testing.expect(std.mem.indexOf(u8, result.output, "User") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "Backend") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "Request") != null);
}

test "sequence diagram with self message" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    Alice->>Alice: Think
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    try testing.expect(std.mem.indexOf(u8, result.output, "Alice") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "Think") != null);
}

// =====================================================
// Class Diagram Tests
// =====================================================

test "render simple class diagram" {
    const testing = std.testing;

    const source =
        \\classDiagram
        \\    Animal <|-- Duck
        \\    Animal : +int age
        \\    Duck : +swim()
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    try testing.expect(result.output.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.output, "Animal") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "Duck") != null);
}

test "render class diagram with members" {
    const testing = std.testing;

    const source =
        \\classDiagram
        \\    class Vehicle
        \\    Vehicle : +String brand
        \\    Vehicle : +start()
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    try testing.expect(std.mem.indexOf(u8, result.output, "Vehicle") != null);
}

// =====================================================
// ER Diagram Tests
// =====================================================

test "render simple ER diagram" {
    const testing = std.testing;

    const source =
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    try testing.expect(result.output.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.output, "CUSTOMER") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "ORDER") != null);
}

test "render ER diagram with multiple relations" {
    const testing = std.testing;

    const source =
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
        \\    ORDER ||--|{ LINE-ITEM : contains
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    try testing.expect(std.mem.indexOf(u8, result.output, "CUSTOMER") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "ORDER") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "LINE-ITEM") != null);
}

// =====================================================
// State Diagram Tests
// =====================================================

test "render simple state diagram" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    [*] --> Still
        \\    Still --> Moving
        \\    Moving --> Still
        \\    Moving --> Crash
        \\    Crash --> [*]
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    try testing.expect(result.output.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.output, "Still") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "Moving") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "Crash") != null);
}

test "render state diagram with descriptions" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    s1 : State One
        \\    s2 : State Two
        \\    [*] --> s1
        \\    s1 --> s2
        \\    s2 --> [*]
    ;

    const result = try render(testing.allocator, source, .{});
    defer if (!result.is_fallback) testing.allocator.free(result.output);

    try testing.expect(!result.is_fallback);
    try testing.expect(std.mem.indexOf(u8, result.output, "State One") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "State Two") != null);
}
