const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const rail_star = @import("../base/rail_star.zig");
const bundle_mod = @import("../base/bundle.zig");
const split_mod = @import("split.zig");
const edge_ends = @import("edge_ends.zig");
const Final = @import("final_scene.zig").Final;

pub fn finalImages(arena: std.mem.Allocator, fin: Final, old_edge: sketch.EdgeId) error{OutOfMemory}![]const edge_ends.Ends {
    const placement = edge_ends.find(fin.outer.edges, fin.outer.rails, old_edge) orelse return &.{};
    if (!fin.sr.isSuper(placement.from) and !fin.sr.isSuper(placement.to)) {
        const id = fin.outer_base + old_edge;
        const image = edge_ends.find(fin.paths, fin.rails, id) orelse return &.{};
        return arena.dupe(edge_ends.Ends, &.{image});
    }

    var out: std.ArrayListUnmanaged(edge_ends.Ends) = .empty;
    for (fin.sr.crossings) |crossing| {
        if (outerReprOf(fin.sr, crossing.from) != placement.from or
            outerReprOf(fin.sr, crossing.to) != placement.to) continue;
        const id = fin.bridge_base + crossing.id;
        const path = sketch.pathById(fin.bridges, id) orelse continue;
        if (!hasImage(out.items, id)) try out.append(arena, edge_ends.ofPath(path));
    }
    std.mem.sort(edge_ends.Ends, out.items, {}, imageLess);
    return out.toOwnedSlice(arena);
}

pub fn rebuildOuterSets(arena: std.mem.Allocator, fin: Final) error{OutOfMemory}![]const bundle_mod.Bundle {
    const outer = fin.outer;
    var out: std.ArrayListUnmanaged(bundle_mod.Bundle) = .empty;
    for (outer.sharing.bundles) |set| {
        if (set.origin == .port_share) continue;
        const polarity = polarityOf(outer, set) orelse continue;
        var groups: std.ArrayListUnmanaged(Group) = .empty;

        for (set.members, 0..) |old_edge, contributor| {
            if (contains(set.members[0..contributor], old_edge)) continue;
            if (edge_ends.find(outer.edges, outer.rails, old_edge)) |ep| {
                if (fin.sr.isSuper(ep.from) or fin.sr.isSuper(ep.to)) continue;
            }
            for (try finalImages(arena, fin, old_edge)) |image| {
                const pivot = if (polarity == .out) image.from else image.to;
                const pivot_end = polarity.pivotEnd();
                const group = try groupFor(arena, &groups, pivot, image.kind, image.arrows[pivot_end.index()]);
                if (!contains(group.members.items, image.edge)) try group.members.append(arena, image.edge);
                if (!contains(group.contributors.items, old_edge)) try group.contributors.append(arena, old_edge);
            }
        }

        std.mem.sort(Group, groups.items, {}, groupLess);
        for (groups.items) |*group| {
            if (group.members.items.len < 2 or group.contributors.items.len < 2) continue;
            std.mem.sort(sketch.EdgeId, group.members.items, {}, std.sort.asc(sketch.EdgeId));
            const rebuilt: bundle_mod.Bundle = .{
                .origin = set.origin,
                .members = try group.members.toOwnedSlice(arena),
            };
            if (!sameSetAlready(out.items, rebuilt)) try out.append(arena, rebuilt);
        }
    }
    return out.toOwnedSlice(arena);
}

const Group = struct {
    pivot: sketch.NodeId,
    kind: sketch.EdgeKind,
    arrow: sketch.ArrowKind,
    members: std.ArrayListUnmanaged(sketch.EdgeId) = .empty,
    contributors: std.ArrayListUnmanaged(sketch.EdgeId) = .empty,
};

fn groupFor(
    arena: std.mem.Allocator,
    groups: *std.ArrayListUnmanaged(Group),
    pivot: sketch.NodeId,
    kind: sketch.EdgeKind,
    arrow: sketch.ArrowKind,
) error{OutOfMemory}!*Group {
    for (groups.items) |*group| {
        if (group.pivot == pivot and group.kind == kind and group.arrow == arrow) return group;
    }
    try groups.append(arena, .{ .pivot = pivot, .kind = kind, .arrow = arrow });
    return &groups.items[groups.items.len - 1];
}

fn polarityOf(outer: sketch.Sketch, set: bundle_mod.Bundle) ?rail_star.RailPolarity {
    var claimed: ?rail_star.RailPolarity = null;
    for (outer.sharing.claims) |claim| {
        var overlap: usize = 0;
        for (set.members, 0..) |edge, i| {
            if (contains(set.members[0..i], edge)) continue;
            for (claim.members) |member| {
                if (member.edge == edge and member.pivot_end == claim.polarity.pivotEnd()) {
                    overlap += 1;
                    break;
                }
            }
        }
        if (overlap < 2) continue;
        if (claimed != null and claimed.? != claim.polarity) return null;
        claimed = claim.polarity;
    }
    if (claimed) |polarity| return polarity;

    var first: ?edge_ends.Ends = null;
    var common_source = true;
    var common_target = true;
    var contributors: usize = 0;
    for (set.members, 0..) |edge, i| {
        if (contains(set.members[0..i], edge)) continue;
        const endpoints = edge_ends.find(outer.edges, outer.rails, edge) orelse continue;
        contributors += 1;
        if (first) |expected| {
            common_source = common_source and endpoints.from == expected.from;
            common_target = common_target and endpoints.to == expected.to;
        } else first = endpoints;
    }
    if (contributors < 2 or common_source == common_target) return null;
    return if (common_source) .out else .in;
}

fn outerReprOf(sr: split_mod.SplitResult, original: sg.NodeId) sketch.NodeId {
    for (sr.supers) |super| {
        for (sr.pieces[super.child_piece].orig_ids) |id| if (id == original) return super.outer_node;
    }
    for (sr.pieces[0].orig_ids, 0..) |id, i| if (id == original) return @intCast(i);
    return sg.SENTINEL;
}

fn contains(items: []const sketch.EdgeId, id: sketch.EdgeId) bool {
    return std.mem.indexOfScalar(sketch.EdgeId, items, id) != null;
}

fn hasImage(items: []const edge_ends.Ends, id: sketch.EdgeId) bool {
    for (items) |item| if (item.edge == id) return true;
    return false;
}

fn sameSetAlready(sets: []const bundle_mod.Bundle, candidate: bundle_mod.Bundle) bool {
    for (sets) |set| {
        if (set.origin != candidate.origin or set.members.len != candidate.members.len) continue;
        var same = true;
        for (candidate.members) |member| {
            if (!contains(set.members, member)) same = false;
        }
        if (same) return true;
    }
    return false;
}

fn imageLess(_: void, a: edge_ends.Ends, b: edge_ends.Ends) bool {
    return a.edge < b.edge;
}

fn groupLess(_: void, a: Group, b: Group) bool {
    if (a.pivot != b.pivot) return a.pivot < b.pivot;
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return @intFromEnum(a.arrow) < @intFromEnum(b.arrow);
}
