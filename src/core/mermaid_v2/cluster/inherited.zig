//! cluster/inherited.zig — the records one cut hands the cuts below it:
//! the decorated ends that arrive at a piece's nodes from outside, and the
//! nodes whose cross-border edges depart toward the flow. Pure data.
//!
//! Imports: sem_graph + sketch.

const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");

/// A decorated edge end that lands on a node of one of this cut's pieces while
/// the edge itself is absent from that piece's graph: a crossing this cut
/// recorded, or one a cut above it recorded and handed down. `to` is an id of
/// the graph that was cut; `side` is the frame side the edge enters, fixed by
/// the flow direction of the graph whose cut recorded it (the level that
/// routes it). `SplitResult.childArrivals` carries the record down every
/// nesting level, so a cluster at any depth learns which of its members
/// receive an arrowhead from outside.
pub const Arrival = struct { to: sg.NodeId, side: sketch.Dir4 };

/// A cross-border edge end that leaves a node of one of this cut's pieces:
/// the bridge routed above this piece departs that node, and where it must
/// corridor past a box the piece stacked under it, it jogs in the row under
/// the node — a row the piece's ledger reserves (`layout/gap_rows.zig`).
pub const Departure = struct { from: sg.NodeId, side: sketch.Dir4 };

/// The records a cut above handed down: empty at the root.
pub const Inherited = struct {
    arrivals: []const Arrival = &.{},
    departures: []const Departure = &.{},
};

/// The frame side a cross-border edge leaves under flow direction `dir`.
pub fn exitSide(dir: sg.Direction) sketch.Dir4 {
    return switch (dir) {
        .TD => .south,
        .BT => .north,
        .LR => .east,
        .RL => .west,
    };
}

/// The frame side a cross-border edge enters under flow direction `dir`.
pub fn entrySide(dir: sg.Direction) sketch.Dir4 {
    return switch (dir) {
        .TD => .north,
        .BT => .south,
        .LR => .west,
        .RL => .east,
    };
}
