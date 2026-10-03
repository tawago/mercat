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
    labeled: bool = false,
};
