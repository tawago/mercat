const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");

const Direction = types.Direction;

pub const StateType = enum {
    start,
    end,
    regular,
    choice,
    fork,
    join,
};

pub const State = struct {
    id: []const u8,
    label: ?[]const u8 = null,
    state_type: StateType = .regular,
    is_composite: bool = false,
    parent_id: ?[]const u8 = null,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    layer: ?u32 = null,

    pub fn centerX(self: *const State) i32 {
        return self.x + @as(i32, @intCast(self.width / 2));
    }

    pub fn bottom(self: *const State) i32 {
        return self.y + @as(i32, @intCast(self.height));
    }

    pub fn midY(self: *const State) i32 {
        return self.y + @as(i32, @intCast(self.height / 2));
    }
};

pub const StateTransition = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8 = null,
};

pub const StateDiagram = struct {
    allocator: Allocator,
    states: std.StringHashMap(State),
    transitions: std.ArrayList(StateTransition),
    state_order: std.ArrayList([]const u8),
    allocated_ids: std.ArrayList([]const u8),
    direction: Direction = .TD,

    pub fn init(allocator: Allocator) StateDiagram {
        return .{
            .allocator = allocator,
            .states = std.StringHashMap(State).init(allocator),
            .transitions = .empty,
            .state_order = .empty,
            .allocated_ids = .empty,
        };
    }

    pub fn deinit(self: *StateDiagram) void {
        for (self.allocated_ids.items) |id| {
            self.allocator.free(id);
        }
        self.allocated_ids.deinit(self.allocator);
        self.states.deinit();
        self.transitions.deinit(self.allocator);
        self.state_order.deinit(self.allocator);
    }

    pub fn trackAllocatedId(self: *StateDiagram, id: []const u8) !void {
        try self.allocated_ids.append(self.allocator, id);
    }

    pub fn addState(self: *StateDiagram, state: State) !void {
        const result = try self.states.getOrPut(state.id);
        if (!result.found_existing) {
            result.value_ptr.* = state;
            try self.state_order.append(self.allocator, state.id);
        } else {
            if (state.label != null and result.value_ptr.label == null) {
                result.value_ptr.label = state.label;
            }
            if (state.is_composite) {
                result.value_ptr.is_composite = true;
            }
            if (state.state_type != .regular and result.value_ptr.state_type == .regular) {
                result.value_ptr.state_type = state.state_type;
            }
        }
    }

    /// Register a state by id, leaving an existing one untouched.
    pub fn ensureState(self: *StateDiagram, id: []const u8, parent_id: ?[]const u8) !void {
        const result = try self.states.getOrPut(id);
        if (!result.found_existing) {
            result.value_ptr.* = .{ .id = id, .parent_id = parent_id };
            try self.state_order.append(self.allocator, id);
        }
    }

    pub fn addTransition(self: *StateDiagram, transition: StateTransition) !void {
        try self.transitions.append(self.allocator, transition);
    }

    pub fn getState(self: *const StateDiagram, id: []const u8) ?*const State {
        return self.states.getPtr(id);
    }

    pub fn getStateMut(self: *StateDiagram, id: []const u8) ?*State {
        return self.states.getPtr(id);
    }

    pub fn getLayerCount(self: *const StateDiagram) u32 {
        var max_layer: u32 = 0;
        var it = self.states.valueIterator();
        while (it.next()) |state| {
            if (state.layer) |l| {
                if (l > max_layer) max_layer = l;
            }
        }
        return max_layer + 1;
    }
};

test "StateDiagram basic operations" {
    const testing = std.testing;
    var diagram = StateDiagram.init(testing.allocator);
    defer diagram.deinit();

    try diagram.addState(.{ .id = "s1", .label = "State 1" });
    try diagram.addState(.{ .id = "s2", .label = "State 2" });
    try diagram.addState(.{ .id = "[*]_start", .state_type = .start });
    try diagram.addState(.{ .id = "[*]_end", .state_type = .end });

    try diagram.addTransition(.{ .from = "[*]_start", .to = "s1" });
    try diagram.addTransition(.{ .from = "s1", .to = "s2", .label = "go" });
    try diagram.addTransition(.{ .from = "s2", .to = "[*]_end" });

    try testing.expect(diagram.getState("s1") != null);
    try testing.expect(diagram.getState("s2") != null);
    try testing.expect(diagram.getState("s3") == null);
    try testing.expectEqual(@as(usize, 3), diagram.transitions.items.len);
    try testing.expectEqual(@as(usize, 4), diagram.state_order.items.len);
}
