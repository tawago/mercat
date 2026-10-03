const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const bridge_types = @import("bridge_types.zig");

pub const Crossing = bridge_types.Crossing;

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

pub const Piece = struct {
    graph: sg.SemGraph,
    cluster_id: ?sg.ClusterId,
    orig_ids: []const sg.NodeId,
};

pub const SuperNode = struct {
    outer_node: sg.NodeId,
    cluster_id: sg.ClusterId,
    child_piece: usize,
    synthetic: bool = false,
};

pub const SplitResult = struct {
    pieces: []const Piece,
    supers: []const SuperNode,
    crossings: []const Crossing,
    arrivals: []const Arrival,
    departures: []const Departure,
    orig_node_count: usize,

    pub fn childArrivals(self: SplitResult, arena: std.mem.Allocator, piece_idx: usize) error{OutOfMemory}![]const Arrival {
        var out: std.ArrayListUnmanaged(Arrival) = .empty;
        for (self.arrivals) |a| {
            for (self.pieces[piece_idx].orig_ids, 0..) |o, i| {
                if (o == a.to) try out.append(arena, .{ .to = @intCast(i), .side = a.side });
            }
        }
        return out.toOwnedSlice(arena);
    }

    pub fn childDepartures(self: SplitResult, arena: std.mem.Allocator, piece_idx: usize) error{OutOfMemory}![]const Departure {
        var out: std.ArrayListUnmanaged(Departure) = .empty;
        for (self.departures) |d| {
            for (self.pieces[piece_idx].orig_ids, 0..) |o, i| {
                if (o == d.from) try out.append(arena, .{ .from = @intCast(i), .side = d.side });
            }
        }
        return out.toOwnedSlice(arena);
    }

    pub fn childInherited(self: SplitResult, arena: std.mem.Allocator, piece_idx: usize) error{OutOfMemory}!Inherited {
        return .{ .arrivals = try self.childArrivals(arena, piece_idx), .departures = try self.childDepartures(arena, piece_idx) };
    }

    pub fn isFlat(self: SplitResult) bool {
        return self.pieces.len == 1 and self.supers.len == 0;
    }

    pub fn superIndex(self: SplitResult, outer_node: sg.NodeId) ?usize {
        for (self.supers, 0..) |s, i| {
            if (s.outer_node == outer_node) return i;
        }
        return null;
    }

    pub fn isSuper(self: SplitResult, outer_node: sg.NodeId) bool {
        return self.superIndex(outer_node) != null;
    }
};

pub fn split(arena: std.mem.Allocator, graph: sg.SemGraph, inherited: Inherited) error{OutOfMemory}!SplitResult {
    if (cuttable(graph)) return cut(arena, graph, inherited);
    return identity(arena, graph, inherited);
}

fn identity(arena: std.mem.Allocator, graph: sg.SemGraph, inherited: Inherited) error{OutOfMemory}!SplitResult {
    const pieces = try arena.alloc(Piece, 1);
    pieces[0] = .{ .graph = graph, .cluster_id = null, .orig_ids = &.{} };
    return .{ .pieces = pieces, .supers = &.{}, .crossings = &.{}, .arrivals = inherited.arrivals, .departures = inherited.departures, .orig_node_count = graph.nodes.len };
}

fn cuttable(graph: sg.SemGraph) bool {
    for (graph.clusters) |c| {
        if (c.parent == null) return true;
    }
    return false;
}

fn parentOf(graph: sg.SemGraph, cid: sg.ClusterId) ?sg.ClusterId {
    for (graph.clusters) |c| {
        if (c.id == cid) return c.parent;
    }
    return null;
}

fn topAncestor(graph: sg.SemGraph, cid: sg.ClusterId) sg.ClusterId {
    var cur = cid;
    while (parentOf(graph, cur)) |p| cur = p;
    return cur;
}

fn isDescendant(graph: sg.SemGraph, d: sg.ClusterId, anc: sg.ClusterId) bool {
    if (d == anc) return false;
    var cur: ?sg.ClusterId = d;
    while (cur) |c| : (cur = parentOf(graph, c)) {
        if (c == anc) return true;
    }
    return false;
}

fn inSubtree(graph: sg.SemGraph, id: sg.NodeId, c: sg.ClusterId) bool {
    const nc = graph.clusterOf(id) orelse return false;
    return nc == c or isDescendant(graph, nc, c);
}

fn topClusterOf(graph: sg.SemGraph, id: sg.NodeId) ?sg.ClusterId {
    const nc = graph.clusterOf(id) orelse return null;
    return topAncestor(graph, nc);
}

fn cut(arena: std.mem.Allocator, graph: sg.SemGraph, inherited: Inherited) error{OutOfMemory}!SplitResult {
    var tops: std.ArrayListUnmanaged(usize) = .empty;
    for (graph.clusters, 0..) |c, ci| {
        if (c.parent == null) try tops.append(arena, ci);
    }
    const ntop = tops.items.len;

    const pieces = try arena.alloc(Piece, ntop + 1);
    const supers = try arena.alloc(SuperNode, ntop);

    for (tops.items, 0..) |ci, k| {
        pieces[k + 1] = try buildChild(arena, graph, graph.clusters[ci]);
        supers[k] = .{
            .outer_node = undefined,
            .cluster_id = graph.clusters[ci].id,
            .child_piece = k + 1,
            .synthetic = graph.clusters[ci].synthetic,
        };
    }

    const ob = try buildOuter(arena, graph, tops.items, supers);
    pieces[0] = ob.piece;

    var arrivals: std.ArrayListUnmanaged(Arrival) = .empty;
    try arrivals.appendSlice(arena, inherited.arrivals);
    var departures: std.ArrayListUnmanaged(Departure) = .empty;
    try departures.appendSlice(arena, inherited.departures);
    for (ob.crossings) |c| {
        if (c.arrow_to != .none) try arrivals.append(arena, .{ .to = c.to, .side = entrySide(graph.direction) });
        if (topClusterOf(graph, c.from) != null) try departures.append(arena, .{ .from = c.from, .side = exitSide(graph.direction) });
    }

    return .{
        .pieces = pieces,
        .supers = supers,
        .crossings = ob.crossings,
        .arrivals = try arrivals.toOwnedSlice(arena),
        .departures = try departures.toOwnedSlice(arena),
        .orig_node_count = graph.nodes.len,
    };
}

const OuterBuild = struct { piece: Piece, crossings: []const Crossing };

fn buildChild(arena: std.mem.Allocator, graph: sg.SemGraph, c: sg.Cluster) error{OutOfMemory}!Piece {
    var ids: std.ArrayListUnmanaged(sg.NodeId) = .empty;
    for (c.members) |mid| try ids.append(arena, mid);
    for (graph.nodes) |n| {
        const nc = n.cluster orelse continue;
        if (nc != c.id and isDescendant(graph, nc, c.id)) try ids.append(arena, n.id);
    }
    const k = ids.items.len;

    const nodes = try arena.alloc(sg.Node, k);
    const orig = try arena.alloc(sg.NodeId, k);
    for (ids.items, 0..) |oid, new_id| {
        const src = graph.nodeById(oid) orelse graph.nodes[0];
        orig[new_id] = oid;
        nodes[new_id] = pieceNode(src, @intCast(new_id), withoutRoot(src.cluster, c.id));
    }

    var child_clusters: std.ArrayListUnmanaged(sg.Cluster) = .empty;
    for (graph.clusters) |d| {
        if (!isDescendant(graph, d.id, c.id)) continue;
        const new_members = try arena.alloc(sg.NodeId, d.members.len);
        for (d.members, 0..) |m, i| new_members[i] = localId(orig, m);
        try child_clusters.append(arena, .{
            .id = d.id,
            .raw_id = d.raw_id,
            .label = d.label,
            .parent = withoutRoot(d.parent, c.id),
            .members = new_members,
            .sub_clusters = d.sub_clusters,
            .direction = d.direction,
            .synthetic = d.synthetic,
        });
    }

    var edges: std.ArrayListUnmanaged(sg.Edge) = .empty;
    for (graph.edges) |e| {
        if (inSubtree(graph, e.from, c.id) and inSubtree(graph, e.to, c.id)) {
            try edges.append(arena, pieceEdge(e, @intCast(edges.items.len), localId(orig, e.from), localId(orig, e.to)));
        }
    }

    const child_graph: sg.SemGraph = .{
        .direction = c.direction orelse graph.direction,
        .nodes = nodes,
        .edges = try edges.toOwnedSlice(arena),
        .clusters = try child_clusters.toOwnedSlice(arena),
        .classes = graph.classes,
        .arena = null,
    };
    return .{ .graph = child_graph, .cluster_id = c.id, .orig_ids = orig };
}

fn buildOuter(arena: std.mem.Allocator, graph: sg.SemGraph, tops: []const usize, supers: []SuperNode) error{OutOfMemory}!OuterBuild {
    var nodes: std.ArrayListUnmanaged(sg.Node) = .empty;
    var orig: std.ArrayListUnmanaged(sg.NodeId) = .empty;

    for (graph.nodes) |n| {
        if (n.cluster != null) continue;
        try orig.append(arena, n.id);
        try nodes.append(arena, pieceNode(n, @intCast(nodes.items.len), null));
    }

    for (tops, 0..) |ci, k| {
        const c = graph.clusters[ci];
        const super_id: sg.NodeId = @intCast(nodes.items.len);
        try orig.append(arena, sg.SENTINEL);
        try nodes.append(arena, .{
            .id = super_id,
            .raw_id = c.raw_id,
            .label = c.label,
            .shape = .rect,
            .classes = &.{},
            .cluster = null,
        });
        supers[k].outer_node = super_id;
    }

    var edges: std.ArrayListUnmanaged(sg.Edge) = .empty;
    var crossings: std.ArrayListUnmanaged(Crossing) = .empty;
    var seen: std.ArrayListUnmanaged(SeenPair) = .empty;

    for (graph.edges) |e| {
        const fa = topClusterOf(graph, e.from);
        const ta = topClusterOf(graph, e.to);
        if (fa == null and ta == null) {
            try edges.append(arena, pieceEdge(e, @intCast(edges.items.len), localId(orig.items, e.from), localId(orig.items, e.to)));
        } else if (sameCluster(fa, ta)) {} else {
            try crossings.append(arena, .{
                .id = @intCast(crossings.items.len),
                .from = e.from,
                .to = e.to,
                .kind = e.kind,
                .arrow_from = e.arrow_from,
                .arrow_to = e.arrow_to,
                .label = e.label,
                .origin = originOf(e),
            });
            const rf = outerRepr(graph, supers, orig.items, e.from);
            const rt = outerRepr(graph, supers, orig.items, e.to);
            if (rf == rt) continue;
            const class = sg.standsForClass(e.arrow_from, e.arrow_to);
            if (seenIndex(seen.items, rf, rt)) |at| {
                edges.items[at].stands_for =
                    sg.mergeStandsFor(edges.items[at].stands_for, class);
                edges.items[at].crossings += 1;
                continue;
            }
            try seen.append(arena, .{ .from = rf, .to = rt, .edge = @intCast(edges.items.len) });
            try edges.append(arena, .{
                .id = @intCast(edges.items.len),
                .from = rf,
                .to = rt,
                .kind = e.kind,
                .arrow_from = .none,
                .arrow_to = .none,
                .label = null,
                .stands_for = class,
                .crossings = 1,
            });
        }
    }

    const outer_graph: sg.SemGraph = .{
        .direction = graph.direction,
        .nodes = try nodes.toOwnedSlice(arena),
        .edges = try edges.toOwnedSlice(arena),
        .clusters = &.{},
        .classes = graph.classes,
        .arena = null,
    };
    return .{
        .piece = .{ .graph = outer_graph, .cluster_id = null, .orig_ids = try orig.toOwnedSlice(arena) },
        .crossings = try crossings.toOwnedSlice(arena),
    };
}

fn sameCluster(a: ?sg.ClusterId, b: ?sg.ClusterId) bool {
    return a != null and b != null and a.? == b.?;
}

fn originOf(e: sg.Edge) sg.EdgeId {
    return if (e.origin == sg.SENTINEL) e.id else e.origin;
}

fn withoutRoot(cluster: ?sg.ClusterId, root: sg.ClusterId) ?sg.ClusterId {
    return if (cluster == root) null else cluster;
}

fn pieceNode(src: sg.Node, id: sg.NodeId, cluster: ?sg.ClusterId) sg.Node {
    return .{ .id = id, .raw_id = src.raw_id, .label = src.label, .shape = src.shape, .classes = src.classes, .cluster = cluster };
}

fn pieceEdge(e: sg.Edge, id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .kind = e.kind,
        .arrow_from = e.arrow_from,
        .arrow_to = e.arrow_to,
        .label = e.label,
        .stands_for = e.stands_for,
        .origin = originOf(e),
    };
}

const SeenPair = struct { from: sg.NodeId, to: sg.NodeId, edge: u32 };

fn seenIndex(seen: []const SeenPair, f: sg.NodeId, t: sg.NodeId) ?u32 {
    for (seen) |p| {
        if (p.from == f and p.to == t) return p.edge;
    }
    return null;
}

fn outerRepr(graph: sg.SemGraph, supers: []const SuperNode, orig: []const sg.NodeId, id: sg.NodeId) sg.NodeId {
    if (topClusterOf(graph, id)) |cid| {
        for (supers) |s| {
            if (s.cluster_id == cid) return s.outer_node;
        }
    }
    return localId(orig, id);
}

fn localId(orig: []const sg.NodeId, original: sg.NodeId) sg.NodeId {
    for (orig, 0..) |o, i| {
        if (o == original) return @intCast(i);
    }
    return 0;
}

pub fn pieceId(piece_orig_ids: []const sg.NodeId, child_input_of: []const sketch.NodeId, sketch_id: sketch.NodeId) sketch.NodeId {
    const child_graph_id = idAt(child_input_of, sketch_id);
    return idAt(piece_orig_ids, child_graph_id);
}

pub fn idAt(map: []const sketch.NodeId, i: sketch.NodeId) sketch.NodeId {
    if (i == sg.SENTINEL or i >= map.len) return sg.SENTINEL;
    return map[i];
}
