const std = @import("std");
const model = @import("model.zig");
const state_layout = @import("layout.zig");

const StateLayout = state_layout.StateLayout;

test "state layout simple" {
    const testing = std.testing;
    const parse = @import("parse.zig");

    const source =
        \\stateDiagram-v2
        \\    [*] --> s1
        \\    s1 --> s2
        \\    s2 --> [*]
    ;

    var diagram = try parse.parse(testing.allocator, source);
    defer diagram.deinit();

    var layout_obj = StateLayout.init(testing.allocator, &diagram);
    defer layout_obj.deinit();

    try layout_obj.run();

    var start: ?model.State = null;
    var end: ?model.State = null;

    for (diagram.state_order.items) |id| {
        if (diagram.getState(id)) |state| {
            if (state.state_type == .start) {
                start = state.*;
            } else if (state.state_type == .end) {
                end = state.*;
            }
        }
    }

    try testing.expect(start.?.layer.? < end.?.layer.?);
    try testing.expect(start.?.y < end.?.y);
}
