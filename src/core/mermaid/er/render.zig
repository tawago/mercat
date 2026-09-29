const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const parse = @import("parse.zig");
const model = @import("model.zig");
const canvas_mod = @import("../shared/canvas.zig");

const RenderResult = types.RenderResult;
const ERDiagram = model.ERDiagram;
const Entity = model.Entity;
const ERRelation = model.ERRelation;
const LineChars = types.LineChars;

const Canvas = canvas_mod.Canvas;

pub fn renderERDiagram(allocator: Allocator, source: []const u8, max_width: u32) !RenderResult {
    var diagram = try parse.parse(allocator, source);
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

    const entity_padding: u32 = 2;
    const min_entity_width: u32 = 12;
    const entity_height: u32 = 3;
    const horizontal_spacing: u32 = 8;
    const vertical_spacing: u32 = 3;

    for (diagram.entity_order.items) |entity_name| {
        if (diagram.getEntityMut(entity_name)) |entity| {
            var width: u32 = @intCast(entity_name.len + entity_padding * 2);
            if (width < min_entity_width) width = min_entity_width;
            entity.width = width;
            entity.height = entity_height;
        }
    }

    var current_x: i32 = 1;
    const y: i32 = 1;

    for (diagram.entity_order.items) |entity_name| {
        if (diagram.getEntityMut(entity_name)) |entity| {
            entity.x = current_x;
            entity.y = y;
            current_x += @intCast(entity.width + horizontal_spacing);
        }
    }

    const total_width: u32 = @intCast(@max(current_x, 1));
    var total_height: u32 = entity_height + vertical_spacing + 2;
    total_height += @intCast(diagram.relations.items.len * 2);

    if (total_width > max_width) {
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

    for (diagram.entity_order.items) |entity_name| {
        if (diagram.getEntity(entity_name)) |entity| {
            drawEntityBox(&canvas, entity);
        }
    }

    for (diagram.relations.items) |*rel| {
        drawERRelation(&canvas, rel, &diagram);
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

fn drawEntityBox(canvas: *Canvas, entity: *const Entity) void {
    const x = entity.x orelse return;
    const y = entity.y orelse return;
    const w: i32 = @intCast(entity.width);

    const box_style = types.unicode_square;

    canvas.drawBox(.{
        .x = x,
        .y = y,
        .width = entity.width,
        .height = entity.height,
    }, box_style, .node_border);

    const name_len: i32 = @intCast(entity.name.len);
    const name_x = x + @divFloor(w - name_len, 2);
    canvas.drawText(name_x, y + 1, entity.name, .node_text);
}

fn drawERRelation(canvas: *Canvas, rel: *const ERRelation, diagram: *const ERDiagram) void {
    const from_entity = diagram.getEntity(rel.from) orelse return;
    const to_entity = diagram.getEntity(rel.to) orelse return;

    const from_x = from_entity.x orelse return;
    const from_y = from_entity.y orelse return;
    const to_x = to_entity.x orelse return;
    const to_y = to_entity.y orelse return;

    const start_x = from_x + @as(i32, @intCast(from_entity.width));
    const start_y = from_y + @as(i32, @intCast(from_entity.height / 2));
    const end_x = to_x;
    const end_y = to_y + @as(i32, @intCast(to_entity.height / 2));

    const line_char: u21 = LineChars.horizontal;

    if (start_y == end_y) {
        canvas.drawHorizontalLine(start_y, start_x, end_x, line_char, .edge);
    } else {
        const mid_x = @divFloor(start_x + end_x, 2);
        const v_char: u21 = LineChars.vertical;

        canvas.drawHorizontalLine(start_y, start_x, mid_x, line_char, .edge);
        canvas.drawVerticalLine(mid_x, @min(start_y, end_y), @max(start_y, end_y), v_char, .edge);
        canvas.drawHorizontalLine(end_y, mid_x, end_x, line_char, .edge);
    }

    const left_card = rel.from_cardinality.toStringLeft();
    canvas.drawText(start_x + 1, start_y, left_card, .edge_label);

    const right_card = rel.to_cardinality.toStringRight();
    canvas.drawText(end_x - @as(i32, @intCast(right_card.len)) - 1, end_y, right_card, .edge_label);

    if (rel.label) |label| {
        const mid_x = @divFloor(start_x + end_x, 2);
        const label_len: i32 = @intCast(label.len);
        canvas.drawText(mid_x - @divFloor(label_len, 2), start_y + 1, label, .edge_label);
    }
}
