//! The top-down sequence diagram: participants side by side, one row of messages per element.

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

const participant_height: u32 = 3;
const normal_row_height: u32 = 2;
const self_msg_row_height: u32 = 4;
const self_msg_loop_width: u32 = 4;
const self_msg_text_offset: u32 = 2;
const note_row_height: u32 = 3;

const Size = struct { width: u32, height: u32 };

pub fn render(allocator: Allocator, diagram: *SequenceDiagram, spacing: fit.Spacing, max_width: u32) !ladder.Fit {
    if (diagram.participants.items.len == 0) {
        return .{ .drawn = "" };
    }

    const size = measure(diagram, spacing);
    if (size.width > max_width) {
        return .{ .too_wide = size.width };
    }

    var canvas = try Canvas.init(allocator, size.width, size.height);
    defer canvas.deinit();

    for (diagram.participants.items) |*p| {
        common.drawParticipantBox(&canvas, p, 0);
    }

    const lifeline_start: i32 = @intCast(participant_height);
    const lifeline_end: i32 = @intCast(size.height - 1);
    for (diagram.participants.items) |*p| {
        canvas.drawVerticalLine(p.centerX(), lifeline_start, lifeline_end, LineChars.vertical_dotted, .edge);
    }

    var activations: common.Activations = .{};
    var current_y: i32 = @intCast(participant_height + 1);
    for (diagram.elements.items) |element| {
        switch (element) {
            .message => |msg| {
                drawMessage(&canvas, &msg, diagram, current_y);
                current_y += @intCast(if (msg.is_self_message) self_msg_row_height else normal_row_height);
            },
            .note => |note| {
                drawNote(&canvas, &note, diagram, current_y);
                current_y += @intCast(note_row_height);
            },
            .activation => |act| {
                if (activations.apply(diagram, act, current_y)) |bar| {
                    drawActivationBox(&canvas, bar);
                }
            },
        }
    }

    return .{ .drawn = try canvas.toString(allocator) };
}

/// Place the participants left to right and size the canvas around them, their self-message
/// loops and the notes to the right of a lifeline.
fn measure(diagram: *SequenceDiagram, spacing: fit.Spacing) Size {
    var message_height: u32 = 0;
    var max_self_msg_text_len: u32 = 0;
    var max_note_width: u32 = 0;
    for (diagram.elements.items) |element| {
        switch (element) {
            .message => |msg| {
                if (msg.is_self_message) {
                    max_self_msg_text_len = @max(max_self_msg_text_len, @as(u32, @intCast(msg.text.len)));
                    message_height += self_msg_row_height;
                } else {
                    message_height += normal_row_height;
                }
            },
            .note => |note| {
                message_height += note_row_height;
                if (note.position == .right_of) {
                    max_note_width = @max(max_note_width, @as(u32, @intCast(note.text.len + 6)));
                }
            },
            .activation => {},
        }
    }

    var width: u32 = spacing.padding;
    for (diagram.participants.items) |*p| {
        p.box_width = p.naturalWidth();
        p.x = @intCast(width);
        width += p.box_width + spacing.participant;
    }
    width = width - spacing.participant + spacing.padding;

    if (max_self_msg_text_len > 0) {
        width += self_msg_loop_width + self_msg_text_offset + max_self_msg_text_len;
    }
    width += max_note_width;

    return .{ .width = width, .height = participant_height + message_height + 2 };
}

fn drawActivationBox(canvas: *Canvas, bar: common.Bar) void {
    const center_x = bar.participant.centerX();
    const left = center_x - 1;
    const right = center_x + 1;

    const box_style = types.unicode_square;

    canvas.setChar(left, bar.start, box_style.top_left, .node_border);
    canvas.setChar(center_x, bar.start, box_style.horizontal, .node_border);
    canvas.setChar(right, bar.start, box_style.top_right, .node_border);

    canvas.setChar(left, bar.end, box_style.bottom_left, .node_border);
    canvas.setChar(center_x, bar.end, box_style.horizontal, .node_border);
    canvas.setChar(right, bar.end, box_style.bottom_right, .node_border);

    var y = bar.start + 1;
    while (y < bar.end) : (y += 1) {
        canvas.setChar(left, y, box_style.vertical, .node_border);
        canvas.setChar(right, y, box_style.vertical, .node_border);
    }
}

fn drawMessage(canvas: *Canvas, msg: *const Message, diagram: *const SequenceDiagram, y: i32) void {
    const from_p = diagram.getParticipant(msg.from) orelse return;
    const to_p = diagram.getParticipant(msg.to) orelse return;

    const from_x = from_p.centerX();
    const to_x = to_p.centerX();

    var text_buf: [256]u8 = undefined;
    const text = processLabel(msg.text, &text_buf);

    if (msg.is_self_message) {
        drawSelfMessage(canvas, from_x, y, text);
        return;
    }

    const left_x = @min(from_x, to_x);
    const right_x = @max(from_x, to_x);
    const going_right = to_x > from_x;

    const line_char: u21 = if (msg.arrow_type.isDashed())
        LineChars.horizontal_dotted
    else
        LineChars.horizontal;

    canvas.drawHorizontalLine(y, left_x + 1, right_x - 1, line_char, .edge);

    if (msg.arrow_type.hasArrowhead()) {
        const arrow_char: u21 = if (going_right) Arrows.right_thin else Arrows.left_thin;
        canvas.setChar(to_x, y, arrow_char, .edge);
    }

    const text_len: i32 = @intCast(text.len);
    const mid_x = left_x + @divFloor(right_x - left_x - text_len, 2);
    if (text_len > 0 and mid_x >= 0) {
        canvas.drawText(mid_x, y - 1, text, .edge_label);
    }
}

fn drawSelfMessage(canvas: *Canvas, x: i32, y: i32, text: []const u8) void {
    const loop_width: i32 = 4;

    canvas.drawHorizontalLine(y - 1, x + 1, x + loop_width, LineChars.horizontal, .edge);
    canvas.setChar(x + loop_width, y - 1, LineChars.corner_sw, .edge);
    canvas.setChar(x + loop_width, y, LineChars.vertical, .edge);
    canvas.setChar(x + loop_width, y + 1, LineChars.corner_nw, .edge);
    canvas.drawHorizontalLine(y + 1, x + 1, x + loop_width - 1, LineChars.horizontal, .edge);
    canvas.setChar(x, y + 1, Arrows.left_thin, .edge);

    if (text.len > 0) {
        canvas.drawText(x + loop_width + 2, y, text, .edge_label);
    }
}

fn drawNote(canvas: *Canvas, note: *const model.SequenceNote, diagram: *const SequenceDiagram, y: i32) void {
    var text_buf: [256]u8 = undefined;
    const text = processLabel(note.text, &text_buf);

    const p1 = diagram.getParticipant(note.participant1) orelse return;
    const p1_center = p1.centerX();

    const text_len: i32 = @intCast(text.len);
    const box_width: i32 = text_len + 4;
    const box_x: i32 = switch (note.position) {
        .right_of => p1_center + 2,
        .left_of => p1_center - box_width - 2,
        .over => blk: {
            const p2 = if (note.participant2) |id| diagram.getParticipant(id) else null;
            const mid = if (p2) |other| @divFloor(p1_center + other.centerX(), 2) else p1_center;
            break :blk mid - @divFloor(box_width, 2);
        },
    };

    const rect = Rect{
        .x = box_x,
        .y = y,
        .width = @intCast(box_width),
        .height = 3,
    };
    canvas.drawBox(rect, types.unicode_rounded, .edge_label);
    canvas.drawText(box_x + 2, y + 1, text, .edge_label);
}
