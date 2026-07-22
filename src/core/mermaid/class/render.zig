/// Class diagram renderer.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const parser = @import("../parser.zig");
const canvas_mod = @import("../shared/canvas.zig");

const RenderOptions = types.RenderOptions;
const RenderResult = types.RenderResult;
const ClassDiagram = types.ClassDiagram;
const Class = types.Class;
const ClassRelation = types.ClassRelation;
const LineChars = types.LineChars;

const Canvas = canvas_mod.Canvas;
const Parser = parser.Parser;

pub fn renderClassDiagram(allocator: Allocator, source: []const u8, options: RenderOptions) !RenderResult {
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

    var max_width: u32 = 0;
    var class_heights: std.ArrayList(u32) = .empty;
    defer class_heights.deinit(allocator);
    var class_widths: std.ArrayList(u32) = .empty;
    defer class_widths.deinit(allocator);

    for (diagram.class_order.items) |class_name| {
        if (diagram.getClassMut(class_name)) |class| {
            var width: u32 = @intCast(class_name.len + class_padding * 2);
            for (class.members.items) |m| {
                const member_len: u32 = @intCast(m.name.len + 2);
                if (member_len + class_padding * 2 > width) {
                    width = member_len + class_padding * 2;
                }
            }
            if (width < min_class_width) width = min_class_width;
            class.width = width;
            try class_widths.append(allocator, width);

            var attr_count: u32 = 0;
            var method_count: u32 = 0;
            for (class.members.items) |m| {
                if (m.is_method) {
                    method_count += 1;
                } else {
                    attr_count += 1;
                }
            }
            const attr_section = if (attr_count > 0) attr_count else 1;
            const method_section = if (method_count > 0) method_count else 1;
            const height = header_height + separator_height + attr_section + separator_height + method_section + 1;
            class.height = height;
            try class_heights.append(allocator, height);
        }
    }

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

    const total_width: u32 = if (max_width > 0) max_width else @intCast(current_x);
    const total_height: u32 = @intCast(current_y + @as(i32, @intCast(row_height)) + 2);

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

    for (diagram.class_order.items) |class_name| {
        if (diagram.getClass(class_name)) |class| {
            drawClassBox(&canvas, class, options);
        }
    }

    for (diagram.relations.items) |*rel| {
        drawClassRelation(&canvas, rel, &diagram, options);
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

fn drawClassBox(canvas: *Canvas, class: *const Class, options: RenderOptions) void {
    const x = class.x orelse return;
    const y = class.y orelse return;
    const w: i32 = @intCast(class.width);
    const h: i32 = @intCast(class.height);

    const box_style = if (options.unicode_mode) types.unicode_square else types.ascii_box;

    canvas.drawBox(.{
        .x = x,
        .y = y,
        .width = class.width,
        .height = class.height,
    }, box_style, .node_border);

    const name_len: i32 = @intCast(class.name.len);
    const name_x = x + @divFloor(w - name_len, 2);
    canvas.drawText(name_x, y + 1, class.name, .node_text);

    const sep_y = y + 2;
    canvas.setChar(x, sep_y, LineChars.tee_right, .node_border);
    var col = x + 1;
    while (col < x + w - 1) : (col += 1) {
        canvas.setChar(col, sep_y, LineChars.horizontal, .node_border);
    }
    canvas.setChar(x + w - 1, sep_y, LineChars.tee_left, .node_border);

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

    if (row < y + h - 2) {
        canvas.setChar(x, row, LineChars.tee_right, .node_border);
        col = x + 1;
        while (col < x + w - 1) : (col += 1) {
            canvas.setChar(col, row, LineChars.horizontal, .node_border);
        }
        canvas.setChar(x + w - 1, row, LineChars.tee_left, .node_border);
        row += 1;
    }

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

    const from_cx = from_x + @as(i32, @intCast(from_class.width / 2));
    const from_cy = from_y + @as(i32, @intCast(from_class.height / 2));
    const to_cx = to_x + @as(i32, @intCast(to_class.width / 2));
    const to_cy = to_y + @as(i32, @intCast(to_class.height / 2));

    var start_x: i32 = from_cx;
    var start_y: i32 = from_y + @as(i32, @intCast(from_class.height));
    var end_x: i32 = to_cx;
    var end_y: i32 = to_y;

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

    const line_char: u21 = if (rel.relation_type == .dependency or rel.relation_type == .realization)
        LineChars.horizontal_dotted
    else
        LineChars.horizontal;

    if (start_y == end_y) {
        const left = @min(start_x, end_x);
        const right = @max(start_x, end_x);
        canvas.drawHorizontalLine(start_y, left + 1, right - 1, line_char, .edge);
    } else {
        const mid_y = @divFloor(start_y + end_y, 2);
        const v_char: u21 = if (rel.relation_type == .dependency or rel.relation_type == .realization)
            LineChars.vertical_dotted
        else
            LineChars.vertical;

        canvas.drawVerticalLine(start_x, start_y, mid_y, v_char, .edge);
        const left = @min(start_x, end_x);
        const right = @max(start_x, end_x);
        canvas.drawHorizontalLine(mid_y, left, right, line_char, .edge);
        canvas.drawVerticalLine(end_x, mid_y, end_y, v_char, .edge);
    }

    const arrow_info = rel.relation_type.getArrowChars(options.unicode_mode);
    if (arrow_info.end.len > 0) {
        canvas.drawText(end_x, end_y - 1, arrow_info.end, .edge);
    }
}
