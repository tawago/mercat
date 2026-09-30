const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

const StateDiagram = model.StateDiagram;
const StateType = model.StateType;

const horizontal_spacing: u32 = 8;
const vertical_spacing: u32 = 3;

pub const StateLayout = struct {
    allocator: Allocator,
    diagram: *StateDiagram,

    layers: std.ArrayList(std.ArrayList([]const u8)),

    pub fn init(allocator: Allocator, diagram: *StateDiagram) StateLayout {
        return .{
            .allocator = allocator,
            .diagram = diagram,
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
        self.assignCoordinates();
    }

    /// Layer 0 holds the top-level start states, each other state sits one layer below the
    /// first state that reaches it, states nothing reaches sit in layer 1, and a top-level end
    /// state sits below the deepest state that leads to it.
    fn assignLayers(self: *StateLayout) !void {
        try self.spreadFromStarts();
        self.placeUnreached();
        self.lowerEndStates();
        try self.bucketByLayer();
    }

    fn spreadFromStarts(self: *StateLayout) !void {
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(self.allocator);

        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                if (state.state_type == .start and state.parent_id == null) {
                    state.layer = 0;
                    try queue.append(self.allocator, id);
                }
            }
        }

        while (queue.items.len > 0) {
            const current_id = queue.orderedRemove(0);
            const current_layer = self.diagram.getState(current_id).?.layer orelse 0;

            for (self.diagram.transitions.items) |transition| {
                if (!std.mem.eql(u8, transition.from, current_id)) continue;

                const target_id = transition.to;
                if (self.diagram.getStateMut(target_id)) |target_state| {
                    if (target_state.layer == null) {
                        target_state.layer = current_layer + 1;
                        try queue.append(self.allocator, target_id);
                    }
                }
            }
        }
    }

    fn placeUnreached(self: *StateLayout) void {
        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                if (state.layer == null) state.layer = 1;
            }
        }
    }

    fn lowerEndStates(self: *StateLayout) void {
        for (self.diagram.state_order.items) |id| {
            const state = self.diagram.getStateMut(id) orelse continue;
            if (state.state_type != .end or state.parent_id != null) continue;

            var max_predecessor_layer: u32 = 0;
            for (self.diagram.transitions.items) |t| {
                if (!std.mem.eql(u8, t.to, id)) continue;
                const from_state = self.diagram.getState(t.from) orelse continue;
                const from_layer = from_state.layer orelse continue;
                if (from_layer > max_predecessor_layer) max_predecessor_layer = from_layer;
            }
            state.layer = max_predecessor_layer + 1;
        }
    }

    fn bucketByLayer(self: *StateLayout) !void {
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

    fn assignCoordinates(self: *StateLayout) void {
        self.sizeStates();

        var max_layer_width: u32 = 0;
        for (self.layers.items) |layer| {
            max_layer_width = @max(max_layer_width, self.layerWidth(layer));
        }

        var y: i32 = 0;
        for (self.layers.items, 0..) |layer, layer_idx| {
            var x: i32 = @intCast((max_layer_width - self.layerWidth(layer)) / 2);
            var max_height: u32 = 0;

            for (layer.items) |id| {
                if (self.diagram.getStateMut(id)) |state| {
                    state.x = x;
                    state.y = y;
                    x += @intCast(state.width + horizontal_spacing);
                    if (state.height > max_height) max_height = state.height;
                }
            }

            y += @intCast(max_height + vertical_spacing + self.extraSpacing(layer_idx));
        }

        self.centerStartEndStates();
    }

    fn sizeStates(self: *StateLayout) void {
        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                const label_len = if (state.label) |l| l.len else state.id.len;
                switch (state.state_type) {
                    .start, .end => {
                        state.width = 3;
                        state.height = 1;
                    },
                    .choice => {
                        state.width = @intCast(@max(label_len + 4, 7));
                        state.height = 3;
                    },
                    else => {
                        state.width = @intCast(label_len + 4);
                        state.height = 3;
                    },
                }
            }
        }
    }

    fn layerWidth(self: *const StateLayout, layer: std.ArrayList([]const u8)) u32 {
        var width: u32 = 0;
        for (layer.items) |id| {
            if (self.diagram.getState(id)) |state| {
                width += state.width;
                if (layer.items.len > 1) {
                    width += horizontal_spacing;
                }
            }
        }
        if (layer.items.len > 1 and width >= horizontal_spacing) {
            width -= horizontal_spacing;
        }
        return width;
    }

    /// Extra rows under a layer for the parallel transitions between it and the next: two for
    /// each one beyond the first, counting both directions of a pair.
    fn extraSpacing(self: *const StateLayout, layer_idx: usize) u32 {
        if (layer_idx + 1 >= self.layers.items.len) return 0;
        const layer = self.layers.items[layer_idx];
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
        return if (max_transitions > 1) (max_transitions - 1) * 2 else 0;
    }

    /// A start state sits above the target of its first transition, an end state below the
    /// source of the first transition into it.
    fn centerStartEndStates(self: *StateLayout) void {
        for (self.diagram.state_order.items) |id| {
            const state = self.diagram.getStateMut(id) orelse continue;
            const neighbour_id = self.firstNeighbour(id, state.state_type) orelse continue;
            const neighbour = self.diagram.getState(neighbour_id) orelse continue;
            state.x = neighbour.centerX() - @as(i32, @intCast(state.width / 2));
        }
    }

    fn firstNeighbour(self: *const StateLayout, id: []const u8, state_type: StateType) ?[]const u8 {
        for (self.diagram.transitions.items) |t| {
            switch (state_type) {
                .start => if (std.mem.eql(u8, t.from, id)) return t.to,
                .end => if (std.mem.eql(u8, t.to, id)) return t.from,
                else => return null,
            }
        }
        return null;
    }

    pub fn getBounds(self: *const StateLayout) struct { width: u32, height: u32 } {
        var max_x: i32 = 0;
        var max_y: i32 = 0;

        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getState(id)) |state| {
                const right = state.x + @as(i32, @intCast(state.width));
                const bottom = state.y + @as(i32, @intCast(state.height));
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
