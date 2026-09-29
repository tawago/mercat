const sg = @import("../sem_graph.zig");

pub const Direction = enum { out, in };

pub const ChildRole = enum {
    leftmost,
    rightmost,
    middle,
    center,
};

pub const FanEdge = struct {
    edge_id: sg.EdgeId,
    peer_idx: u32,
    role: ChildRole,
    lane: u32 = 0,
    shared: bool = true,
    label_width: u32 = 0,
    long: bool = false,
};

pub const Fan = struct {
    direction: Direction,
    pivot: sg.NodeId = 0,
    pivot_idx: u32,
    source_layer: u32,
    peers: []FanEdge,
    rows: u32 = 1,
    lane: u32 = 0,
    /// @guarded-by: gap_rows_test.zig "a labeled fan claims its rail row and one label band; an unlabeled fan claims one row"
    /// @guarded-by: gap_rows_test.zig "a fan-OUT with three labeled members claims the same rows as one with a single labeled member"
    labeled: bool = false,
};
