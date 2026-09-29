const sg = @import("../sem_graph.zig");

const NodeId = sg.NodeId;
const ClusterId = sg.ClusterId;

pub const ClusterEndpointRole = enum { source, target };

pub fn nodeInCluster(
    nodes: anytype,
    clusters: anytype,
    nid: NodeId,
    cid: ClusterId,
) bool {
    var cur: ?ClusterId = nodes[nid].cluster;
    while (cur) |member_cid| {
        if (member_cid == cid) return true;
        cur = clusters[member_cid].parent;
    }
    return false;
}

fn hasInternalOutgoing(
    nodes: anytype,
    clusters: anytype,
    edges: anytype,
    nid: NodeId,
    cid: ClusterId,
) bool {
    for (edges) |edge| {
        if (edge.from == nid and nodeInCluster(nodes, clusters, edge.to, cid)) return true;
    }
    return false;
}

fn hasInternalIncoming(
    nodes: anytype,
    clusters: anytype,
    edges: anytype,
    nid: NodeId,
    cid: ClusterId,
) bool {
    for (edges) |edge| {
        if (edge.to == nid and nodeInCluster(nodes, clusters, edge.from, cid)) return true;
    }
    return false;
}

pub fn clusterRepresentative(
    nodes: anytype,
    clusters: anytype,
    edges: anytype,
    cid: ClusterId,
    role: ClusterEndpointRole,
) error{InvalidNode}!NodeId {
    var fallback: ?NodeId = null;
    var best: ?NodeId = null;
    for (nodes) |node| {
        if (!nodeInCluster(nodes, clusters, node.id, cid)) continue;
        switch (role) {
            .source => {
                fallback = node.id;
                if (!hasInternalOutgoing(nodes, clusters, edges, node.id, cid)) best = node.id;
            },
            .target => {
                if (fallback == null) fallback = node.id;
                if (best == null and !hasInternalIncoming(nodes, clusters, edges, node.id, cid)) best = node.id;
            },
        }
    }
    return best orelse fallback orelse error.InvalidNode;
}
