const std = @import("std");
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const model = @import("model.zig");
const fit = @import("fit.zig");
const ladder = @import("../shared/ladder.zig");
const top_down = @import("tb.zig");
const left_right = @import("lr.zig");
const top_down_wrapped = @import("tb_wrap.zig");

pub fn render(allocator: Allocator, source: []const u8, max_width: u32) !ladder.Fit {
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();

    const painter = Painter{ .allocator = allocator, .diagram = &diagram };
    return ladder.firstFit(fit.ladder(diagram.direction, diagram.direction_explicit), painter, max_width);
}

pub const Painter = struct {
    allocator: Allocator,
    diagram: *model.SequenceDiagram,

    pub fn draw(self: Painter, spacing: fit.Spacing, max_width: u32) !ladder.Fit {
        if (spacing.wrap) {
            return top_down_wrapped.render(self.allocator, self.diagram, spacing, max_width) catch |err| switch (err) {
                error.OutOfMemory => err,
                else => .{ .too_wide = std.math.maxInt(u32) },
            };
        }
        return switch (spacing.direction orelse self.diagram.direction) {
            .LR => left_right.render(self.allocator, self.diagram, spacing, max_width),
            else => top_down.render(self.allocator, self.diagram, spacing, max_width),
        };
    }
};

pub const wide_self_message =
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

test {
    _ = @import("tb_wrap_test.zig");
}
