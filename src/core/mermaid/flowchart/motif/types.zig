const std = @import("std");
const sg = @import("../sem_graph.zig");

/// guarded-by: motif/motif_test.zig "diamond classifies as fan (documented choice)"
pub const MotifKind = enum { atom, spine, fan, parallel, cluster, prime };

pub const Motif = struct {
    kind: MotifKind,
    members: []const sg.NodeId,
    entry: ?sg.NodeId,
    cluster_id: ?sg.ClusterId,
    ext_in: u32,
    ext_out: u32,
    covered: u32,
    children: []const usize,
    branches: []const []const sg.NodeId = &.{},
};

pub const MotifTree = struct {
    motifs: []const Motif,
    roots: []const usize,
    node_count: usize,
};
