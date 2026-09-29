const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");

pub const Arrival = struct { to: sg.NodeId, side: sketch.Dir4 };

pub const Departure = struct { from: sg.NodeId, side: sketch.Dir4 };

pub const Inherited = struct {
    arrivals: []const Arrival = &.{},
    departures: []const Departure = &.{},
};

pub fn exitSide(dir: sg.Direction) sketch.Dir4 {
    return switch (dir) {
        .TD => .south,
        .BT => .north,
        .LR => .east,
        .RL => .west,
    };
}

pub fn entrySide(dir: sg.Direction) sketch.Dir4 {
    return switch (dir) {
        .TD => .north,
        .BT => .south,
        .LR => .west,
        .RL => .east,
    };
}
