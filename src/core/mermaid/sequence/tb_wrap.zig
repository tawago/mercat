//! The top-down sequence diagram for the wrap rungs: message labels wrapped to the lifelines
//! they span, self-message text wrapped to the width left of the budget.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const model = @import("model.zig");
const fit = @import("fit.zig");
const ladder = @import("../shared/ladder.zig");
const wrap = @import("../shared/wrap.zig");
const common = @import("common.zig");
const tb = @import("tb.zig");
const Canvas = @import("../shared/canvas.zig").Canvas;
const unicode = @import("unicode");
const draw_helpers = @import("../shared/draw_helpers.zig");

const SequenceDiagram = model.SequenceDiagram;
const Message = model.Message;
const LineChars = types.LineChars;
const Arrows = types.Arrows;

const self_text_floor: u32 = 10;
const unlimited = std.math.maxInt(u32);

const Row = struct { lines: []const wrap.Line = &.{}, height: u32 };

pub fn render(allocator: Allocator, diagram: *SequenceDiagram, spacing: fit.Spacing, max_width: u32) !ladder.Fit {
    if (diagram.participants.items.len == 0) return .{ .drawn = "" };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var width = placeParticipants(diagram, spacing);
    const rows = try scratch.alloc(Row, diagram.elements.items.len);
    var height: u32 = tb.participant_height + 2;
    for (diagram.elements.items, rows) |element, *row| {
        row.* = switch (element) {
            .message => |msg| if (msg.is_self_message)
                try selfRow(scratch, &msg, diagram, spacing, max_width, &width)
            else
                try messageRow(scratch, &msg, diagram),
            .note => |note| blk: {
                width = @max(width, try noteEnd(&note, diagram) + spacing.padding);
                break :blk .{ .height = tb.note_row_height };
            },
            .activation => .{ .height = 0 },
        };
        height += row.height;
    }
    if (width > max_width) return .{ .too_wide = width };

    var canvas = try Canvas.init(scratch, width, height);
    for (diagram.participants.items) |*p| try drawParticipant(&canvas, p);
    for (diagram.participants.items) |*p| {
        canvas.drawVerticalLine(p.centerX(), @intCast(tb.participant_height), @intCast(height - 1), LineChars.vertical_dotted, .edge);
    }

    var activations: common.Activations = .{};
    var top: i32 = @intCast(tb.participant_height);
    for (diagram.elements.items, rows) |element, row| {
        switch (element) {
            .message => |msg| if (msg.is_self_message)
                drawSelfMessage(&canvas, &msg, diagram, row, top)
            else
                drawMessage(&canvas, &msg, diagram, row, top),
            .note => |note| try drawNote(&canvas, &note, diagram, top),
            .activation => |act| if (activations.apply(diagram, act, top + 1)) |bar| tb.drawActivationBox(&canvas, bar),
        }
        top += @intCast(row.height);
    }

    return .{ .drawn = try canvas.toString(allocator) };
}

/// Lay the participants out as tb.zig does at this spacing; the width up to the last box's
/// right edge plus padding.
fn placeParticipants(diagram: *SequenceDiagram, spacing: fit.Spacing) u32 {
    var x: u32 = spacing.padding;
    for (diagram.participants.items) |*p| {
        p.box_width = p.naturalWidth();
        p.x = @intCast(x);
        x += p.box_width + spacing.participant;
    }
    return x - spacing.participant + spacing.padding;
}

const Span = struct { left: i32, right: i32 };

fn messageSpan(msg: *const Message, diagram: *const SequenceDiagram) ?Span {
    const from = diagram.getParticipant(msg.from) orelse return null;
    const to = diagram.getParticipant(msg.to) orelse return null;
    return .{ .left = @min(from.centerX(), to.centerX()), .right = @max(from.centerX(), to.centerX()) };
}

/// Label columns between the two lifelines, one clear column beside each so an activation bar
/// never covers a glyph.
fn labelRoom(span: Span) u32 {
    return @intCast(@max(span.right - span.left - 3, 1));
}

fn messageRow(scratch: Allocator, msg: *const Message, diagram: *const SequenceDiagram) !Row {
    const span = messageSpan(msg, diagram) orelse return .{ .height = tb.normal_row_height };
    const lines = try wrap.wrap(scratch, msg.text, labelRoom(span));
    return .{ .lines = lines, .height = @as(u32, @intCast(@max(lines.len, 1))) + 1 };
}

fn selfTextColumn(msg: *const Message, diagram: *const SequenceDiagram) ?i32 {
    const p = diagram.getParticipant(msg.from) orelse return null;
    return p.centerX() + @as(i32, @intCast(tb.self_msg_loop_width + tb.self_msg_text_offset));
}

fn selfRow(scratch: Allocator, msg: *const Message, diagram: *const SequenceDiagram, spacing: fit.Spacing, max_width: u32, width: *u32) !Row {
    const column = selfTextColumn(msg, diagram) orelse return .{ .height = tb.self_msg_row_height };
    const left = @as(i64, max_width) - spacing.padding - column;
    const room: u32 = @intCast(std.math.clamp(left, 0, unlimited));
    var lines = try wrap.wrap(scratch, msg.text, unlimited);
    if (widest(lines) > room) {
        lines = try wrap.wrap(scratch, msg.text, @max(room, @min(try wrap.longestWord(msg.text), self_text_floor)));
    }
    if (lines.len > 0) width.* = @max(width.*, @as(u32, @intCast(column)) + widest(lines) + spacing.padding);
    return .{ .lines = lines, .height = @max(tb.self_msg_row_height, @as(u32, @intCast(lines.len)) + 2) };
}

fn widest(lines: []const wrap.Line) u32 {
    var w: u32 = 0;
    for (lines) |line| w = @max(w, line.width);
    return w;
}

fn noteRect(note: *const model.SequenceNote, diagram: *const SequenceDiagram) !?types.Rect {
    const p1 = diagram.getParticipant(note.participant1) orelse return null;
    var text_buf: [256]u8 = undefined;
    const box_width: i32 = @intCast(try unicode.rawDisplayWidth(draw_helpers.processLabel(note.text, &text_buf)) + 4);
    const x = switch (note.position) {
        .right_of => p1.centerX() + 2,
        .left_of => p1.centerX() - box_width - 2,
        .over => blk: {
            const p2 = if (note.participant2) |id| diagram.getParticipant(id) else null;
            const mid = if (p2) |other| @divFloor(p1.centerX() + other.centerX(), 2) else p1.centerX();
            break :blk mid - @divFloor(box_width, 2);
        },
    };
    return .{ .x = @max(x, 0), .y = 0, .width = @intCast(box_width), .height = tb.note_row_height };
}

fn noteEnd(note: *const model.SequenceNote, diagram: *const SequenceDiagram) !u32 {
    const rect = try noteRect(note, diagram) orelse return 0;
    return @intCast(@max(rect.x + @as(i32, @intCast(rect.width)), 0));
}

fn drawNote(canvas: *Canvas, note: *const model.SequenceNote, diagram: *const SequenceDiagram, top: i32) !void {
    var rect = try noteRect(note, diagram) orelse return;
    rect.y = top;
    var text_buf: [256]u8 = undefined;
    canvas.drawBox(rect, types.unicode_rounded, .edge_label);
    canvas.drawTextSpanning(rect.x + 2, top + 1, draw_helpers.processLabel(note.text, &text_buf), .edge_label);
}

fn drawParticipant(canvas: *Canvas, p: *const model.Participant) !void {
    const rect = types.Rect{ .x = p.x, .y = 0, .width = p.box_width, .height = tb.participant_height };
    canvas.drawBox(rect, types.unicode_rounded, .node_border);
    const name = p.displayName();
    const name_width: i32 = @intCast(try unicode.rawDisplayWidth(name));
    canvas.drawTextSpanning(rect.x + @divFloor(@as(i32, @intCast(rect.width)) - name_width, 2), 1, name, .node_text);
}

fn drawMessage(canvas: *Canvas, msg: *const Message, diagram: *const SequenceDiagram, row: Row, top: i32) void {
    const span = messageSpan(msg, diagram) orelse return;
    const arrow_y = top + @as(i32, @intCast(row.height)) - 1;
    const line_char: u21 = if (msg.arrow_type.isDashed()) LineChars.horizontal_dotted else LineChars.horizontal;
    canvas.drawHorizontalLine(arrow_y, span.left + 1, span.right - 1, line_char, .edge);
    if (msg.arrow_type.hasArrowhead()) {
        const to_x = diagram.getParticipant(msg.to).?.centerX();
        canvas.setChar(to_x, arrow_y, if (to_x == span.right) Arrows.right_thin else Arrows.left_thin, .edge);
    }

    const room: i32 = @intCast(labelRoom(span));
    for (row.lines, 0..) |line, i| {
        const x = span.left + 2 + @divFloor(room - @as(i32, @intCast(line.width)), 2);
        canvas.drawTextSpanning(x, top + @as(i32, @intCast(i)), line.bytes, .edge_label);
    }
}

fn drawSelfMessage(canvas: *Canvas, msg: *const Message, diagram: *const SequenceDiagram, row: Row, top: i32) void {
    const p = diagram.getParticipant(msg.from) orelse return;
    tb.drawSelfMessage(canvas, p.centerX(), top + 1, "");
    const column = selfTextColumn(msg, diagram).?;
    for (row.lines, 0..) |line, i| {
        canvas.drawTextSpanning(column, top + 1 + @as(i32, @intCast(i)), line.bytes, .edge_label);
    }
}
