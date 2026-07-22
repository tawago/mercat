/// State diagram renderer.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const parser = @import("../parser.zig");
const canvas_mod = @import("../shared/canvas.zig");
const state_layout_mod = @import("layout.zig");
const draw_helpers = @import("../shared/draw_helpers.zig");

const RenderOptions = types.RenderOptions;
const RenderResult = types.RenderResult;
const StateDiagram = types.StateDiagram;
const State = types.State;
const StateType = types.StateType;
const StateTransition = types.StateTransition;
const LineChars = types.LineChars;
const Arrows = types.Arrows;
const Rect = types.Rect;

const Canvas = canvas_mod.Canvas;
const Parser = parser.Parser;
const StateLayout = state_layout_mod.StateLayout;

pub fn renderStateDiagram(allocator: Allocator, source: []const u8, options: RenderOptions) !RenderResult {
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

    var layout = StateLayout.init(allocator, &diagram, options);
    defer layout.deinit();
    try layout.run();

    const bounds = layout.getBounds();
    const padding: u32 = 2;

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

    var has_skip_edge = false;
    var max_skip_edge_label_len: usize = 0;
    for (diagram.transitions.items) |transition| {
        const from_state = diagram.getState(transition.from) orelse continue;
        const to_state = diagram.getState(transition.to) orelse continue;
        const from_layer = from_state.layer orelse continue;
        const to_layer = to_state.layer orelse continue;
        const from_x = from_state.x orelse continue;
        const to_x = to_state.x orelse continue;
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

    const back_edge_width: u32 = if (has_back_edge) 4 + @as(u32, @intCast(max_back_edge_label_len)) else 0;
    const skip_edge_width: u32 = if (has_skip_edge) 5 + @as(u32, @intCast(max_skip_edge_label_len)) else 0;
    const canvas_width = bounds.width + padding * 2 + back_edge_width + skip_edge_width;
    const canvas_height = bounds.height + padding * 2;

    if (canvas_width > options.max_width) {
        return .{
            .output = source,
            .width = canvas_width,
            .height = canvas_height,
            .is_fallback = true,
            .fallback_reason = "Diagram too wide for terminal",
        };
    }

    const left_offset = padding + skip_edge_width;
    for (diagram.state_order.items) |id| {
        if (diagram.getStateMut(id)) |state| {
            if (state.x) |*x| x.* += @intCast(left_offset);
            if (state.y) |*y| y.* += @intCast(padding);
        }
    }

    var canvas = try Canvas.init(allocator, canvas_width, canvas_height);
    defer canvas.deinit();

    for (diagram.transitions.items, 0..) |*transition, idx| {
        drawStateTransition(&canvas, transition, &diagram, options, idx);
    }

    for (diagram.state_order.items) |id| {
        if (diagram.getState(id)) |state| {
            drawState(&canvas, state, options);
        }
    }

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
            if (options.unicode_mode) {
                canvas.setChar(x + 1, y, 0x25CF, .node_text); // ●
            } else {
                canvas.setChar(x, y, '(', .node_border);
                canvas.setChar(x + 1, y, '*', .node_text);
                canvas.setChar(x + 2, y, ')', .node_border);
            }
        },
        .end => {
            if (options.unicode_mode) {
                canvas.setChar(x + 1, y, 0x25CE, .node_text); // ◎
            } else {
                canvas.setChar(x, y, '(', .node_border);
                canvas.setChar(x + 1, y, 'o', .node_text);
                canvas.setChar(x + 2, y, ')', .node_border);
            }
        },
        .choice => {
            const rect = Rect{
                .x = x,
                .y = y,
                .width = state.width,
                .height = state.height,
            };
            const label = state.label orelse state.id;
            draw_helpers.drawDiamondNode(canvas, rect, label, options);
        },
        .fork, .join => {
            const h_char: u21 = if (options.unicode_mode) LineChars.horizontal_thick else '=';
            var i: i32 = 0;
            while (i < @as(i32, @intCast(state.width))) : (i += 1) {
                canvas.setChar(x + i, y, h_char, .node_border);
            }
        },
        .regular, .composite => {
            const rect = Rect{
                .x = x,
                .y = y,
                .width = state.width,
                .height = state.height,
            };
            const label = state.label orelse state.id;
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

    const from_center_x = from_x + @as(i32, @intCast(from_state.width / 2));
    const from_bottom = from_y + @as(i32, @intCast(from_state.height));
    const to_center_x = to_x + @as(i32, @intCast(to_state.width / 2));
    const to_bottom = to_y + @as(i32, @intCast(to_state.height));

    const is_back_edge = to_y < from_y;

    var transition_count: u32 = 0;
    var my_index: u32 = 0;
    const state_a = if (is_back_edge) transition.to else transition.from;
    const state_b = if (is_back_edge) transition.from else transition.to;
    for (diagram.transitions.items, 0..) |t, idx| {
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
        const wider_width = @max(from_state.width, to_state.width);
        const center_x = @max(from_center_x, to_center_x);
        const edge_x = center_x + @as(i32, @intCast(wider_width / 4));

        const from_top = from_y;
        const arrow_y = to_bottom;

        const line_middle = @divTrunc(to_bottom + from_top, 2);
        const label_offset = @as(i32, @intCast(my_index)) - @as(i32, @intCast(transition_count / 2));
        const label_y = line_middle + label_offset;

        var y = to_bottom;
        while (y < from_top) : (y += 1) {
            if (y == arrow_y) {
                const arrow_up: u21 = if (options.unicode_mode) 0x25B3 else '^'; // △
                canvas.setChar(edge_x, y, arrow_up, .edge);
            } else {
                canvas.setChar(edge_x, y, v_char, .edge);
            }
        }

        if (transition.label) |label| {
            var i: usize = 0;
            while (i < label.len) : (i += 1) {
                canvas.setChar(edge_x + 1 + @as(i32, @intCast(i)), label_y, label[i], .edge_label);
            }
        }
    } else if (from_center_x == to_center_x) {
        const from_layer = from_state.layer orelse 0;
        const to_layer = to_state.layer orelse 0;
        const is_skip_edge = to_layer > from_layer + 1;

        if (is_skip_edge) {
            var min_x: i32 = from_x;
            for (diagram.state_order.items) |id| {
                if (diagram.getState(id)) |state| {
                    if (state.x) |sx| {
                        if (sx < min_x) min_x = sx;
                    }
                }
            }

            const route_x = min_x - 3;
            const corner_se: u21 = if (options.unicode_mode) LineChars.corner_se else '+'; // ┌
            const corner_ne: u21 = if (options.unicode_mode) LineChars.corner_ne else '+'; // └

            const exit_y = from_y + @as(i32, @intCast(from_state.height / 2));
            const enter_y = to_y + @as(i32, @intCast(to_state.height / 2));

            var hx = route_x;
            while (hx < from_x) : (hx += 1) {
                if (hx == route_x) {
                    canvas.setChar(hx, exit_y, corner_se, .edge);
                } else {
                    canvas.setChar(hx, exit_y, h_char, .edge);
                }
            }

            var vy = exit_y + 1;
            while (vy < enter_y) : (vy += 1) {
                canvas.setChar(route_x, vy, v_char, .edge);
            }

            canvas.setChar(route_x, enter_y, corner_ne, .edge);

            hx = route_x + 1;
            const target_entry_x = to_x;
            while (hx < target_entry_x) : (hx += 1) {
                if (hx == target_entry_x - 1) {
                    const arrow_right: u21 = if (options.unicode_mode) Arrows.right else '>';
                    canvas.setChar(hx, enter_y, arrow_right, .edge);
                } else {
                    canvas.setChar(hx, enter_y, h_char, .edge);
                }
            }

            if (transition.label) |label| {
                const label_y = @divTrunc(exit_y + enter_y, 2);
                var i: usize = 0;
                while (i < label.len) : (i += 1) {
                    canvas.setChar(route_x + 1 + @as(i32, @intCast(i)), label_y, label[i], .edge_label);
                }
            }
        } else {
            const arrow_y = to_y - 1;

            const line_middle = @divTrunc(from_bottom + to_y, 2);
            const label_offset = @as(i32, @intCast(my_index)) - @as(i32, @intCast(transition_count / 2));
            const label_y = line_middle + label_offset;

            var y = from_bottom;
            while (y < to_y) : (y += 1) {
                if (y == arrow_y) {
                    canvas.setChar(from_center_x, y, arrow_down, .edge);
                } else {
                    canvas.setChar(from_center_x, y, v_char, .edge);
                }
            }

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
        const mid_y = from_bottom + 1;

        canvas.setChar(from_center_x, from_bottom, v_char, .edge);

        const min_x = @min(from_center_x, to_center_x);
        const max_x = @max(from_center_x, to_center_x);
        var hx = min_x;
        while (hx <= max_x) : (hx += 1) {
            if (hx == from_center_x) {
                const corner: u21 = if (to_center_x > from_center_x)
                    (if (options.unicode_mode) 0x2514 else '+') // └
                else
                    (if (options.unicode_mode) 0x2518 else '+'); // ┘
                canvas.setChar(hx, mid_y, corner, .edge);
            } else if (hx == to_center_x) {
                const corner: u21 = if (to_center_x > from_center_x)
                    (if (options.unicode_mode) 0x2510 else '+') // ┐
                else
                    (if (options.unicode_mode) 0x250C else '+'); // ┌
                canvas.setChar(hx, mid_y, corner, .edge);
            } else {
                canvas.setChar(hx, mid_y, h_char, .edge);
            }
        }

        var y = mid_y + 1;
        while (y < to_y) : (y += 1) {
            if (y == to_y - 1) {
                canvas.setChar(to_center_x, y, arrow_down, .edge);
            } else {
                canvas.setChar(to_center_x, y, v_char, .edge);
            }
        }

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
