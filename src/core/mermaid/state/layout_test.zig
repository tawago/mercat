const std = @import("std");
const state_layout = @import("layout.zig");

const StateLayout = state_layout.StateLayout;

test "state layout simple" {
    const testing = std.testing;
    const parser = @import("../parser.zig");

    const source =
        \\stateDiagram-v2
        \\    [*] --> s1
        \\    s1 --> s2
        \\    s2 --> [*]
    ;

    var diagram = try parser.Parser.parseStateDiagram(testing.allocator, source);
    defer diagram.deinit();

    var layout_obj = StateLayout.init(testing.allocator, &diagram, .{});
    defer layout_obj.deinit();

    try layout_obj.run();

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

    for (diagram.state_order.items) |id| {
        const state = diagram.getState(id).?;
        try testing.expect(state.x != null);
        try testing.expect(state.y != null);
    }
}
