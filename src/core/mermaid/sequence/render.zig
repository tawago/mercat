const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const parse = @import("parse.zig");
const model = @import("model.zig");
const canvas_mod = @import("../shared/canvas.zig");
const fit = @import("fit.zig");
const draw_helpers = @import("../shared/draw_helpers.zig");

const SequenceDiagram = model.SequenceDiagram;
const Participant = model.Participant;
const Message = model.Message;
const LineChars = types.LineChars;
const Arrows = types.Arrows;
const Rect = types.Rect;

const Canvas = canvas_mod.Canvas;

const processLabel = draw_helpers.processLabel;
const processedLabelLen = draw_helpers.processedLabelLen;

pub fn render(allocator: Allocator, source: []const u8, max_width: u32) !?[]const u8 {
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();

    for (fit.ladder(diagram.direction, diagram.direction_explicit)) |rung| {
        const spacing = rung orelse continue;
        const drawn = switch (spacing.direction orelse diagram.direction) {
            .LR => try renderSequenceLR(allocator, &diagram, spacing, max_width),
            else => try renderSequenceTB(allocator, &diagram, spacing, max_width),
        };
        if (drawn) |text| return text;
    }
    return null;
}

fn renderSequenceTB(allocator: Allocator, diagram: *SequenceDiagram, spacing: fit.Spacing, max_width: u32) !?[]const u8 {
    if (diagram.participants.items.len == 0) {
        return "";
    }

    const participant_height: u32 = 3;
    const normal_row_height: u32 = 2;
    const self_msg_row_height: u32 = 4;
    const min_participant_spacing: u32 = spacing.participant;
    const padding: u32 = spacing.padding;
    const self_msg_loop_width: u32 = 4;
    const self_msg_text_offset: u32 = 2;
    const note_row_height: u32 = 3;

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
    total_message_height += @intCast(diagram.notes.items.len * note_row_height);

    var total_width: u32 = padding;
    for (diagram.participants.items) |*p| {
        const name = p.displayName();
        p.box_width = @intCast(name.len + 4);
        if (p.box_width < 8) p.box_width = 8;
        p.x = @intCast(total_width);
        total_width += p.box_width + min_participant_spacing;
    }
    total_width = total_width - min_participant_spacing + padding;

    if (max_self_msg_text_len > 0) {
        total_width += self_msg_loop_width + self_msg_text_offset + max_self_msg_text_len;
    }

    var max_note_width: u32 = 0;
    for (diagram.notes.items) |note| {
        if (note.position == .right_of) {
            const note_width: u32 = @intCast(note.text.len + 6);
            if (note_width > max_note_width) max_note_width = note_width;
        }
    }
    total_width += max_note_width;

    if (total_width > max_width) {
        return null;
    }

    const total_height: u32 = participant_height + total_message_height + 2;

    var canvas = try Canvas.init(allocator, total_width, total_height);
    defer canvas.deinit();

    for (diagram.participants.items) |*p| {
        drawParticipantBox(&canvas, p, 0);
    }

    const lifeline_start: i32 = @intCast(participant_height);
    const lifeline_end: i32 = @intCast(total_height - 1);
    for (diagram.participants.items) |*p| {
        const center_x = (p.x orelse 0) + @as(i32, @intCast(p.box_width / 2));
        drawLifeline(&canvas, center_x, lifeline_start, lifeline_end);
    }

    const max_participants = 16;
    var activation_start_y: [max_participants]i32 = .{-1} ** max_participants;

    var current_y: i32 = @intCast(participant_height + 1);
    for (diagram.elements.items) |element| {
        switch (element) {
            .message => |msg| {
                drawSequenceMessage(&canvas, &msg, diagram, current_y);
                if (msg.is_self_message) {
                    current_y += @intCast(self_msg_row_height);
                } else {
                    current_y += @intCast(normal_row_height);
                }
            },
            .note => |note| {
                drawSequenceNote(&canvas, &note, diagram, current_y);
                current_y += @intCast(note_row_height);
            },
            .activation => |act| {
                if (diagram.getParticipantIndex(act.participant)) |idx| {
                    if (idx < max_participants) {
                        if (act.is_activate) {
                            activation_start_y[idx] = current_y - 1;
                        } else {
                            const start_y = activation_start_y[idx];
                            if (start_y >= 0) {
                                if (diagram.getParticipant(act.participant)) |p| {
                                    drawActivationBox(&canvas, p, start_y, current_y - 1);
                                }
                                activation_start_y[idx] = -1;
                            }
                        }
                    }
                }
            },
        }
    }

    const output = try canvas.toString(allocator);

    return output;
}

fn renderSequenceLR(allocator: Allocator, diagram: *SequenceDiagram, spacing: fit.Spacing, max_width: u32) !?[]const u8 {
    if (diagram.participants.items.len == 0) {
        return "";
    }

    const participant_height: u32 = 3;
    const participant_spacing: u32 = spacing.participant;
    const padding: u32 = spacing.padding;
    const min_box_width: u32 = 8;
    const min_column_width: u32 = @max(spacing.participant + 4, 6);

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

    if (total_width > max_width) {
        return null;
    }

    var canvas = try Canvas.init(allocator, total_width, total_height);
    defer canvas.deinit();

    for (diagram.participants.items) |*p| {
        drawParticipantBox(&canvas, p, p.y orelse 0);
    }

    const lifeline_start_x: i32 = @intCast(padding + max_box_width);
    const lifeline_end_x: i32 = @intCast(total_width - padding - 1);
    for (diagram.participants.items) |*p| {
        drawLifelineHorizontal(&canvas, (p.y orelse 0) + 1, lifeline_start_x, lifeline_end_x);
    }

    const max_participants = 16;
    var activation_start_x: [max_participants]i32 = .{-1} ** max_participants;
    var current_x: i32 = lifeline_start_x + 2;

    for (diagram.elements.items) |element| {
        switch (element) {
            .message => |msg| {
                current_x += drawSequenceMessageLR(&canvas, &msg, diagram, current_x);
            },
            .note => |note| {
                current_x += drawSequenceNoteLR(&canvas, &note, diagram, current_x);
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
                                    drawActivationBoxLR(&canvas, p, start_x, current_x - 1);
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
    return output;
}

fn drawParticipantBox(canvas: *Canvas, participant: *const Participant, y: i32) void {
    const x = participant.x orelse 0;
    const w = participant.box_width;
    const name = participant.displayName();

    const rect = Rect{
        .x = x,
        .y = y,
        .width = w,
        .height = 3,
    };

    const box_style = types.unicode_rounded;
    canvas.drawBox(rect, box_style, .node_border);
    canvas.drawTextCentered(rect, name, .node_text);
}

fn drawLifeline(canvas: *Canvas, x: i32, y_start: i32, y_end: i32) void {
    const char: u21 = LineChars.vertical_dotted;
    canvas.drawVerticalLine(x, y_start, y_end, char, .edge);
}

fn drawLifelineHorizontal(canvas: *Canvas, y: i32, x_start: i32, x_end: i32) void {
    const char: u21 = LineChars.horizontal_dotted;
    canvas.drawHorizontalLine(y, x_start, x_end, char, .edge);
}

fn drawActivationBox(canvas: *Canvas, participant: *const Participant, y_start: i32, y_end: i32) void {
    const center_x = (participant.x orelse 0) + @as(i32, @intCast(participant.box_width / 2));
    const box_half_width: i32 = 1;

    const left = center_x - box_half_width;
    const right = center_x + box_half_width;

    const box_style = types.unicode_square;

    canvas.setChar(left, y_start, box_style.top_left, .node_border);
    canvas.setChar(center_x, y_start, box_style.horizontal, .node_border);
    canvas.setChar(right, y_start, box_style.top_right, .node_border);

    canvas.setChar(left, y_end, box_style.bottom_left, .node_border);
    canvas.setChar(center_x, y_end, box_style.horizontal, .node_border);
    canvas.setChar(right, y_end, box_style.bottom_right, .node_border);

    var y = y_start + 1;
    while (y < y_end) : (y += 1) {
        canvas.setChar(left, y, box_style.vertical, .node_border);
        canvas.setChar(right, y, box_style.vertical, .node_border);
    }
}

fn drawActivationBoxLR(canvas: *Canvas, participant: *const Participant, x_start: i32, x_end: i32) void {
    const center_y = (participant.y orelse 0) + 1;
    const top = center_y - 1;
    const bottom = center_y + 1;
    const box_style = types.unicode_square;

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

fn drawSequenceMessage(canvas: *Canvas, msg: *const Message, diagram: *const SequenceDiagram, y: i32) void {
    const from_idx = diagram.getParticipantIndex(msg.from) orelse return;
    const to_idx = diagram.getParticipantIndex(msg.to) orelse return;

    const from_p = &diagram.participants.items[from_idx];
    const to_p = &diagram.participants.items[to_idx];

    const from_x = (from_p.x orelse 0) + @as(i32, @intCast(from_p.box_width / 2));
    const to_x = (to_p.x orelse 0) + @as(i32, @intCast(to_p.box_width / 2));

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

fn drawSequenceMessageLR(canvas: *Canvas, msg: *const Message, diagram: *const SequenceDiagram, x: i32) i32 {
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
        drawSelfMessageLR(canvas, from_y, x, text);
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

fn drawSelfMessage(canvas: *Canvas, x: i32, y: i32, text: []const u8) void {
    const loop_width: i32 = 4;

    const h_char: u21 = LineChars.horizontal;
    canvas.drawHorizontalLine(y - 1, x + 1, x + loop_width, h_char, .edge);

    const corner_tr: u21 = LineChars.corner_sw;
    canvas.setChar(x + loop_width, y - 1, corner_tr, .edge);

    const v_char: u21 = LineChars.vertical;
    canvas.setChar(x + loop_width, y, v_char, .edge);

    const corner_br: u21 = LineChars.corner_nw;
    canvas.setChar(x + loop_width, y + 1, corner_br, .edge);

    canvas.drawHorizontalLine(y + 1, x + 1, x + loop_width - 1, h_char, .edge);

    const arrow: u21 = Arrows.left_thin;
    canvas.setChar(x, y + 1, arrow, .edge);

    if (text.len > 0) {
        canvas.drawText(x + loop_width + 2, y, text, .edge_label);
    }
}

fn drawSelfMessageLR(canvas: *Canvas, y: i32, x: i32, text: []const u8) void {
    const v_char: u21 = LineChars.vertical;
    const h_char: u21 = LineChars.horizontal;
    const corner_bl: u21 = LineChars.corner_ne;
    const corner_br: u21 = LineChars.corner_nw;

    canvas.drawVerticalLine(x, y + 1, y + 3, v_char, .edge);
    canvas.setChar(x, y + 3, corner_bl, .edge);
    canvas.drawHorizontalLine(y + 3, x + 1, x + 3, h_char, .edge);
    canvas.setChar(x + 3, y + 3, corner_br, .edge);
    canvas.setChar(x + 3, y, Arrows.up_thin, .edge);

    if (text.len > 0) {
        canvas.drawText(x + 5, y + 1, text, .edge_label);
    }
}

fn drawSequenceNote(canvas: *Canvas, note: *const model.SequenceNote, diagram: *const SequenceDiagram, y: i32) void {
    var text_buf: [256]u8 = undefined;
    const text = processLabel(note.text, &text_buf);

    const p1_idx = diagram.getParticipantIndex(note.participant1) orelse return;
    const p1 = &diagram.participants.items[p1_idx];
    const p1_center = (p1.x orelse 0) + @as(i32, @intCast(p1.box_width / 2));

    const text_len: i32 = @intCast(text.len);
    const box_width: i32 = text_len + 4;
    var box_x: i32 = undefined;

    switch (note.position) {
        .right_of => {
            box_x = p1_center + 2;
        },
        .left_of => {
            box_x = p1_center - box_width - 2;
        },
        .over => {
            if (note.participant2) |p2_id| {
                if (diagram.getParticipantIndex(p2_id)) |p2_idx| {
                    const p2 = &diagram.participants.items[p2_idx];
                    const p2_center = (p2.x orelse 0) + @as(i32, @intCast(p2.box_width / 2));
                    const mid = @divFloor(p1_center + p2_center, 2);
                    box_x = mid - @divFloor(box_width, 2);
                } else {
                    box_x = p1_center - @divFloor(box_width, 2);
                }
            } else {
                box_x = p1_center - @divFloor(box_width, 2);
            }
        },
    }

    const box_style = types.unicode_rounded;
    const rect = Rect{
        .x = box_x,
        .y = y,
        .width = @intCast(box_width),
        .height = 3,
    };
    canvas.drawBox(rect, box_style, .edge_label);
    canvas.drawText(box_x + 2, y + 1, text, .edge_label);
}

fn drawSequenceNoteLR(canvas: *Canvas, note: *const model.SequenceNote, diagram: *const SequenceDiagram, x: i32) i32 {
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

    const box_style = types.unicode_rounded;
    const rect = Rect{ .x = x, .y = box_y, .width = @intCast(box_width), .height = 3 };
    canvas.drawBox(rect, box_style, .edge_label);
    canvas.drawText(x + 2, box_y + 1, text, .edge_label);
    return box_width + 2;
}
