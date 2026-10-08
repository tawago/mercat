const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const parse = @import("parse.zig");
const model = @import("model.zig");
const state_layout_mod = @import("layout.zig");
const Canvas = @import("../shared/canvas.zig").Canvas;
const ladder = @import("../shared/ladder.zig");
const draw_helpers = @import("../shared/draw_helpers.zig");

const StateDiagram = model.StateDiagram;
const State = model.State;
const StateTransition = model.StateTransition;
const LineChars = types.LineChars;
const Arrows = types.Arrows;
const Rect = types.Rect;

const StateLayout = state_layout_mod.StateLayout;

const start_glyph: u21 = 0x25CF;
const end_glyph: u21 = 0x25CE;
const back_edge_arrow: u21 = 0x25B3;

pub fn render(allocator: Allocator, source: []const u8, max_width: u32) !ladder.Fit {
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();

    if (diagram.state_order.items.len == 0) {
        return .{ .drawn = "" };
    }

    return ladder.firstFit(&rungs, Painter{ .allocator = allocator, .diagram = &diagram }, max_width);
}

const Rung = struct {};
const rungs = [_]Rung{.{}};

const Painter = struct {
    allocator: Allocator,
    diagram: *StateDiagram,

    pub fn draw(self: Painter, _: Rung, max_width: u32) !ladder.Fit {
        var layout = StateLayout.init(self.allocator, self.diagram);
        defer layout.deinit();
        try layout.run();

        const bounds = layout.getBounds();
        const padding: u32 = 2;

        const back_edge_width = backEdgeWidth(self.diagram);
        const skip_edge_width = skipEdgeWidth(self.diagram);
        const canvas_width = bounds.width + padding * 2 + back_edge_width + skip_edge_width;
        const canvas_height = bounds.height + padding * 2;

        if (canvas_width > max_width) {
            return .{ .too_wide = canvas_width };
        }

        const left_offset = padding + skip_edge_width;
        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                state.x += @intCast(left_offset);
                state.y += @intCast(padding);
            }
        }

        var canvas = try Canvas.init(self.allocator, canvas_width, canvas_height);
        defer canvas.deinit();

        for (self.diagram.transitions.items, 0..) |*transition, idx| {
            drawStateTransition(&canvas, transition, self.diagram, idx);
        }

        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getState(id)) |state| {
                drawState(&canvas, state);
            }
        }

        return .{ .drawn = try canvas.toString(self.allocator) };
    }
};

fn isBackEdge(diagram: *const StateDiagram, transition: StateTransition) ?bool {
    const from_state = diagram.getState(transition.from) orelse return null;
    const to_state = diagram.getState(transition.to) orelse return null;
    return to_state.y < from_state.y;
}

/// Columns to the right of the drawing for the lane of the edges that climb back up, and
/// their labels; none when no edge climbs.
fn backEdgeWidth(diagram: *const StateDiagram) u32 {
    var has_back_edge = false;
    var max_label_len: usize = 0;
    for (diagram.transitions.items) |transition| {
        if (isBackEdge(diagram, transition) != true) continue;
        has_back_edge = true;
        if (transition.label) |label| {
            max_label_len = @max(max_label_len, label.len);
        }
    }
    return if (has_back_edge) 4 + @as(u32, @intCast(max_label_len)) else 0;
}

/// Columns to the left for the lane of the edges that skip a layer straight down past the
/// states between, and their labels; none when no edge does.
fn skipEdgeWidth(diagram: *const StateDiagram) u32 {
    var has_skip_edge = false;
    var max_label_len: usize = 0;
    for (diagram.transitions.items) |transition| {
        const from_state = diagram.getState(transition.from) orelse continue;
        const to_state = diagram.getState(transition.to) orelse continue;
        const from_layer = from_state.layer orelse continue;
        const to_layer = to_state.layer orelse continue;
        if (to_layer > from_layer + 1 and from_state.centerX() == to_state.centerX()) {
            has_skip_edge = true;
            if (transition.label) |label| {
                max_label_len = @max(max_label_len, label.len);
            }
        }
    }
    return if (has_skip_edge) 5 + @as(u32, @intCast(max_label_len)) else 0;
}

fn drawState(canvas: *Canvas, state: *const State) void {
    const x = state.x;
    const y = state.y;

    switch (state.state_type) {
        .start => canvas.setChar(x + 1, y, start_glyph, .node_text),
        .end => canvas.setChar(x + 1, y, end_glyph, .node_text),
        .choice => {
            const rect = Rect{
                .x = x,
                .y = y,
                .width = state.width,
                .height = state.height,
            };
            const label = state.label orelse state.id;
            draw_helpers.drawDiamondNode(canvas, rect, label);
        },
        .fork, .join => {
            canvas.drawHorizontalLine(y, x, x + @as(i32, @intCast(state.width)) - 1, LineChars.horizontal_thick, .node_border);
        },
        .regular => {
            const rect = Rect{
                .x = x,
                .y = y,
                .width = state.width,
                .height = state.height,
            };
            const label = state.label orelse state.id;
            canvas.drawBox(rect, types.unicode_rounded, .node_border);
            canvas.drawTextCentered(rect, label, .node_text);
        },
    }
}

/// Where a transition sits among those that join the same two states in the same drawn
/// direction, which offsets the labels of parallel edges.
const Slot = struct { count: u32, index: u32 };

fn parallelSlot(diagram: *const StateDiagram, transition_idx: usize) Slot {
    const transition = diagram.transitions.items[transition_idx];
    const is_back = isBackEdge(diagram, transition) orelse false;
    const state_a = if (is_back) transition.to else transition.from;
    const state_b = if (is_back) transition.from else transition.to;

    var slot: Slot = .{ .count = 0, .index = 0 };
    for (diagram.transitions.items, 0..) |t, idx| {
        const t_is_back = isBackEdge(diagram, t) orelse continue;
        const t_state_a = if (t_is_back) t.to else t.from;
        const t_state_b = if (t_is_back) t.from else t.to;

        if (std.mem.eql(u8, t_state_a, state_a) and std.mem.eql(u8, t_state_b, state_b)) {
            if (idx == transition_idx) {
                slot.index = slot.count;
            }
            slot.count += 1;
        }
    }
    return slot;
}

/// Label text goes down one cell per byte, as it is.
fn drawLabel(canvas: *Canvas, x: i32, y: i32, label: []const u8) void {
    for (label, 0..) |byte, i| {
        canvas.setChar(x + @as(i32, @intCast(i)), y, byte, .edge_label);
    }
}

fn drawStateTransition(canvas: *Canvas, transition: *const StateTransition, diagram: *const StateDiagram, transition_idx: usize) void {
    const from_state = diagram.getState(transition.from) orelse return;
    const to_state = diagram.getState(transition.to) orelse return;

    const slot = parallelSlot(diagram, transition_idx);

    if (to_state.y < from_state.y) {
        drawBackEdge(canvas, transition, from_state, to_state, slot);
    } else if (from_state.centerX() == to_state.centerX()) {
        const from_layer = from_state.layer orelse 0;
        const to_layer = to_state.layer orelse 0;
        if (to_layer > from_layer + 1) {
            drawSkipEdge(canvas, transition, diagram, from_state, to_state);
        } else {
            drawStraightEdge(canvas, transition, from_state, to_state, slot);
        }
    } else {
        drawElbowEdge(canvas, transition, from_state, to_state);
    }
}

/// An edge up to an earlier layer: a dashless line beside the two boxes, rising to an arrow
/// under the target.
fn drawBackEdge(canvas: *Canvas, transition: *const StateTransition, from_state: *const State, to_state: *const State, slot: Slot) void {
    const wider_width = @max(from_state.width, to_state.width);
    const center_x = @max(from_state.centerX(), to_state.centerX());
    const edge_x = center_x + @as(i32, @intCast(wider_width / 4));

    const from_top = from_state.y;
    const arrow_y = to_state.bottom();

    const line_middle = @divTrunc(to_state.bottom() + from_top, 2);
    const label_offset = @as(i32, @intCast(slot.index)) - @as(i32, @intCast(slot.count / 2));
    const label_y = line_middle + label_offset;

    var y = to_state.bottom();
    while (y < from_top) : (y += 1) {
        if (y == arrow_y) {
            canvas.setChar(edge_x, y, back_edge_arrow, .edge);
        } else {
            canvas.setChar(edge_x, y, LineChars.vertical, .edge);
        }
    }

    if (transition.label) |label| {
        drawLabel(canvas, edge_x + 1, label_y, label);
    }
}

/// An edge down past intermediate layers, routed around the left of every state.
fn drawSkipEdge(canvas: *Canvas, transition: *const StateTransition, diagram: *const StateDiagram, from_state: *const State, to_state: *const State) void {
    var min_x: i32 = from_state.x;
    for (diagram.state_order.items) |id| {
        if (diagram.getState(id)) |state| {
            min_x = @min(min_x, state.x);
        }
    }

    const route_x = min_x - 3;

    const exit_y = from_state.midY();
    const enter_y = to_state.midY();

    var hx = route_x;
    while (hx < from_state.x) : (hx += 1) {
        if (hx == route_x) {
            canvas.setChar(hx, exit_y, LineChars.corner_se, .edge);
        } else {
            canvas.setChar(hx, exit_y, LineChars.horizontal, .edge);
        }
    }

    var vy = exit_y + 1;
    while (vy < enter_y) : (vy += 1) {
        canvas.setChar(route_x, vy, LineChars.vertical, .edge);
    }

    canvas.setChar(route_x, enter_y, LineChars.corner_ne, .edge);

    hx = route_x + 1;
    while (hx < to_state.x) : (hx += 1) {
        if (hx == to_state.x - 1) {
            canvas.setChar(hx, enter_y, Arrows.right, .edge);
        } else {
            canvas.setChar(hx, enter_y, LineChars.horizontal, .edge);
        }
    }

    if (transition.label) |label| {
        drawLabel(canvas, route_x + 1, @divTrunc(exit_y + enter_y, 2), label);
    }
}

/// An edge straight down to the next layer, its label to the left.
fn drawStraightEdge(canvas: *Canvas, transition: *const StateTransition, from_state: *const State, to_state: *const State, slot: Slot) void {
    const center_x = from_state.centerX();
    const from_bottom = from_state.bottom();
    const arrow_y = to_state.y - 1;

    const line_middle = @divTrunc(from_bottom + to_state.y, 2);
    const label_offset = @as(i32, @intCast(slot.index)) - @as(i32, @intCast(slot.count / 2));
    const label_y = line_middle + label_offset;

    var y = from_bottom;
    while (y < to_state.y) : (y += 1) {
        if (y == arrow_y) {
            canvas.setChar(center_x, y, Arrows.down, .edge);
        } else {
            canvas.setChar(center_x, y, LineChars.vertical, .edge);
        }
    }

    if (transition.label) |label| {
        const label_x = @max(center_x - @as(i32, @intCast(label.len)) - 1, 0);
        drawLabel(canvas, label_x, label_y, label);
    }
}

/// An edge down and across: out of the source, along the row under it, then down into the target.
fn drawElbowEdge(canvas: *Canvas, transition: *const StateTransition, from_state: *const State, to_state: *const State) void {
    const from_center_x = from_state.centerX();
    const to_center_x = to_state.centerX();
    const from_bottom = from_state.bottom();
    const mid_y = from_bottom + 1;
    const going_right = to_center_x > from_center_x;

    canvas.setChar(from_center_x, from_bottom, LineChars.vertical, .edge);

    const min_x = @min(from_center_x, to_center_x);
    const max_x = @max(from_center_x, to_center_x);
    var hx = min_x;
    while (hx <= max_x) : (hx += 1) {
        if (hx == from_center_x) {
            canvas.setChar(hx, mid_y, if (going_right) LineChars.corner_ne else LineChars.corner_nw, .edge);
        } else if (hx == to_center_x) {
            canvas.setChar(hx, mid_y, if (going_right) LineChars.corner_sw else LineChars.corner_se, .edge);
        } else {
            canvas.setChar(hx, mid_y, LineChars.horizontal, .edge);
        }
    }

    var y = mid_y + 1;
    while (y < to_state.y) : (y += 1) {
        if (y == to_state.y - 1) {
            canvas.setChar(to_center_x, y, Arrows.down, .edge);
        } else {
            canvas.setChar(to_center_x, y, LineChars.vertical, .edge);
        }
    }

    if (transition.label) |label| {
        const label_x = @divTrunc(from_center_x + to_center_x, 2) - @as(i32, @intCast(label.len / 2));
        drawLabel(canvas, label_x, mid_y, label);
    }
}
