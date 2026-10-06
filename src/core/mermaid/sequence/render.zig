const std = @import("std");
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const model = @import("model.zig");
const fit = @import("fit.zig");
const ladder = @import("../shared/ladder.zig");
const top_down = @import("tb.zig");
const left_right = @import("lr.zig");

pub fn render(allocator: Allocator, source: []const u8, max_width: u32) !ladder.Fit {
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();

    const painter = Painter{ .allocator = allocator, .diagram = &diagram };
    return ladder.firstFit(fit.ladder(diagram.direction, diagram.direction_explicit), painter, max_width);
}

const Painter = struct {
    allocator: Allocator,
    diagram: *model.SequenceDiagram,

    pub fn draw(self: Painter, spacing: fit.Spacing, max_width: u32) !ladder.Fit {
        return switch (spacing.direction orelse self.diagram.direction) {
            .LR => left_right.render(self.allocator, self.diagram, spacing, max_width),
            else => top_down.render(self.allocator, self.diagram, spacing, max_width),
        };
    }
};

const wide_self_message =
    \\sequenceDiagram
    \\    participant P as Sender
    \\    participant API as Ingest endpoint
    \\    participant DB as DataStore
    \\    participant W as Worker
    \\    P->>API: Signed request
    \\    API->>API: Validate signature and size/schema limits
    \\    API->>DB: Transaction: dedupe + minimized record + event + task
    \\    API-->>P: Acknowledge
    \\    W->>DB: Lease task
    \\    W->>P: Fetch authoritative current value when needed
    \\    W->>DB: Commit normalized value + Domain event
;

test "nothing fits: the narrowest rung's width" {
    for ([_]u32{ 78, 98 }) |max_width| {
        try std.testing.expectEqual(ladder.Fit{ .too_wide = 100 }, try render(std.testing.allocator, wide_self_message, max_width));
    }
}

test "the narrowest width draws on the tight top-down rung" {
    const allocator = std.testing.allocator;
    const fitted = try render(allocator, wide_self_message, 100);
    defer allocator.free(fitted.drawn);

    var diagram = try parse.parse(allocator, wide_self_message);
    defer diagram.deinit();
    const direct = try top_down.render(allocator, &diagram, .{ .participant = 2, .padding = 2 }, 100);
    defer allocator.free(direct.drawn);
    try std.testing.expectEqualStrings(direct.drawn, fitted.drawn);
}
