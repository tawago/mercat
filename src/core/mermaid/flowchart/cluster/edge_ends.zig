const sketch = @import("../sketch.zig");

pub const Ends = struct {
    edge: sketch.EdgeId,
    from: sketch.NodeId,
    to: sketch.NodeId,
    kind: sketch.EdgeKind,
    arrows: [2]sketch.ArrowKind,
};

pub fn isFanIn(rail: sketch.Rail) bool {
    return rail.role == .fan_in_dropper or rail.role == .fan_in_rail;
}

pub fn ofPath(path: sketch.EdgePath) Ends {
    return .{ .edge = path.id, .from = path.from, .to = path.to, .kind = path.kind, .arrows = .{ path.arrow_from, path.arrow_to } };
}

pub fn ofTap(rail: sketch.Rail, tap: sketch.Tap) Ends {
    return if (isFanIn(rail))
        .{ .edge = tap.edge, .from = tap.node, .to = rail.pivot, .kind = rail.kind, .arrows = .{ tap.arrow, rail.pivot_arrow } }
    else
        .{ .edge = tap.edge, .from = rail.pivot, .to = tap.node, .kind = rail.kind, .arrows = .{ rail.pivot_arrow, tap.arrow } };
}

pub fn find(edges: []const sketch.EdgePath, rails: []const sketch.Rail, id: sketch.EdgeId) ?Ends {
    for (edges) |path| {
        if (path.id == id) return ofPath(path);
    }
    for (rails) |rail| {
        for (rail.taps) |tap| {
            if (tap.edge == id) return ofTap(rail, tap);
        }
    }
    return null;
}

test {
    _ = @import("edge_ends_test.zig");
}
