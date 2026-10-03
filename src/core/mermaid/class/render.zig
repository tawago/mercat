const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const parse = @import("parse.zig");
const model = @import("model.zig");
const Canvas = @import("../shared/canvas.zig").Canvas;

const ClassDiagram = model.ClassDiagram;
const Class = model.Class;
const ClassMember = model.ClassMember;
const ClassRelation = model.ClassRelation;
const LineChars = types.LineChars;

const class_padding: u32 = 2;
const min_class_width: u32 = 16;
const horizontal_spacing: u32 = 6;
const vertical_spacing: u32 = 2;
const header_height: u32 = 3;
const separator_height: u32 = 1;
const classes_per_row: u32 = 3;

const Size = struct { width: u32, height: u32 };

pub fn render(allocator: Allocator, source: []const u8, max_width: u32) !?[]const u8 {
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();

    if (diagram.class_order.items.len == 0) {
        return "";
    }

    const size = place(&diagram);
    if (size.width > max_width) {
        return null;
    }

    var canvas = try Canvas.init(allocator, size.width, size.height);
    defer canvas.deinit();

    for (diagram.class_order.items) |class_name| {
        if (diagram.getClass(class_name)) |class| {
            drawClassBox(&canvas, class);
        }
    }

    for (diagram.relations.items) |*rel| {
        drawClassRelation(&canvas, rel, &diagram);
    }

    return try canvas.toString(allocator);
}

/// Size every class box and lay the boxes out three to a row. The canvas width is the widest
/// full row; a last row of fewer than three counts only when no row is full.
fn place(diagram: *ClassDiagram) Size {
    for (diagram.class_order.items) |class_name| {
        if (diagram.getClassMut(class_name)) |class| {
            fit(class);
        }
    }

    var widest_row: u32 = 0;
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
                if (x_end > widest_row) widest_row = x_end;
                current_x = 1;
                current_y += @intCast(row_height + vertical_spacing);
                row_height = 0;
                col = 0;
            }
        }
    }

    const width: u32 = if (widest_row > 0) widest_row else @intCast(current_x);
    const height: u32 = @intCast(current_y + @as(i32, @intCast(row_height)) + 2);
    return .{ .width = width, .height = height };
}

/// A box wide enough for its widest line and tall enough for the header and one row for each
/// attribute and method, with a single empty row standing in for an empty section.
fn fit(class: *Class) void {
    var width: u32 = @intCast(class.name.len + class_padding * 2);
    var attr_count: u32 = 0;
    var method_count: u32 = 0;
    for (class.members.items) |m| {
        const member_len: u32 = @intCast(m.name.len + 2);
        width = @max(width, member_len + class_padding * 2);
        if (m.is_method) {
            method_count += 1;
        } else {
            attr_count += 1;
        }
    }
    class.width = @max(width, min_class_width);

    const attr_section = @max(attr_count, 1);
    const method_section = @max(method_count, 1);
    class.height = header_height + separator_height + attr_section + separator_height + method_section + 1;
}

fn drawClassBox(canvas: *Canvas, class: *const Class) void {
    const x = class.x;
    const y = class.y;
    const w: i32 = @intCast(class.width);
    const h: i32 = @intCast(class.height);

    canvas.drawBox(.{
        .x = x,
        .y = y,
        .width = class.width,
        .height = class.height,
    }, types.unicode_square, .node_border);

    const name_len: i32 = @intCast(class.name.len);
    const name_x = x + @divFloor(w - name_len, 2);
    canvas.drawText(name_x, y + 1, class.name, .node_text);

    const sep_y = y + 2;
    drawSeparator(canvas, x, sep_y, w);

    var row = sep_y + 1;
    for (class.members.items) |m| {
        if (!m.is_method) {
            drawMember(canvas, x, row, m);
            row += 1;
        }
    }

    if (row < y + h - 2) {
        drawSeparator(canvas, x, row, w);
        row += 1;
    }

    for (class.members.items) |m| {
        if (m.is_method and row < y + h - 1) {
            drawMember(canvas, x, row, m);
            row += 1;
        }
    }
}

fn drawSeparator(canvas: *Canvas, x: i32, y: i32, w: i32) void {
    canvas.setChar(x, y, LineChars.tee_right, .node_border);
    var col = x + 1;
    while (col < x + w - 1) : (col += 1) {
        canvas.setChar(col, y, LineChars.horizontal, .node_border);
    }
    canvas.setChar(x + w - 1, y, LineChars.tee_left, .node_border);
}

/// A member line: its visibility mark, when it has one, then its name cut to 63 bytes.
fn drawMember(canvas: *Canvas, x: i32, row: i32, m: ClassMember) void {
    var buf: [64]u8 = undefined;
    var member_str: []const u8 = m.name;
    if (m.visibility.toChar()) |mark| {
        buf[0] = mark;
        const copy_len = @min(m.name.len, buf.len - 1);
        @memcpy(buf[1 .. 1 + copy_len], m.name[0..copy_len]);
        member_str = buf[0 .. 1 + copy_len];
    }
    canvas.drawText(x + 1, row, member_str, .node_text);
}

fn drawClassRelation(canvas: *Canvas, rel: *const ClassRelation, diagram: *const ClassDiagram) void {
    const from_class = diagram.getClass(rel.from) orelse return;
    const to_class = diagram.getClass(rel.to) orelse return;

    var start_x: i32 = from_class.centerX();
    var start_y: i32 = from_class.y + @as(i32, @intCast(from_class.height));
    var end_x: i32 = to_class.centerX();
    var end_y: i32 = to_class.y;

    if (@abs(from_class.centerY() - to_class.centerY()) < @as(i32, @intCast(from_class.height))) {
        start_y = from_class.centerY();
        end_y = to_class.centerY();
        if (to_class.x > from_class.x) {
            start_x = from_class.x + @as(i32, @intCast(from_class.width));
            end_x = to_class.x;
        } else {
            start_x = from_class.x;
            end_x = to_class.x + @as(i32, @intCast(to_class.width));
        }
    }

    const dotted = rel.relation_type == .dependency or rel.relation_type == .realization;
    const line_char: u21 = if (dotted) LineChars.horizontal_dotted else LineChars.horizontal;

    if (start_y == end_y) {
        const left = @min(start_x, end_x);
        const right = @max(start_x, end_x);
        canvas.drawHorizontalLine(start_y, left + 1, right - 1, line_char, .edge);
    } else {
        const mid_y = @divFloor(start_y + end_y, 2);
        const v_char: u21 = if (dotted) LineChars.vertical_dotted else LineChars.vertical;

        canvas.drawVerticalLine(start_x, start_y, mid_y, v_char, .edge);
        const left = @min(start_x, end_x);
        const right = @max(start_x, end_x);
        canvas.drawHorizontalLine(mid_y, left, right, line_char, .edge);
        canvas.drawVerticalLine(end_x, mid_y, end_y, v_char, .edge);
    }

    const marker = rel.relation_type.endMarker();
    if (marker.len > 0) {
        canvas.drawText(end_x, end_y - 1, marker, .edge);
    }
}
