//! Final-image resolution and outer structural co-set rebuild after
//! cross-border routing.
//!
//! Outer placement carriers that touch a super-node are not final geometry.
//! One such carrier may represent zero, one, or many routed bridges;
//! `finalImages` resolves that relation for the claim rebuild (report tier).
//! Co-sets never expand across it: bridge fusion authority is the licence
//! tier's recorded verdict (cluster/bridge_plan.zig), so `rebuildOuterSets`
//! keeps only sets among surviving real-node carriers. Cell-scoped port
//! shares are excluded here: stitch derives their one final population from
//! final `EdgePath` geometry instead.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const split_mod = @import("split.zig");

pub const Image = struct {
    edge: sketch.EdgeId,
    from: sketch.NodeId,
    to: sketch.NodeId,
    kind: sketch.EdgeKind,
    arrows: [2]sketch.ArrowKind,
};

/// Every final carrier represented by one outer placement member. A surviving
/// carrier has one image. A dropped carrier expands to every matching bridge
/// that routing actually produced; absent routes produce no image.
pub fn finalImages(
    arena: std.mem.Allocator,
    sr: split_mod.SplitResult,
    outer: sketch.Sketch,
    old_edge: sketch.EdgeId,
    outer_base: sketch.EdgeId,
    bridge_base: sketch.EdgeId,
    final_edges: []const sketch.EdgePath,
    final_bridges: []const sketch.EdgePath,
    final_bars: []const sketch.Rail,
) error{OutOfMemory}![]const Image {
    const placement = endpointsOf(outer, old_edge) orelse return &.{};
    if (!isSuper(sr, placement.from) and !isSuper(sr, placement.to)) {
        const id = outer_base + old_edge;
        const image = finalImage(final_edges, final_bars, id) orelse return &.{};
        return arena.dupe(Image, &.{image});
    }

    var out: std.ArrayListUnmanaged(Image) = .empty;
    for (sr.crossings) |crossing| {
        if (outerReprOf(sr, crossing.from) != placement.from or
            outerReprOf(sr, crossing.to) != placement.to) continue;
        const id = bridge_base + crossing.id;
        const path = pathById(final_bridges, id) orelse continue;
        if (!hasImage(out.items, id)) try out.append(arena, .{
            .edge = id,
            .from = path.from,
            .to = path.to,
            .kind = path.kind,
            .arrows = .{ path.arrow_from, path.arrow_to },
        });
    }
    std.mem.sort(Image, out.items, {}, imageLess);
    return out.toOwnedSlice(arena);
}

/// Rebuild only structural outer sets. Polarity must be proven by an outer
/// claim or by a unique common placement endpoint. Final images are grouped by
/// their exact real pivot, and a group needs two distinct old contributors.
/// Members whose placement touches a super-node contribute nothing: routed
/// bridges answer to the licence tier (cluster/bridge_plan.zig), and its
/// recorded verdict — not a rebuilt set — is their fusion authority.
pub fn rebuildOuterSets(
    arena: std.mem.Allocator,
    sr: split_mod.SplitResult,
    outer: sketch.Sketch,
    outer_base: sketch.EdgeId,
    bridge_base: sketch.EdgeId,
    final_edges: []const sketch.EdgePath,
    final_bridges: []const sketch.EdgePath,
    final_bars: []const sketch.Rail,
) error{OutOfMemory}![]const ledger.CoSet {
    var out: std.ArrayListUnmanaged(ledger.CoSet) = .empty;
    for (outer.co_sets) |set| {
        if (set.origin == .port_share) continue;
        const polarity = polarityOf(outer, set) orelse continue;
        var groups: std.ArrayListUnmanaged(Group) = .empty;

        for (set.members, 0..) |old_edge, contributor| {
            if (seenEarlier(set.members, contributor, old_edge)) continue;
            if (endpointsOf(outer, old_edge)) |ep| {
                if (isSuper(sr, ep.from) or isSuper(sr, ep.to)) continue;
            }
            const images = try finalImages(
                arena,
                sr,
                outer,
                old_edge,
                outer_base,
                bridge_base,
                final_edges,
                final_bridges,
                final_bars,
            );
            for (images) |image| {
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
            std.mem.sort(sketch.EdgeId, group.members.items, {}, edgeLess);
            const rebuilt: ledger.CoSet = .{
                .origin = set.origin,
                .channel = ledger.no_channel,
                // Structural fan authority is intentionally unscoped.
                .members = try group.members.toOwnedSlice(arena),
            };
            if (!sameSetAlready(out.items, rebuilt)) try out.append(arena, rebuilt);
        }
    }
    return out.toOwnedSlice(arena);
}

const Endpoints = struct { from: sketch.NodeId, to: sketch.NodeId };

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

fn polarityOf(outer: sketch.Sketch, set: ledger.CoSet) ?ledger.RailPolarity {
    var claimed: ?ledger.RailPolarity = null;
    for (outer.rail_claims) |claim| {
        var overlap: usize = 0;
        for (set.members, 0..) |edge, i| {
            if (seenEarlier(set.members, i, edge)) continue;
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

    var first: ?Endpoints = null;
    var common_source = true;
    var common_target = true;
    var contributors: usize = 0;
    for (set.members, 0..) |edge, i| {
        if (seenEarlier(set.members, i, edge)) continue;
        const endpoints = endpointsOf(outer, edge) orelse continue;
        contributors += 1;
        if (first) |expected| {
            common_source = common_source and endpoints.from == expected.from;
            common_target = common_target and endpoints.to == expected.to;
        } else first = endpoints;
    }
    if (contributors < 2 or common_source == common_target) return null;
    return if (common_source) .out else .in;
}

fn endpointsOf(s: sketch.Sketch, id: sketch.EdgeId) ?Endpoints {
    for (s.edges) |edge| if (edge.id == id) return .{ .from = edge.from, .to = edge.to };
    for (s.rails) |bar| {
        const fan_in = bar.role == .fan_in_dropper or bar.role == .fan_in_rail;
        for (bar.taps) |tap| {
            if (tap.edge != id) continue;
            return if (fan_in)
                .{ .from = tap.node, .to = bar.pivot }
            else
                .{ .from = bar.pivot, .to = tap.node };
        }
    }
    return null;
}

fn finalImage(edges: []const sketch.EdgePath, bars: []const sketch.Rail, id: sketch.EdgeId) ?Image {
    for (edges) |edge| if (edge.id == id) return .{
        .edge = id,
        .from = edge.from,
        .to = edge.to,
        .kind = edge.kind,
        .arrows = .{ edge.arrow_from, edge.arrow_to },
    };
    for (bars) |bar| {
        const fan_in = bar.role == .fan_in_dropper or bar.role == .fan_in_rail;
        for (bar.taps) |tap| {
            if (tap.edge != id) continue;
            return if (fan_in)
                .{ .edge = id, .from = tap.node, .to = bar.pivot, .kind = bar.kind, .arrows = .{ tap.arrow, bar.pivot_arrow } }
            else
                .{ .edge = id, .from = bar.pivot, .to = tap.node, .kind = bar.kind, .arrows = .{ bar.pivot_arrow, tap.arrow } };
        }
    }
    return null;
}

fn isSuper(sr: split_mod.SplitResult, node: sketch.NodeId) bool {
    for (sr.supers) |super| if (super.outer_node == node) return true;
    return false;
}

fn outerReprOf(sr: split_mod.SplitResult, original: sg.NodeId) sketch.NodeId {
    for (sr.supers) |super| {
        for (sr.pieces[super.child_piece].orig_ids) |id| if (id == original) return super.outer_node;
    }
    for (sr.pieces[0].orig_ids, 0..) |id, i| if (id == original) return @intCast(i);
    return sg.SENTINEL;
}

fn pathById(paths: []const sketch.EdgePath, id: sketch.EdgeId) ?sketch.EdgePath {
    for (paths) |path| if (path.id == id) return path;
    return null;
}

fn seenEarlier(items: []const sketch.EdgeId, at: usize, id: sketch.EdgeId) bool {
    for (items[0..at]) |prior| if (prior == id) return true;
    return false;
}

fn contains(items: []const sketch.EdgeId, id: sketch.EdgeId) bool {
    for (items) |item| if (item == id) return true;
    return false;
}

fn hasImage(items: []const Image, id: sketch.EdgeId) bool {
    for (items) |item| if (item.edge == id) return true;
    return false;
}

fn sameSetAlready(sets: []const ledger.CoSet, candidate: ledger.CoSet) bool {
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

fn imageLess(_: void, a: Image, b: Image) bool {
    return a.edge < b.edge;
}

fn groupLess(_: void, a: Group, b: Group) bool {
    if (a.pivot != b.pivot) return a.pivot < b.pivot;
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return @intFromEnum(a.arrow) < @intFromEnum(b.arrow);
}

fn edgeLess(_: void, a: sketch.EdgeId, b: sketch.EdgeId) bool {
    return a < b;
}
