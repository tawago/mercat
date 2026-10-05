//! The top-down sequence diagram for the wrap rungs: message labels wrapped to the lifelines
//! they span, self-message text wrapped to the width left of the budget. Text never lies under
//! an activation bar: labels take the widest gap between bars, self text stops short of one.

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

const self_text_floor: u32 = 10;
const unlimited = std.math.maxInt(u32);

/// Participants (by index, the tracked ones) whose drawn activation bar crosses an element.
const Barred = std.bit_set.IntegerBitSet(common.Activations.tracked);

/// The wrapped text lines start at `left`; message lines centre within `room` columns.
const Row = struct { lines: []const wrap.Line = &.{}, left: i32 = 0, room: u32 = 0, height: u32 };

pub fn render(allocator: Allocator, diagram: *SequenceDiagram, spacing: fit.Spacing, max_width: u32) !ladder.Fit {
    if (diagram.participants.items.len == 0) return .{ .drawn = "" };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var width = tb.placeParticipants(diagram, spacing, 0);
    const overhang = try noteOverhang(diagram);
    if (overhang > 0) width = tb.placeParticipants(diagram, spacing, overhang);

    const barred = try barredElements(scratch, diagram);
    const rows = try scratch.alloc(Row, diagram.elements.items.len);
    var height: u32 = tb.participant_height + 2;
    for (diagram.elements.items, rows, barred) |element, *row, bars| {
        row.* = switch (element) {
            .message => |msg| if (msg.is_self_message)
                try selfRow(scratch, &msg, diagram, bars, spacing, max_width, &width) orelse
                    return .{ .too_wide = unlimited }
            else
                try messageRow(scratch, &msg, diagram, bars) orelse
                    return .{ .too_wide = unlimited },
            .note => |note| blk: {
                if (try noteRect(&note, diagram)) |rect| width = @max(width, @as(u32, @intCast(rect.x)) + rect.width + spacing.padding);
                break :blk .{ .height = tb.note_row_height };
            },
            .activation => .{ .height = 0 },
        };
        height += row.height;
    }
    if (width > max_width) return .{ .too_wide = width };

    var canvas = try Canvas.init(scratch, width, height);
    for (diagram.participants.items) |*p| common.drawParticipantBox(&canvas, p, 0, .spanning);
    common.drawLifelines(&canvas, diagram, @intCast(tb.participant_height), @intCast(height - 1));

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

/// For each element, the participants whose bar is drawn across its rows, paired as
/// common.Activations pairs them. A bar's bottom lands on the first row after its deactivate.
fn barredElements(scratch: Allocator, diagram: *const SequenceDiagram) ![]Barred {
    const elements = diagram.elements.items;
    const barred = try scratch.alloc(Barred, elements.len);
    @memset(barred, Barred.initEmpty());
    var opened: [common.Activations.tracked]?usize = .{null} ** common.Activations.tracked;
    for (elements, 0..) |element, i| {
        const act = switch (element) {
            .activation => |act| act,
            else => continue,
        };
        const idx = diagram.getParticipantIndex(act.participant) orelse continue;
        if (idx >= common.Activations.tracked) continue;
        if (act.is_activate) {
            opened[idx] = i;
            continue;
        }
        const start = opened[idx] orelse continue;
        opened[idx] = null;
        var k = start + 1;
        while (k < elements.len) : (k += 1) {
            barred[k].set(idx);
            if (k > i and elements[k] != .activation) break;
        }
    }
    return barred;
}

/// How far the leftmost note box would reach past the left edge.
fn noteOverhang(diagram: *const SequenceDiagram) !u32 {
    var overhang: u32 = 0;
    for (diagram.elements.items) |element| {
        const note = switch (element) {
            .note => |note| note,
            else => continue,
        };
        const rect = try noteRect(&note, diagram) orelse continue;
        if (rect.x < 0) overhang = @max(overhang, @as(u32, @intCast(-rect.x)));
    }
    return overhang;
}

const Span = struct { left: i32, right: i32 };

fn messageSpan(msg: *const Message, diagram: *const SequenceDiagram) ?Span {
    const from = diagram.getParticipant(msg.from) orelse return null;
    const to = diagram.getParticipant(msg.to) orelse return null;
    return .{ .left = @min(from.centerX(), to.centerX()), .right = @max(from.centerX(), to.centerX()) };
}

const Gap = struct { left: i32, width: u32 };

/// The widest run of label columns between the two lifelines, one clear column beside each
/// lifeline and each crossed bar.
fn labelGap(span: Span, diagram: *const SequenceDiagram, bars: Barred) Gap {
    var best = Gap{ .left = span.left + 2, .width = 1 };
    var left = span.left + 2;
    for (diagram.participants.items, 0..) |*p, idx| {
        const center = p.centerX();
        if (center <= span.left or center >= span.right) continue;
        if (idx >= common.Activations.tracked or !bars.isSet(idx)) continue;
        widen(&best, left, center - 2);
        left = center + 2;
    }
    widen(&best, left, span.right - 2);
    return best;
}

fn widen(best: *Gap, left: i32, right: i32) void {
    if (right - left + 1 > best.width) best.* = .{ .left = left, .width = @intCast(right - left + 1) };
}

/// Null when a word of the label is wider than the gap: no width widens a gap this rung fixes.
fn messageRow(scratch: Allocator, msg: *const Message, diagram: *const SequenceDiagram, bars: Barred) !?Row {
    const span = messageSpan(msg, diagram) orelse return .{ .height = tb.normal_row_height };
    const gap = labelGap(span, diagram, bars);
    if (try wrap.longestWord(msg.text) > gap.width) return null;
    const lines = try wrap.wrap(scratch, msg.text, gap.width);
    return .{ .lines = lines, .left = gap.left, .room = gap.width, .height = @as(u32, @intCast(@max(lines.len, 1))) + 1 };
}

fn selfTextColumn(p: *const model.Participant) i32 {
    return p.centerX() + @as(i32, @intCast(tb.self_msg_loop_width + tb.self_msg_text_offset));
}

/// Null when an activation bar right of the loop leaves the text less than its floor or its
/// longest word: no width moves a bar this rung fixes.
fn selfRow(scratch: Allocator, msg: *const Message, diagram: *const SequenceDiagram, bars: Barred, spacing: fit.Spacing, max_width: u32, width: *u32) !?Row {
    const p = diagram.getParticipant(msg.from) orelse return .{ .height = tb.self_msg_row_height };
    const column = selfTextColumn(p);
    var room: u32 = @intCast(std.math.clamp(@as(i64, max_width) - spacing.padding - column, 0, unlimited));
    var bar_room: u32 = unlimited;
    for (diagram.participants.items, 0..) |*other, idx| {
        if (idx >= common.Activations.tracked or !bars.isSet(idx) or other.centerX() + 1 < column) continue;
        bar_room = @min(bar_room, @as(u32, @intCast(@max(other.centerX() - 1 - column, 0))));
    }
    room = @min(room, bar_room);
    var lines = try wrap.wrap(scratch, msg.text, unlimited);
    if (widest(lines) > room) {
        const floor = @min(try wrap.longestToken(msg.text), self_text_floor);
        if (bar_room < floor) return null;
        lines = try wrap.wrap(scratch, msg.text, @max(room, floor));
        if (widest(lines) > bar_room) return null;
    }
    if (lines.len > 0) width.* = @max(width.*, @as(u32, @intCast(column)) + widest(lines) + spacing.padding);
    return .{ .lines = lines, .left = column, .height = @max(tb.self_msg_row_height, @as(u32, @intCast(lines.len)) + 2) };
}

fn widest(lines: []const wrap.Line) u32 {
    var w: u32 = 0;
    for (lines) |line| w = @max(w, line.width);
    return w;
}

fn noteRect(note: *const model.SequenceNote, diagram: *const SequenceDiagram) !?types.Rect {
    var text_buf: [256]u8 = undefined;
    const box_width: i32 = @intCast(try unicode.rawDisplayWidth(draw_helpers.processLabel(note.text, &text_buf)) + 4);
    const x = tb.noteBoxX(note, diagram, box_width) orelse return null;
    return .{ .x = x, .y = 0, .width = @intCast(box_width), .height = tb.note_row_height };
}

fn drawNote(canvas: *Canvas, note: *const model.SequenceNote, diagram: *const SequenceDiagram, top: i32) !void {
    var rect = try noteRect(note, diagram) orelse return;
    rect.y = top;
    var text_buf: [256]u8 = undefined;
    canvas.drawBox(rect, types.unicode_rounded, .edge_label);
    canvas.drawTextSpanning(rect.x + 2, top + 1, draw_helpers.processLabel(note.text, &text_buf), .edge_label);
}

fn drawMessage(canvas: *Canvas, msg: *const Message, diagram: *const SequenceDiagram, row: Row, top: i32) void {
    const from = diagram.getParticipant(msg.from) orelse return;
    const to = diagram.getParticipant(msg.to) orelse return;
    tb.drawMessageLine(canvas, msg, from.centerX(), to.centerX(), top + @as(i32, @intCast(row.height)) - 1);
    for (row.lines, 0..) |line, i| {
        const indent = @divFloor(@as(i32, @intCast(row.room)) - @as(i32, @intCast(line.width)), 2);
        canvas.drawTextSpanning(row.left + indent, top + @as(i32, @intCast(i)), line.bytes, .edge_label);
    }
}

fn drawSelfMessage(canvas: *Canvas, msg: *const Message, diagram: *const SequenceDiagram, row: Row, top: i32) void {
    const p = diagram.getParticipant(msg.from) orelse return;
    tb.drawSelfMessage(canvas, p.centerX(), top + 1, "");
    for (row.lines, 0..) |line, i| {
        canvas.drawTextSpanning(row.left, top + 1 + @as(i32, @intCast(i)), line.bytes, .edge_label);
    }
}
