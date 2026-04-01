const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Graph = types.Graph;
const Node = types.Node;
const Edge = types.Edge;
const Direction = types.Direction;
const Point = types.Point;
const RenderOptions = types.RenderOptions;

const min_bent_layer_spacing: u32 = 3;
const subgraph_padding: i32 = 2;
const min_subgraph_gap: i32 = 1;

/// Sugiyama-style layered graph layout algorithm
pub const Layout = struct {
    allocator: Allocator,
    graph: *Graph,
    options: RenderOptions,

    // Working data
    layers: std.ArrayList(std.ArrayList([]const u8)),
    reversed_edges: std.ArrayList(usize),

    pub fn init(allocator: Allocator, graph: *Graph, options: RenderOptions) Layout {
        return .{
            .allocator = allocator,
            .graph = graph,
            .options = options,
            .layers = .empty,
            .reversed_edges = .empty,
        };
    }

    pub fn deinit(self: *Layout) void {
        for (self.layers.items) |*layer| {
            layer.deinit(self.allocator);
        }
        self.layers.deinit(self.allocator);
        self.reversed_edges.deinit(self.allocator);
    }

    /// Run the complete layout algorithm
    pub fn run(self: *Layout) !void {
        // Phase 1: Remove cycles by reversing edges
        try self.removeCycles();

        // Phase 2: Assign nodes to layers
        try self.assignLayers();

        // Phase 3: Reduce edge crossings
        try self.reduceCrossings(24);

        // Phase 4: Assign coordinates
        try self.assignCoordinates();

        // Restore reversed edges
        self.restoreReversedEdges();
    }

    // =====================================================
    // Phase 1: Cycle Removal using DFS
    // =====================================================

    fn removeCycles(self: *Layout) !void {
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();
        var in_stack = std.StringHashMap(void).init(self.allocator);
        defer in_stack.deinit();

        for (self.graph.node_order.items) |node_id| {
            if (!visited.contains(node_id)) {
                try self.dfsRemoveCycles(node_id, &visited, &in_stack);
            }
        }
    }

    fn dfsRemoveCycles(
        self: *Layout,
        node_id: []const u8,
        visited: *std.StringHashMap(void),
        in_stack: *std.StringHashMap(void),
    ) !void {
        try visited.put(node_id, {});
        try in_stack.put(node_id, {});

        for (self.graph.edges.items, 0..) |*edge, i| {
            if (!std.mem.eql(u8, edge.from, node_id)) continue;
            if (edge.reversed) continue;

            const target = edge.to;

            if (in_stack.contains(target)) {
                // Back edge found - reverse it
                edge.reversed = true;
                try self.reversed_edges.append(self.allocator, i);
            } else if (!visited.contains(target)) {
                try self.dfsRemoveCycles(target, visited, in_stack);
            }
        }

        _ = in_stack.remove(node_id);
    }

    fn restoreReversedEdges(self: *Layout) void {
        for (self.reversed_edges.items) |i| {
            self.graph.edges.items[i].reversed = false;
        }
    }

    // =====================================================
    // Phase 2: Layer Assignment (Longest Path)
    // =====================================================

    fn assignLayers(self: *Layout) !void {
        // Find nodes with no incoming edges (sources)
        var in_degree = std.StringHashMap(u32).init(self.allocator);
        defer in_degree.deinit();

        for (self.graph.node_order.items) |id| {
            try in_degree.put(id, 0);
        }

        for (self.graph.edges.items) |edge| {
            const to = if (edge.reversed) edge.from else edge.to;
            if (in_degree.getPtr(to)) |count| {
                count.* += 1;
            }
        }

        // Queue of nodes ready to process
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(self.allocator);

        // Initialize sources with layer 0
        for (self.graph.node_order.items) |id| {
            if (in_degree.get(id).? == 0) {
                if (self.graph.getNodeMut(id)) |node| {
                    node.layer = 0;
                    try queue.append(self.allocator, id);
                }
            }
        }

        // BFS to assign layers
        while (queue.items.len > 0) {
            const current_id = queue.orderedRemove(0);
            const current_layer = self.graph.getNode(current_id).?.layer.?;

            for (self.graph.edges.items) |edge| {
                const from = if (edge.reversed) edge.to else edge.from;
                const to = if (edge.reversed) edge.from else edge.to;

                if (!std.mem.eql(u8, from, current_id)) continue;

                if (self.graph.getNodeMut(to)) |target| {
                    const new_layer = current_layer + 1;
                    if (target.layer == null or target.layer.? < new_layer) {
                        target.layer = new_layer;
                    }

                    // Decrease in-degree
                    if (in_degree.getPtr(to)) |count| {
                        if (count.* > 0) {
                            count.* -= 1;
                            if (count.* == 0) {
                                try queue.append(self.allocator, to);
                            }
                        }
                    }
                }
            }
        }

        // Handle any unassigned nodes (isolated or in remaining cycles)
        for (self.graph.node_order.items) |id| {
            if (self.graph.getNodeMut(id)) |node| {
                if (node.layer == null) {
                    node.layer = 0;
                }
            }
        }

        // Build layer structure
        try self.buildLayers();
    }

    fn buildLayers(self: *Layout) !void {
        const layer_count = self.graph.getLayerCount();

        // Initialize empty layers
        for (0..layer_count) |_| {
            try self.layers.append(self.allocator, .empty);
        }

        // Assign nodes to layers
        for (self.graph.node_order.items) |id| {
            if (self.graph.getNode(id)) |node| {
                if (node.layer) |layer| {
                    if (layer < self.layers.items.len) {
                        try self.layers.items[layer].append(self.allocator, id);
                    }
                }
            }
        }

        // Set initial order within layers
        for (self.layers.items) |layer| {
            for (layer.items, 0..) |id, order| {
                if (self.graph.getNodeMut(id)) |node| {
                    node.order = @intCast(order);
                }
            }
        }
    }

    // =====================================================
    // Phase 3: Crossing Reduction (Median Heuristic)
    // =====================================================

    fn reduceCrossings(self: *Layout, max_iterations: u32) !void {
        if (self.layers.items.len < 2) return;

        var best_crossings = self.countCrossings();
        var best_orders = try self.saveOrders();
        defer self.freeOrders(best_orders);

        var iteration: u32 = 0;
        while (iteration < max_iterations) : (iteration += 1) {
            // Sweep down (layer 0 to n-1)
            for (1..self.layers.items.len) |i| {
                try self.reorderLayerByMedian(i, true);
            }

            // Sweep up (layer n-1 to 0)
            var j: usize = self.layers.items.len - 1;
            while (j > 0) : (j -= 1) {
                try self.reorderLayerByMedian(j - 1, false);
            }

            // Check improvement
            const crossings = self.countCrossings();
            if (crossings < best_crossings) {
                best_crossings = crossings;
                self.freeOrders(best_orders);
                best_orders = try self.saveOrders();
            }
        }

        // Restore best ordering
        self.restoreOrders(best_orders);
    }

    fn reorderLayerByMedian(self: *Layout, layer_idx: usize, use_predecessors: bool) !void {
        var layer = &self.layers.items[layer_idx];
        var positions: std.ArrayList(struct { id: []const u8, median: f64 }) = .empty;
        defer positions.deinit(self.allocator);

        for (layer.items) |node_id| {
            const median = try self.calculateMedian(node_id, use_predecessors);
            try positions.append(self.allocator, .{ .id = node_id, .median = median });
        }

        // Sort by median
        std.mem.sort(@TypeOf(positions.items[0]), positions.items, {}, struct {
            fn lessThan(_: void, a: @TypeOf(positions.items[0]), b: @TypeOf(positions.items[0])) bool {
                return a.median < b.median;
            }
        }.lessThan);

        // Update layer order
        layer.clearRetainingCapacity();
        for (positions.items, 0..) |item, order| {
            try layer.append(self.allocator, item.id);
            if (self.graph.getNodeMut(item.id)) |node| {
                node.order = @intCast(order);
            }
        }
    }

    fn calculateMedian(self: *Layout, node_id: []const u8, use_predecessors: bool) !f64 {
        var neighbor_positions: std.ArrayList(u32) = .empty;
        defer neighbor_positions.deinit(self.allocator);

        for (self.graph.edges.items) |edge| {
            const from = if (edge.reversed) edge.to else edge.from;
            const to = if (edge.reversed) edge.from else edge.to;

            const neighbor_id = if (use_predecessors)
                (if (std.mem.eql(u8, to, node_id)) from else null)
            else
                (if (std.mem.eql(u8, from, node_id)) to else null);

            if (neighbor_id) |id| {
                if (self.graph.getNode(id)) |neighbor| {
                    if (neighbor.order) |order| {
                        try neighbor_positions.append(self.allocator, order);
                    }
                }
            }
        }

        if (neighbor_positions.items.len == 0) {
            // Keep current position if no neighbors
            if (self.graph.getNode(node_id)) |node| {
                return @floatFromInt(node.order orelse 0);
            }
            return 0.0;
        }

        // Sort positions and find median
        std.mem.sort(u32, neighbor_positions.items, {}, std.sort.asc(u32));

        const len = neighbor_positions.items.len;
        if (len % 2 == 1) {
            return @floatFromInt(neighbor_positions.items[len / 2]);
        } else {
            const a: f64 = @floatFromInt(neighbor_positions.items[len / 2 - 1]);
            const b: f64 = @floatFromInt(neighbor_positions.items[len / 2]);
            return (a + b) / 2.0;
        }
    }

    fn countCrossings(self: *Layout) u32 {
        var crossings: u32 = 0;

        for (0..self.layers.items.len - 1) |i| {
            crossings += self.countCrossingsBetweenLayers(i, i + 1);
        }

        return crossings;
    }

    fn countCrossingsBetweenLayers(self: *Layout, layer1: usize, layer2: usize) u32 {
        var crossings: u32 = 0;

        // Collect edges between these layers
        var edges_between: std.ArrayList(struct { from_order: u32, to_order: u32 }) = .empty;
        defer edges_between.deinit(self.allocator);

        for (self.graph.edges.items) |edge| {
            const from = if (edge.reversed) edge.to else edge.from;
            const to = if (edge.reversed) edge.from else edge.to;

            const from_node = self.graph.getNode(from) orelse continue;
            const to_node = self.graph.getNode(to) orelse continue;

            if (from_node.layer == @as(u32, @intCast(layer1)) and to_node.layer == @as(u32, @intCast(layer2))) {
                edges_between.append(self.allocator, .{
                    .from_order = from_node.order orelse 0,
                    .to_order = to_node.order orelse 0,
                }) catch continue;
            }
        }

        // Count crossings (O(n^2) but simple)
        for (edges_between.items, 0..) |e1, i| {
            for (edges_between.items[i + 1 ..]) |e2| {
                // Edges cross if their ordering is reversed
                if ((e1.from_order < e2.from_order and e1.to_order > e2.to_order) or
                    (e1.from_order > e2.from_order and e1.to_order < e2.to_order))
                {
                    crossings += 1;
                }
            }
        }

        return crossings;
    }

    fn saveOrders(self: *Layout) ![]std.ArrayList([]const u8) {
        var orders = try self.allocator.alloc(std.ArrayList([]const u8), self.layers.items.len);
        for (self.layers.items, 0..) |layer, i| {
            orders[i] = try layer.clone(self.allocator);
        }
        return orders;
    }

    fn restoreOrders(self: *Layout, orders: []std.ArrayList([]const u8)) void {
        for (orders, 0..) |order, i| {
            self.layers.items[i].clearRetainingCapacity();
            for (order.items, 0..) |id, j| {
                self.layers.items[i].append(self.allocator, id) catch continue;
                if (self.graph.getNodeMut(id)) |node| {
                    node.order = @intCast(j);
                }
            }
        }
    }

    fn freeOrders(self: *Layout, orders: []std.ArrayList([]const u8)) void {
        for (orders) |*order| {
            order.deinit(self.allocator);
        }
        self.allocator.free(orders);
    }

    // =====================================================
    // Phase 4: Coordinate Assignment
    // =====================================================

    fn assignCoordinates(self: *Layout) !void {
        // Calculate node dimensions
        for (self.graph.node_order.items) |id| {
            if (self.graph.getNodeMut(id)) |node| {
                const wrapped = wrapLabelMetrics(node.label, self.options.max_label_width);
                node.width = @intCast(wrapped.max_line_len + 2 * self.options.node_padding + 2);
                // Height depends on shape
                node.height = switch (node.shape) {
                    .cylinder => @intCast(@max(wrapped.line_count + 3, 4)), // top cap + content + bottom
                    else => @intCast(@max(wrapped.line_count + 2, 3)),
                };
            }
        }

        // Calculate layer widths and positions
        const direction = self.graph.direction;
        const is_horizontal = direction.isHorizontal();

        if (is_horizontal) {
            try self.assignHorizontalCoordinates();
        } else {
            try self.assignVerticalCoordinates();
        }

        try self.enforceSubgraphSeparation();
    }

    fn enforceSubgraphSeparation(self: *Layout) !void {
        if (self.graph.subgraphs.items.len < 2) return;

        const max_iterations = self.graph.subgraphs.items.len * self.graph.subgraphs.items.len;
        var iteration: usize = 0;
        while (iteration < max_iterations) : (iteration += 1) {
            var moved = false;

            for (0..self.graph.subgraphs.items.len) |i| {
                for (i + 1..self.graph.subgraphs.items.len) |j| {
                    const a_bounds = self.getSubgraphBounds(&self.graph.subgraphs.items[i]) orelse continue;
                    const b_bounds = self.getSubgraphBounds(&self.graph.subgraphs.items[j]) orelse continue;

                    const x_gap = axisGap(a_bounds.min_x, a_bounds.max_x, b_bounds.min_x, b_bounds.max_x);
                    const y_gap = axisGap(a_bounds.min_y, a_bounds.max_y, b_bounds.min_y, b_bounds.max_y);

                    if (x_gap >= min_subgraph_gap or y_gap >= min_subgraph_gap) continue;

                    const needed_x = min_subgraph_gap - x_gap;
                    const needed_y = min_subgraph_gap - y_gap;
                    const shift_x = if (needed_x < needed_y)
                        true
                    else if (needed_y < needed_x)
                        false
                    else
                        self.graph.direction.isHorizontal();

                    if (shift_x) {
                        if (a_bounds.min_x <= b_bounds.min_x) {
                            try self.shiftSubgraph(&self.graph.subgraphs.items[j], needed_x, 0);
                        } else {
                            try self.shiftSubgraph(&self.graph.subgraphs.items[i], needed_x, 0);
                        }
                    } else {
                        if (a_bounds.min_y <= b_bounds.min_y) {
                            try self.shiftSubgraph(&self.graph.subgraphs.items[j], 0, needed_y);
                        } else {
                            try self.shiftSubgraph(&self.graph.subgraphs.items[i], 0, needed_y);
                        }
                    }

                    moved = true;
                }
            }

            if (!moved) break;
        }
    }

    fn getSubgraphBounds(self: *const Layout, subgraph: *const types.Subgraph) ?struct { min_x: i32, max_x: i32, min_y: i32, max_y: i32 } {
        var min_x: i32 = std.math.maxInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var max_y: i32 = std.math.minInt(i32);

        for (subgraph.node_ids.items) |node_id| {
            const node = self.graph.getNode(node_id) orelse continue;
            const x = node.x orelse continue;
            const y = node.y orelse continue;
            const w: i32 = @intCast(node.width);
            const h: i32 = @intCast(node.height);

            min_x = @min(min_x, x - subgraph_padding);
            min_y = @min(min_y, y - subgraph_padding);
            max_x = @max(max_x, x + w + subgraph_padding);
            max_y = @max(max_y, y + h + subgraph_padding);
        }

        if (min_x == std.math.maxInt(i32)) return null;
        return .{ .min_x = min_x, .max_x = max_x, .min_y = min_y, .max_y = max_y };
    }

    fn shiftSubgraph(self: *Layout, subgraph: *const types.Subgraph, dx: i32, dy: i32) !void {
        for (subgraph.node_ids.items) |node_id| {
            if (self.graph.getNodeMut(node_id)) |node| {
                if (node.x) |*x| x.* += dx;
                if (node.y) |*y| y.* += dy;
            }
        }
    }

    fn assignHorizontalCoordinates(self: *Layout) !void {
        // For LR/RL: layers are columns (x), nodes stack vertically (y)
        const is_reversed = self.graph.direction.isReversed();

        // Calculate layer order
        const layer_indices = try self.allocator.alloc(usize, self.layers.items.len);
        defer self.allocator.free(layer_indices);

        for (0..self.layers.items.len) |i| {
            layer_indices[i] = if (is_reversed) self.layers.items.len - 1 - i else i;
        }

        const layer_widths = try self.allocator.alloc(u32, layer_indices.len);
        defer self.allocator.free(layer_widths);

        for (layer_indices, 0..) |layer_idx, display_idx| {
            const layer = self.layers.items[layer_idx];

            // Find max width in this layer
            var max_width: u32 = 0;
            for (layer.items) |id| {
                if (self.graph.getNode(id)) |node| {
                    if (node.width > max_width) max_width = node.width;
                }
            }
            layer_widths[display_idx] = max_width;

            // Y positions are independent from the inter-column gap.
            var y: i32 = 0;
            for (layer.items) |id| {
                if (self.graph.getNodeMut(id)) |node| {
                    node.y = y;
                    y += @intCast(node.height + self.options.vertical_spacing);
                }
            }
        }

        const layer_gaps = try self.allocator.alloc(u32, if (layer_indices.len > 0) layer_indices.len - 1 else 0);
        defer self.allocator.free(layer_gaps);
        for (layer_gaps, 0..) |*gap, display_idx| {
            gap.* = self.options.horizontal_spacing;
            if (self.hasBentEdgeBetweenLayers(layer_indices[display_idx], layer_indices[display_idx + 1])) {
                gap.* = @max(gap.*, min_bent_layer_spacing);
            }
        }

        var x: i32 = 0;
        for (layer_indices, 0..) |layer_idx, display_idx| {
            const layer = self.layers.items[layer_idx];
            for (layer.items) |id| {
                if (self.graph.getNodeMut(id)) |node| {
                    node.x = x;
                }
            }

            x += @intCast(layer_widths[display_idx]);
            if (display_idx + 1 < layer_indices.len) {
                x += @intCast(layer_gaps[display_idx]);
            }
        }
    }

    fn assignVerticalCoordinates(self: *Layout) !void {
        // For TD/BT: layers are rows (y), nodes spread horizontally (x)
        const is_reversed = self.graph.direction.isReversed();

        // First pass: find the widest single-node layer for centering
        var max_single_width: u32 = 0;
        for (self.layers.items) |layer| {
            if (layer.items.len == 1) {
                if (self.graph.getNode(layer.items[0])) |node| {
                    if (node.width > max_single_width) max_single_width = node.width;
                }
            }
        }

        const layer_heights = try self.allocator.alloc(u32, self.layers.items.len);
        defer self.allocator.free(layer_heights);

        for (0..self.layers.items.len) |i| {
            const layer_idx = if (is_reversed) self.layers.items.len - 1 - i else i;
            const layer = self.layers.items[layer_idx];

            // Find max height in this layer
            var max_height: u32 = 0;
            for (layer.items) |id| {
                if (self.graph.getNode(id)) |node| {
                    if (node.height > max_height) max_height = node.height;
                }
            }
            layer_heights[i] = max_height;

            // X positions are independent from the inter-row gap.
            var x: i32 = 0;
            for (layer.items) |id| {
                if (self.graph.getNodeMut(id)) |node| {
                    // Center single-node layers for clean vertical alignment
                    if (layer.items.len == 1 and max_single_width > 0) {
                        const center_offset = @divFloor(@as(i32, @intCast(max_single_width - node.width)), 2);
                        node.x = center_offset;
                    } else {
                        node.x = x;
                    }
                    x += @intCast(node.width + self.options.horizontal_spacing);
                }
            }
        }

        const layer_gaps = try self.allocator.alloc(u32, if (self.layers.items.len > 0) self.layers.items.len - 1 else 0);
        defer self.allocator.free(layer_gaps);
        for (layer_gaps, 0..) |*gap, display_idx| {
            gap.* = self.options.vertical_spacing;
            const upper_layer = if (is_reversed) self.layers.items.len - 1 - display_idx else display_idx;
            const lower_layer = if (is_reversed) self.layers.items.len - 2 - display_idx else display_idx + 1;
            if (self.hasBentEdgeBetweenLayers(upper_layer, lower_layer)) {
                gap.* = @max(gap.*, min_bent_layer_spacing);
            }
        }

        var y: i32 = 0;
        for (0..self.layers.items.len) |i| {
            const layer_idx = if (is_reversed) self.layers.items.len - 1 - i else i;
            const layer = self.layers.items[layer_idx];
            for (layer.items) |id| {
                if (self.graph.getNodeMut(id)) |node| {
                    node.y = y;
                }
            }

            y += @intCast(layer_heights[i]);
            if (i + 1 < self.layers.items.len) {
                y += @intCast(layer_gaps[i]);
            }
        }
    }

    fn hasBentEdgeBetweenLayers(self: *Layout, layer_a: usize, layer_b: usize) bool {
        for (self.graph.edges.items, 0..) |edge, edge_index| {
            const from_node = self.graph.getNode(edge.from) orelse continue;
            const to_node = self.graph.getNode(edge.to) orelse continue;
            const from_layer = from_node.layer orelse continue;
            const to_layer = to_node.layer orelse continue;

            const layer_a_u32: u32 = @intCast(layer_a);
            const layer_b_u32: u32 = @intCast(layer_b);
            const matches_layers = (from_layer == layer_a_u32 and to_layer == layer_b_u32) or
                (from_layer == layer_b_u32 and to_layer == layer_a_u32);
            if (!matches_layers) continue;

            const exit_offset = self.edgeExitOffset(edge.from, edge_index);
            const start = getExitPointOffsetForLayout(from_node, self.graph.direction, exit_offset.this_edge_index, exit_offset.edge_count);
            const end = getEntryPointForLayout(to_node, self.graph.direction);

            if (self.graph.direction.isHorizontal()) {
                if (start.y != end.y) return true;
            } else {
                if (start.x != end.x) return true;
            }
        }

        return false;
    }

    fn edgeExitOffset(self: *Layout, from_id: []const u8, edge_index: usize) struct { edge_count: i32, this_edge_index: i32 } {
        var edge_count: i32 = 0;
        var this_edge_index: i32 = 0;

        for (self.graph.edges.items, 0..) |edge, i| {
            if (!std.mem.eql(u8, edge.from, from_id)) continue;
            if (i == edge_index) this_edge_index = edge_count;
            edge_count += 1;
        }

        return .{ .edge_count = edge_count, .this_edge_index = this_edge_index };
    }
};

fn getExitPointOffsetForLayout(node: *const Node, direction: Direction, edge_idx: i32, edge_count: i32) Point {
    const x = node.x orelse 0;
    const y = node.y orelse 0;
    const w: i32 = @intCast(node.width);
    const h: i32 = @intCast(node.height);

    const spread: i32 = if (edge_count > 1) blk: {
        const size = if (direction.isHorizontal()) h else w;
        const step = @divFloor(size, edge_count + 1);
        break :blk step * (edge_idx + 1) - @divFloor(size, 2);
    } else 0;

    return switch (direction) {
        .LR => .{ .x = x + w, .y = y + @divFloor(h, 2) + spread },
        .RL => .{ .x = x - 1, .y = y + @divFloor(h, 2) + spread },
        .TD, .TB => .{ .x = x + @divFloor(w, 2) + spread, .y = y + h },
        .BT => .{ .x = x + @divFloor(w, 2) + spread, .y = y - 1 },
    };
}

fn getEntryPointForLayout(node: *const Node, direction: Direction) Point {
    const x = node.x orelse 0;
    const y = node.y orelse 0;
    const w: i32 = @intCast(node.width);
    const h: i32 = @intCast(node.height);

    return switch (direction) {
        .LR => .{ .x = x - 1, .y = y + @divFloor(h, 2) },
        .RL => .{ .x = x + w, .y = y + @divFloor(h, 2) },
        .TD, .TB => .{ .x = x + @divFloor(w, 2), .y = y - 1 },
        .BT => .{ .x = x + @divFloor(w, 2), .y = y + h },
    };
}

fn axisGap(a_min: i32, a_max: i32, b_min: i32, b_max: i32) i32 {
    return if (a_min <= b_min) b_min - a_max else a_min - b_max;
}

/// Calculate effective label length after processing <br/> tags
fn effectiveLabelLen(label: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < label.len) {
        if (i + 4 < label.len and std.mem.eql(u8, label[i .. i + 4], "<br>")) {
            len += 1; // <br> becomes a space
            i += 4;
        } else if (i + 5 <= label.len and std.mem.eql(u8, label[i .. i + 5], "<br/>")) {
            len += 1; // <br/> becomes a space
            i += 5;
        } else {
            len += 1;
            i += 1;
        }
    }
    return len;
}

const LabelMetrics = struct {
    max_line_len: usize,
    line_count: usize,
};

fn wrapLabelMetrics(label: []const u8, max_label_width: ?u32) LabelMetrics {
    const effective = effectiveLabelLen(label);
    const width = max_label_width orelse return .{ .max_line_len = effective, .line_count = 1 };
    const wrap_width: usize = @intCast(@max(width, 1));

    if (effective <= wrap_width) {
        return .{ .max_line_len = effective, .line_count = 1 };
    }

    var max_line_len: usize = 0;
    var current_line_len: usize = 0;
    var line_count: usize = 1;
    var i: usize = 0;

    while (i < label.len) {
        if (i + 4 <= label.len and std.mem.eql(u8, label[i .. i + 4], "<br>")) {
            if (current_line_len > max_line_len) max_line_len = current_line_len;
            current_line_len = 0;
            line_count += 1;
            i += 4;
            continue;
        }
        if (i + 5 <= label.len and std.mem.eql(u8, label[i .. i + 5], "<br/>")) {
            if (current_line_len > max_line_len) max_line_len = current_line_len;
            current_line_len = 0;
            line_count += 1;
            i += 5;
            continue;
        }

        var word_len: usize = 0;
        var j = i;
        while (j < label.len and label[j] != ' ') : (j += 1) {
            if (j + 4 <= label.len and std.mem.eql(u8, label[j .. j + 4], "<br>")) break;
            if (j + 5 <= label.len and std.mem.eql(u8, label[j .. j + 5], "<br/>")) break;
            word_len += 1;
        }

        if (label[i] == ' ') {
            if (current_line_len == 0) {
                i += 1;
                continue;
            }
            if (current_line_len + 1 > wrap_width) {
                if (current_line_len > max_line_len) max_line_len = current_line_len;
                current_line_len = 0;
                line_count += 1;
            } else {
                current_line_len += 1;
            }
            i += 1;
            continue;
        }

        if (current_line_len > 0 and current_line_len + word_len > wrap_width) {
            if (current_line_len > max_line_len) max_line_len = current_line_len;
            current_line_len = 0;
            line_count += 1;
        }

        if (word_len > wrap_width) {
            var remaining = word_len;
            while (remaining > 0) {
                const chunk = @min(remaining, wrap_width);
                if (chunk > max_line_len) max_line_len = chunk;
                remaining -= chunk;
                if (remaining > 0) line_count += 1;
            }
            current_line_len = 0;
        } else {
            current_line_len += word_len;
            if (current_line_len > max_line_len) max_line_len = current_line_len;
        }
        i = j;
    }

    if (current_line_len > max_line_len) max_line_len = current_line_len;
    return .{ .max_line_len = @max(max_line_len, 1), .line_count = @max(line_count, 1) };
}

// =====================================================
// State Diagram Layout
// =====================================================

const StateDiagram = types.StateDiagram;
const State = types.State;
const StateType = types.StateType;

/// Layout algorithm for state diagrams
/// Key principle: Start states at top, end states at bottom, unless inside composite
pub const StateLayout = struct {
    allocator: Allocator,
    diagram: *StateDiagram,
    options: RenderOptions,

    // Working data
    layers: std.ArrayList(std.ArrayList([]const u8)),

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

    /// Run the complete layout algorithm
    pub fn run(self: *StateLayout) !void {
        // Phase 1: Assign layers using BFS from start states
        try self.assignLayers();

        // Phase 2: Assign order within layers
        try self.assignOrder();

        // Phase 3: Assign coordinates
        try self.assignCoordinates();
    }

    // =====================================================
    // Phase 1: Layer Assignment
    // Start states go to layer 0, end states to last layer
    // =====================================================

    fn assignLayers(self: *StateLayout) !void {
        var assigned = std.StringHashMap(void).init(self.allocator);
        defer assigned.deinit();

        // First pass: Find max depth using BFS from start states
        var max_layer: u32 = 0;

        // Assign start states to layer 0
        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                if (state.state_type == .start and state.parent_id == null) {
                    state.layer = 0;
                    try assigned.put(id, {});
                }
            }
        }

        // BFS from start states
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

            // Find outgoing transitions
            for (self.diagram.transitions.items) |transition| {
                if (!std.mem.eql(u8, transition.from, current_id)) continue;

                const target_id = transition.to;
                if (self.diagram.getStateMut(target_id)) |target_state| {
                    // Don't override if already assigned
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

        // Assign unassigned states (disconnected) to appropriate layer
        for (self.diagram.state_order.items) |id| {
            if (!assigned.contains(id)) {
                if (self.diagram.getStateMut(id)) |state| {
                    // Regular unassigned states go to layer 1
                    state.layer = 1;
                    try assigned.put(id, {});
                }
            }
        }

        // For each end state, set its layer to (max predecessor layer + 1)
        // This ensures the end state is exactly one step after the latest state that transitions to it
        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                if (state.state_type == .end and state.parent_id == null) {
                    // Find max layer among all states that transition TO this end state
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
                    // Set end state to one layer after max predecessor
                    state.layer = max_predecessor_layer + 1;
                }
            }
        }

        // Build layer arrays
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

    // =====================================================
    // Phase 2: Order Assignment within layers
    // =====================================================

    fn assignOrder(self: *StateLayout) !void {
        for (self.layers.items) |layer| {
            for (layer.items, 0..) |id, order| {
                if (self.diagram.getStateMut(id)) |state| {
                    // Store order in x field temporarily
                    state.x = @intCast(order);
                }
            }
        }
    }

    // =====================================================
    // Phase 3: Coordinate Assignment
    // =====================================================

    fn assignCoordinates(self: *StateLayout) !void {
        // First pass: Calculate node sizes
        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                // Size based on state type
                if (state.state_type == .start or state.state_type == .end) {
                    // Small circles for start/end
                    state.width = 3;
                    state.height = 1;
                } else if (state.state_type == .choice) {
                    // Diamond for choice
                    const label_len = if (state.label) |l| l.len else state.id.len;
                    state.width = @intCast(@max(label_len + 4, 7));
                    state.height = 3;
                } else {
                    // Regular state box
                    const label_len = if (state.label) |l| l.len else state.id.len;
                    state.width = @intCast(label_len + 4);
                    state.height = 3;
                }
            }
        }

        // Second pass: Calculate layer widths and find max
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
            // Remove trailing spacing
            if (layer.items.len > 1 and layer_width >= self.options.horizontal_spacing) {
                layer_width -= self.options.horizontal_spacing;
            }
            layer_widths.append(self.allocator, layer_width) catch {};
            if (layer_width > max_layer_width) max_layer_width = layer_width;
        }

        // Third pass: Calculate transitions between each pair of layers
        // This determines the dynamic spacing needed
        var layer_transition_counts: std.ArrayList(u32) = .empty;
        defer layer_transition_counts.deinit(self.allocator);

        for (self.layers.items, 0..) |layer, layer_idx| {
            if (layer_idx + 1 >= self.layers.items.len) break;
            const next_layer = self.layers.items[layer_idx + 1];

            var max_transitions: u32 = 0;
            // Count transitions between states in this layer and next layer
            for (layer.items) |from_id| {
                for (next_layer.items) |to_id| {
                    var count: u32 = 0;
                    for (self.diagram.transitions.items) |t| {
                        // Count forward transitions
                        if (std.mem.eql(u8, t.from, from_id) and std.mem.eql(u8, t.to, to_id)) {
                            count += 1;
                        }
                        // Count back transitions
                        if (std.mem.eql(u8, t.from, to_id) and std.mem.eql(u8, t.to, from_id)) {
                            count += 1;
                        }
                    }
                    if (count > max_transitions) max_transitions = count;
                }
            }
            layer_transition_counts.append(self.allocator, max_transitions) catch {};
        }

        // Fourth pass: Assign coordinates with dynamic spacing
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

            // Dynamic spacing: base + extra per transition
            const transition_count = if (layer_idx < layer_transition_counts.items.len) layer_transition_counts.items[layer_idx] else 1;
            const extra_spacing: u32 = if (transition_count > 1) (transition_count - 1) * 2 else 0;
            const dynamic_spacing = self.options.vertical_spacing + extra_spacing;
            y += @intCast(max_height + dynamic_spacing);
        }

        // Fifth pass: Center start/end states with their connected states
        self.centerStartEndStates();
    }

    fn centerStartEndStates(self: *StateLayout) void {
        // For each start state, center it with its outgoing transition targets
        // For each end state, center it with its incoming transition sources
        for (self.diagram.state_order.items) |id| {
            if (self.diagram.getStateMut(id)) |state| {
                if (state.state_type == .start) {
                    // Find first outgoing transition target
                    for (self.diagram.transitions.items) |t| {
                        if (std.mem.eql(u8, t.from, id)) {
                            if (self.diagram.getState(t.to)) |target| {
                                if (target.x) |target_x| {
                                    // Center start state with target
                                    const target_center = target_x + @as(i32, @intCast(target.width / 2));
                                    state.x = target_center - @as(i32, @intCast(state.width / 2));
                                }
                            }
                            break;
                        }
                    }
                } else if (state.state_type == .end) {
                    // Find first incoming transition source
                    for (self.diagram.transitions.items) |t| {
                        if (std.mem.eql(u8, t.to, id)) {
                            if (self.diagram.getState(t.from)) |source| {
                                if (source.x) |source_x| {
                                    // Center end state with source
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

    /// Get the bounding box of the diagram
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

test "state layout simple" {
    const testing = std.testing;
    const parser = @import("parser.zig");

    const source =
        \\stateDiagram-v2
        \\    [*] --> s1
        \\    s1 --> s2
        \\    s2 --> [*]
    ;

    var diagram = try parser.Parser.parseStateDiagram(testing.allocator, source);
    defer diagram.deinit();

    var layout = StateLayout.init(testing.allocator, &diagram, .{});
    defer layout.deinit();

    try layout.run();

    // Check that start is at layer 0 and end at last layer
    var start_layer: ?u32 = null;
    var end_layer: ?u32 = null;

    for (diagram.state_order.items) |id| {
        if (diagram.getState(id)) |state| {
            if (state.state_type == .start) {
                start_layer = state.layer;
            } else if (state.state_type == .end) {
                end_layer = state.layer;
            }
        }
    }

    try testing.expect(start_layer != null);
    try testing.expect(end_layer != null);
    try testing.expect(start_layer.? < end_layer.?);

    // All states should have coordinates
    for (diagram.state_order.items) |id| {
        const state = diagram.getState(id).?;
        try testing.expect(state.x != null);
        try testing.expect(state.y != null);
    }
}

test "layout simple graph" {
    const testing = std.testing;
    const parser = @import("parser.zig");

    const source =
        \\graph LR
        \\    A --> B
        \\    B --> C
    ;

    var graph = try parser.Parser.parse(testing.allocator, source);
    defer graph.deinit();

    var layout = Layout.init(testing.allocator, &graph, .{});
    defer layout.deinit();

    try layout.run();

    // Check layers are assigned
    try testing.expect(graph.getNode("A").?.layer != null);
    try testing.expect(graph.getNode("B").?.layer != null);
    try testing.expect(graph.getNode("C").?.layer != null);

    // A should be in layer 0, B in layer 1, C in layer 2
    try testing.expectEqual(@as(u32, 0), graph.getNode("A").?.layer.?);
    try testing.expectEqual(@as(u32, 1), graph.getNode("B").?.layer.?);
    try testing.expectEqual(@as(u32, 2), graph.getNode("C").?.layer.?);

    // Coordinates should be assigned
    try testing.expect(graph.getNode("A").?.x != null);
    try testing.expect(graph.getNode("B").?.x != null);
    try testing.expect(graph.getNode("C").?.x != null);
}

test "layout with cycle" {
    const testing = std.testing;
    const parser = @import("parser.zig");

    const source =
        \\graph TD
        \\    A --> B
        \\    B --> C
        \\    C --> A
    ;

    var graph = try parser.Parser.parse(testing.allocator, source);
    defer graph.deinit();

    var layout = Layout.init(testing.allocator, &graph, .{});
    defer layout.deinit();

    // Should not error even with a cycle
    try layout.run();

    // All nodes should have layers
    try testing.expect(graph.getNode("A").?.layer != null);
    try testing.expect(graph.getNode("B").?.layer != null);
    try testing.expect(graph.getNode("C").?.layer != null);
}

test "crossing reduction" {
    const testing = std.testing;
    const parser = @import("parser.zig");

    // Graph designed to have crossings initially
    const source =
        \\graph TD
        \\    A --> C
        \\    B --> D
        \\    A --> D
        \\    B --> C
    ;

    var graph = try parser.Parser.parse(testing.allocator, source);
    defer graph.deinit();

    var layout = Layout.init(testing.allocator, &graph, .{});
    defer layout.deinit();

    try layout.run();

    // After layout, crossings should be minimized
    // The optimal ordering should have A,B in layer 0 and C,D or D,C in layer 1
    const crossings = layout.countCrossings();
    // With optimal ordering, crossings should be 0 or minimal
    try testing.expect(crossings <= 2);
}

test "layout widens adjacent bent flowchart edges under tight spacing" {
    const testing = std.testing;
    const parser = @import("parser.zig");

    const source =
        \\graph TD
        \\    A --> B
        \\    A --> C
    ;

    var graph = try parser.Parser.parse(testing.allocator, source);
    defer graph.deinit();

    var layout = Layout.init(testing.allocator, &graph, .{
        .vertical_spacing = 1,
        .horizontal_spacing = 2,
    });
    defer layout.deinit();

    try layout.run();

    var saw_bent_edge = false;
    for (graph.edges.items, 0..) |edge, edge_index| {
        const from_node = graph.getNode(edge.from).?;
        const to_node = graph.getNode(edge.to).?;
        const exit_offset = layout.edgeExitOffset(edge.from, edge_index);
        const start = getExitPointOffsetForLayout(from_node, graph.direction, exit_offset.this_edge_index, exit_offset.edge_count);
        const end = getEntryPointForLayout(to_node, graph.direction);

        if (start.x != end.x) {
            saw_bent_edge = true;
            try testing.expect(end.y - start.y >= 2);
        }
    }

    try testing.expect(saw_bent_edge);
}

test "layout keeps adjacent subgraphs separated under tight compaction" {
    const testing = std.testing;
    const parser = @import("parser.zig");

    const source =
        \\graph LR
        \\    subgraph frontend/
        \\        AUTH[auth]
        \\    end
        \\
        \\    subgraph backend/
        \\        API[api]
        \\    end
        \\
        \\    AUTH --> API
    ;

    var graph = try parser.Parser.parse(testing.allocator, source);
    defer graph.deinit();

    var layout = Layout.init(testing.allocator, &graph, .{
        .horizontal_spacing = 2,
        .vertical_spacing = 1,
    });
    defer layout.deinit();

    try layout.run();

    try testing.expectEqual(@as(usize, 2), graph.subgraphs.items.len);

    const first = layout.getSubgraphBounds(&graph.subgraphs.items[0]).?;
    const second = layout.getSubgraphBounds(&graph.subgraphs.items[1]).?;
    const x_gap = axisGap(first.min_x, first.max_x, second.min_x, second.max_x);
    const y_gap = axisGap(first.min_y, first.max_y, second.min_y, second.max_y);

    try testing.expect(x_gap >= min_subgraph_gap or y_gap >= min_subgraph_gap);
    try testing.expect(x_gap >= min_subgraph_gap);
}
