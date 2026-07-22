const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");

const RenderOptions = types.RenderOptions;
const LayoutAlgorithm = types.LayoutAlgorithm;
const StateDiagram = types.StateDiagram;

/// Layout algorithm for state diagrams
/// Key principle: Start states at top, end states at bottom, unless inside composite
pub const StateLayout = struct {
    allocator: Allocator,
    diagram: *StateDiagram,
    options: RenderOptions,

    layers: std.ArrayList(std.ArrayList([]const u8)),
    algorithm_used: LayoutAlgorithm = .layered_bfs,

    pub fn init(allocator: Allocator, diagram: *StateDiagram, options: RenderOptions) StateLayout {
        return .{
            .allocator = allocator,
            .diagram = diagram,
            .options = options,
            .layers = .empty,
        };
    }

    pub fn deinit(self: *StateLayout) void {
        for (self.layers.items) |*layer| {
            layer.deinit(self.allocator);
        }
        self.layers.deinit(self.allocator);
    }

    pub fn run(self: *StateLayout) !void {
        try self.assignLayers();
        try self.assignOrder();
        try self.assignCoordinates();
    }

    fn assignLayers(self: *StateLayout) !void {
        var assigned = std.StringHashMap(void).init(self.allocator);
        defer assigned.deinit();

        var max_layer: u32 = 0;

        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                if (state.state_type == .start and state.parent_id == null) {
                    state.layer = 0;
                    try assigned.put(id, {});
                }
            }
        }

        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(self.allocator);

        for (self.diagram.state_order.items) |id| {
            if (assigned.contains(id)) {
                try queue.append(self.allocator, id);
            }
        }

        while (queue.items.len > 0) {
            const current_id = queue.orderedRemove(0);
            const current_layer = self.diagram.getState(current_id).?.layer orelse 0;

            for (self.diagram.transitions.items) |transition| {
                if (!std.mem.eql(u8, transition.from, current_id)) continue;

                const target_id = transition.to;
                if (self.diagram.getStateMut(target_id)) |target_state| {
                    if (!assigned.contains(target_id)) {
                        const new_layer = current_layer + 1;
                        target_state.layer = new_layer;
                        if (new_layer > max_layer) max_layer = new_layer;
                        try assigned.put(target_id, {});
                        try queue.append(self.allocator, target_id);
                    }
                }
            }
        }

        for (self.diagram.state_order.items) |id| {
            if (!assigned.contains(id)) {
                if (self.diagram.getStateMut(id)) |state| {
                    state.layer = 1;
                    try assigned.put(id, {});
                }
            }
        }

        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                if (state.state_type == .end and state.parent_id == null) {
                    var max_predecessor_layer: u32 = 0;
                    for (self.diagram.transitions.items) |t| {
                        if (std.mem.eql(u8, t.to, id)) {
                            if (self.diagram.getState(t.from)) |from_state| {
                                if (from_state.layer) |l| {
                                    if (l > max_predecessor_layer) max_predecessor_layer = l;
                                }
                            }
                        }
                    }
                    state.layer = max_predecessor_layer + 1;
                }
            }
        }

        const total_layers = self.diagram.getLayerCount();
        for (0..total_layers) |_| {
            try self.layers.append(self.allocator, .empty);
        }

        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getState(id)) |state| {
                if (state.layer) |layer| {
                    if (layer < self.layers.items.len) {
                        try self.layers.items[layer].append(self.allocator, id);
                    }
                }
            }
        }
    }

    fn assignOrder(self: *StateLayout) !void {
        for (self.layers.items) |layer| {
            for (layer.items, 0..) |id, order| {
                if (self.diagram.getStateMut(id)) |state| {
                    state.x = @intCast(order);
                }
            }
        }
    }

    fn assignCoordinates(self: *StateLayout) !void {
        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                if (state.state_type == .start or state.state_type == .end) {
                    state.width = 3;
                    state.height = 1;
                } else if (state.state_type == .choice) {
                    const label_len = if (state.label) |l| l.len else state.id.len;
                    state.width = @intCast(@max(label_len + 4, 7));
                    state.height = 3;
                } else {
                    const label_len = if (state.label) |l| l.len else state.id.len;
                    state.width = @intCast(label_len + 4);
                    state.height = 3;
                }
            }
        }

        var layer_widths: std.ArrayList(u32) = .empty;
        defer layer_widths.deinit(self.allocator);

        var max_layer_width: u32 = 0;
        for (self.layers.items) |layer| {
            var layer_width: u32 = 0;
            for (layer.items) |id| {
                if (self.diagram.getState(id)) |state| {
                    layer_width += state.width;
                    if (layer.items.len > 1) {
                        layer_width += self.options.horizontal_spacing;
                    }
                }
            }
            if (layer.items.len > 1 and layer_width >= self.options.horizontal_spacing) {
                layer_width -= self.options.horizontal_spacing;
            }
            layer_widths.append(self.allocator, layer_width) catch {};
            if (layer_width > max_layer_width) max_layer_width = layer_width;
        }

        var layer_transition_counts: std.ArrayList(u32) = .empty;
        defer layer_transition_counts.deinit(self.allocator);

        for (self.layers.items, 0..) |layer, layer_idx| {
            if (layer_idx + 1 >= self.layers.items.len) break;
            const next_layer = self.layers.items[layer_idx + 1];

            var max_transitions: u32 = 0;
            for (layer.items) |from_id| {
                for (next_layer.items) |to_id| {
                    var count: u32 = 0;
                    for (self.diagram.transitions.items) |t| {
                        if (std.mem.eql(u8, t.from, from_id) and std.mem.eql(u8, t.to, to_id)) count += 1;
                        if (std.mem.eql(u8, t.from, to_id) and std.mem.eql(u8, t.to, from_id)) count += 1;
                    }
                    if (count > max_transitions) max_transitions = count;
                }
            }
            layer_transition_counts.append(self.allocator, max_transitions) catch {};
        }

        var y: i32 = 0;
        for (self.layers.items, 0..) |layer, layer_idx| {
            const layer_width = if (layer_idx < layer_widths.items.len) layer_widths.items[layer_idx] else 0;
            var x: i32 = @intCast((max_layer_width - layer_width) / 2);
            var max_height: u32 = 0;

            for (layer.items) |id| {
                if (self.diagram.getStateMut(id)) |state| {
                    state.x = x;
                    state.y = y;
                    x += @intCast(state.width + self.options.horizontal_spacing);
                    if (state.height > max_height) max_height = state.height;
                }
            }

            const transition_count = if (layer_idx < layer_transition_counts.items.len) layer_transition_counts.items[layer_idx] else 1;
            const extra_spacing: u32 = if (transition_count > 1) (transition_count - 1) * 2 else 0;
            const dynamic_spacing = self.options.vertical_spacing + extra_spacing;
            y += @intCast(max_height + dynamic_spacing);
        }

        self.centerStartEndStates();
    }

    fn centerStartEndStates(self: *StateLayout) void {
        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                if (state.state_type == .start) {
                    for (self.diagram.transitions.items) |t| {
                        if (std.mem.eql(u8, t.from, id)) {
                            if (self.diagram.getState(t.to)) |target| {
                                if (target.x) |target_x| {
                                    const target_center = target_x + @as(i32, @intCast(target.width / 2));
                                    state.x = target_center - @as(i32, @intCast(state.width / 2));
                                }
                            }
                            break;
                        }
                    }
                } else if (state.state_type == .end) {
                    for (self.diagram.transitions.items) |t| {
                        if (std.mem.eql(u8, t.to, id)) {
                            if (self.diagram.getState(t.from)) |source| {
                                if (source.x) |source_x| {
                                    const source_center = source_x + @as(i32, @intCast(source.width / 2));
                                    state.x = source_center - @as(i32, @intCast(state.width / 2));
                                }
                            }
                            break;
                        }
                    }
                }
            }
        }
    }

    pub fn getBounds(self: *const StateLayout) struct { width: u32, height: u32 } {
        var max_x: i32 = 0;
        var max_y: i32 = 0;

        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getState(id)) |state| {
                const right = (state.x orelse 0) + @as(i32, @intCast(state.width));
                const bottom = (state.y orelse 0) + @as(i32, @intCast(state.height));
                if (right > max_x) max_x = right;
                if (bottom > max_y) max_y = bottom;
            }
        }

        return .{
            .width = @intCast(@max(max_x, 1)),
            .height = @intCast(@max(max_y, 1)),
        };
    }
};
