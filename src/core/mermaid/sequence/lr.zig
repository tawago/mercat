//! The left-to-right sequence diagram: participants stacked top to bottom, one column of
//! messages per element.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const model = @import("model.zig");
const fit = @import("fit.zig");
const ladder = @import("../shared/ladder.zig");
const common = @import("common.zig");
const Canvas = @import("../shared/canvas.zig").Canvas;
const draw_helpers = @import("../shared/draw_helpers.zig");

const SequenceDiagram = model.SequenceDiagram;
const Message = model.Message;
const LineChars = types.LineChars;
const Arrows = types.Arrows;
const Rect = types.Rect;

const processLabel = draw_helpers.processLabel;
const processedLabelLen = draw_helpers.processedLabelLen;

const participant_height: u32 = 3;
const min_box_width: u32 = 8;

const Size = struct { width: u32, height: u32 };

pub fn render(allocator: Allocator, diagram: *SequenceDiagram, spacing: fit.Spacing, max_width: u32) !ladder.Fit {
    if (diagram.participants.items.len == 0) {
        return .{ .drawn = "" };
    }

    const box_width = stackParticipants(diagram, spacing);
    const size = measure(diagram, spacing, box_width);
    if (size.width > max_width) {
        return .{ .too_wide = size.width };
    }

    var canvas = try Canvas.init(allocator, size.width, size.height);
    defer canvas.deinit();

    for (diagram.participants.items) |*p| {
        common.drawParticipantBox(&canvas, p, p.y, .scalar);
    }

    const padding = spacing.padding;
    const lifeline_start_x: i32 = @intCast(padding + box_width);
    const lifeline_end_x: i32 = @intCast(size.width - padding - 1);
    for (diagram.participants.items) |*p| {
        canvas.drawHorizontalLine(p.y + 1, lifeline_start_x, lifeline_end_x, LineChars.horizontal_dotted, .edge);
    }

    var activations: common.Activations = .{};
    var current_x: i32 = lifeline_start_x + 2;
    for (diagram.elements.items) |element| {
        switch (element) {
            .message => |msg| {
                current_x += drawMessage(&canvas, &msg, diagram, current_x);
            },
            .note => |note| {
                current_x += drawNote(&canvas, &note, diagram, current_x);
            },
            .activation => |act| {
                if (activations.apply(diagram, act, current_x)) |bar| {
                    drawActivationBox(&canvas, bar);
                }
                current_x += 2;
            },
        }
    }

    return .{ .drawn = try canvas.toString(allocator) };
}

/// Give every participant the widest box and one row band, top to bottom; returns the box
/// width.
fn stackParticipants(diagram: *SequenceDiagram, spacing: fit.Spacing) u32 {
    var box_width: u32 = min_box_width;
    for (diagram.participants.items) |*p| {
        box_width = @max(box_width, p.naturalWidth());
    }

    var y: u32 = spacing.padding;
    for (diagram.participants.items) |*p| {
        p.box_width = box_width;
        p.x = @intCast(spacing.padding);
        p.y = @intCast(y);
        y += participant_height + spacing.participant;
    }
    return box_width;
}

fn measure(diagram: *const SequenceDiagram, spacing: fit.Spacing, box_width: u32) Size {
    const min_column_width: u32 = @max(spacing.participant + 4, 6);

    const last_y: u32 = @intCast(diagram.participants.items[diagram.participants.items.len - 1].y);
    const height = last_y + participant_height + spacing.padding;

    var width: u32 = box_width + spacing.padding * 2 + 2;
    for (diagram.elements.items) |element| {
        width += switch (element) {
            .message => |msg| blk: {
                const text_len: u32 = @intCast(processedLabelLen(msg.text));
                const extra: u32 = if (msg.is_self_message) 8 else 6;
                break :blk @max(text_len + extra, min_column_width);
            },
            .note => |note| @max(@as(u32, @intCast(processedLabelLen(note.text))) + 6, min_column_width),
            .activation => 2,
        };
    }
    width += spacing.padding;

    return .{ .width = width, .height = height };
}

fn drawActivationBox(canvas: *Canvas, bar: common.Bar) void {
    const center_y = bar.participant.y + 1;
    const top = center_y - 1;
    const bottom = center_y + 1;
    const box_style = types.unicode_square;

    canvas.setChar(bar.start, top, box_style.top_left, .node_border);
    canvas.setChar(bar.end, top, box_style.top_right, .node_border);
    canvas.setChar(bar.start, bottom, box_style.bottom_left, .node_border);
    canvas.setChar(bar.end, bottom, box_style.bottom_right, .node_border);

    if (bar.end - bar.start > 1) {
        canvas.drawHorizontalLine(top, bar.start + 1, bar.end - 1, box_style.horizontal, .node_border);
        canvas.drawHorizontalLine(bottom, bar.start + 1, bar.end - 1, box_style.horizontal, .node_border);
    }

    canvas.setChar(bar.start, center_y, box_style.vertical, .node_border);
    canvas.setChar(bar.end, center_y, box_style.vertical, .node_border);
}

fn drawMessage(canvas: *Canvas, msg: *const Message, diagram: *const SequenceDiagram, x: i32) i32 {
    const from_p = diagram.getParticipant(msg.from) orelse return 2;
    const to_p = diagram.getParticipant(msg.to) orelse return 2;
    const from_y = from_p.y + 1;
    const to_y = to_p.y + 1;

    var text_buf: [256]u8 = undefined;
    const text = processLabel(msg.text, &text_buf);
    const used_width: i32 = @intCast(@max(text.len + 6, 8));

    if (msg.is_self_message) {
        drawSelfMessage(canvas, from_y, x, text);
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
        const arrow_char: u21 = if (going_down) Arrows.down_thin else Arrows.up_thin;
        canvas.setChar(x, to_y, arrow_char, .edge);
    }

    if (text.len > 0) {
        canvas.drawText(x + 2, top_y, text, .edge_label);
    }

    return used_width;
}

fn drawSelfMessage(canvas: *Canvas, y: i32, x: i32, text: []const u8) void {
    canvas.drawVerticalLine(x, y + 1, y + 3, LineChars.vertical, .edge);
    canvas.setChar(x, y + 3, LineChars.corner_ne, .edge);
    canvas.drawHorizontalLine(y + 3, x + 1, x + 3, LineChars.horizontal, .edge);
    canvas.setChar(x + 3, y + 3, LineChars.corner_nw, .edge);
    canvas.setChar(x + 3, y, Arrows.up_thin, .edge);

    if (text.len > 0) {
        canvas.drawText(x + 5, y + 1, text, .edge_label);
    }
}

fn drawNote(canvas: *Canvas, note: *const model.SequenceNote, diagram: *const SequenceDiagram, x: i32) i32 {
    var text_buf: [256]u8 = undefined;
    const text = processLabel(note.text, &text_buf);
    const box_width: i32 = @intCast(text.len + 4);

    const p1 = diagram.getParticipant(note.participant1) orelse return 4;
    var box_y = p1.y;

    if (note.participant2) |p2_id| {
        if (diagram.getParticipant(p2_id)) |p2| {
            box_y = @divFloor(p1.y + p2.y, 2);
        }
    } else {
        switch (note.position) {
            .left_of => box_y -= 2,
            .right_of => box_y += 2,
            .over => {},
        }
    }

    const rect = Rect{ .x = x, .y = box_y, .width = @intCast(box_width), .height = 3 };
    canvas.drawBox(rect, types.unicode_rounded, .edge_label);
    canvas.drawText(x + 2, box_y + 1, text, .edge_label);
    return box_width + 2;
}
