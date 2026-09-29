const std = @import("std");
const sg = @import("../sem_graph.zig");

pub const MotifKind = enum { atom, spine, fan, parallel, cluster, prime };

pub const Motif = struct {
    kind: MotifKind,
    members: []const sg.NodeId,
    entry: ?sg.NodeId,
    cluster_id: ?sg.ClusterId,
    children: []const usize,
    branches: []const []const sg.NodeId = &.{},
};

pub const MotifTree = struct {
    motifs: []const Motif,
    roots: []const usize,
};
