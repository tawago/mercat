const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const parse = @import("parse.zig");
const model = @import("model.zig");
const Canvas = @import("../shared/canvas.zig").Canvas;

const ERDiagram = model.ERDiagram;
const Entity = model.Entity;
const ERRelation = model.ERRelation;
const LineChars = types.LineChars;

const entity_padding: u32 = 2;
const min_entity_width: u32 = 12;
const entity_height: u32 = 3;
const horizontal_spacing: u32 = 8;
const vertical_spacing: u32 = 3;

const Size = struct { width: u32, height: u32 };

pub fn render(allocator: Allocator, source: []const u8, max_width: u32) !?[]const u8 {
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();

    if (diagram.entity_order.items.len == 0) {
        return "";
    }

    const size = place(&diagram);
    if (size.width > max_width) {
        return null;
    }

    var canvas = try Canvas.init(allocator, size.width, size.height);
    defer canvas.deinit();

    for (diagram.entity_order.items) |entity_name| {
        if (diagram.getEntity(entity_name)) |entity| {
            drawEntityBox(&canvas, entity);
        }
    }

    for (diagram.relations.items) |*rel| {
        drawERRelation(&canvas, rel, &diagram);
    }

    return try canvas.toString(allocator);
}

/// Size the entity boxes and set them in one row, in declaration order; the canvas is tall
/// enough for two rows of crossing line per relation.
fn place(diagram: *ERDiagram) Size {
    var current_x: i32 = 1;

    for (diagram.entity_order.items) |entity_name| {
        if (diagram.getEntityMut(entity_name)) |entity| {
            entity.width = @max(@as(u32, @intCast(entity_name.len)) + entity_padding * 2, min_entity_width);
            entity.height = entity_height;
            entity.x = current_x;
            entity.y = 1;
            current_x += @intCast(entity.width + horizontal_spacing);
        }
    }

    const width: u32 = @intCast(@max(current_x, 1));
    const height: u32 = entity_height + vertical_spacing + 2 + @as(u32, @intCast(diagram.relations.items.len * 2));
    return .{ .width = width, .height = height };
}

fn drawEntityBox(canvas: *Canvas, entity: *const Entity) void {
    const w: i32 = @intCast(entity.width);

    canvas.drawBox(.{
        .x = entity.x,
        .y = entity.y,
        .width = entity.width,
        .height = entity.height,
    }, types.unicode_square, .node_border);

    const name_len: i32 = @intCast(entity.name.len);
    const name_x = entity.x + @divFloor(w - name_len, 2);
    canvas.drawText(name_x, entity.y + 1, entity.name, .node_text);
}

fn drawERRelation(canvas: *Canvas, rel: *const ERRelation, diagram: *const ERDiagram) void {
    const from_entity = diagram.getEntity(rel.from) orelse return;
    const to_entity = diagram.getEntity(rel.to) orelse return;

    const start_x = from_entity.x + @as(i32, @intCast(from_entity.width));
    const start_y = from_entity.y + @as(i32, @intCast(from_entity.height / 2));
    const end_x = to_entity.x;
    const end_y = to_entity.y + @as(i32, @intCast(to_entity.height / 2));

    const line_char: u21 = LineChars.horizontal;

    if (start_y == end_y) {
        canvas.drawHorizontalLine(start_y, start_x, end_x, line_char, .edge);
    } else {
        const mid_x = @divFloor(start_x + end_x, 2);

        canvas.drawHorizontalLine(start_y, start_x, mid_x, line_char, .edge);
        canvas.drawVerticalLine(mid_x, @min(start_y, end_y), @max(start_y, end_y), LineChars.vertical, .edge);
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
