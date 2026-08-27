//! Rebuild stitched RailClaims from final carriers.
//!
//! Transported outer members use shifted placement ids as pending keys. This
//! pass expands those keys through final routed bridges, rebuilds facts from
//! final paths or rails, splits on exact real pivots, and derives bridge-native
//! claims only from a shared final endpoint and attachment site.

const std = @import("std");
const sketch = @import("../sketch.zig");
const sketch_ports = @import("../sketch_ports.zig");
const ledger = @import("../base/ledger.zig");
const split_mod = @import("split.zig");
const bridge_cosets = @import("bridge_cosets.zig");
const stitch_rails = @import("stitch_rails.zig");

pub fn rebuild(
    arena: std.mem.Allocator,
    sr: split_mod.SplitResult,
    outer: sketch.Sketch,
    transported: []const ledger.RailClaim,
    outer_base: sketch.EdgeId,
    bridge_base: sketch.EdgeId,
    paths: []const sketch.EdgePath,
    bridges: []const sketch.EdgePath,
    bars: []const sketch.Rail,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]const ledger.RailClaim {
    var out: std.ArrayListUnmanaged(ledger.RailClaim) = .empty;
    for (transported) |claim| {
        var groups: std.ArrayListUnmanaged(Group) = .empty;
        var pending: std.ArrayListUnmanaged(Pending) = .empty;
        for (claim.members) |source| {
            if (source.edge >= outer_base and source.edge < bridge_base) {
                const old_edge = source.edge - outer_base;
                const images = try bridge_cosets.finalImages(
                    arena,
                    sr,
                    outer,
                    old_edge,
                    outer_base,
                    bridge_base,
                    paths,
                    bridges,
                    bars,
                );
                if (images.len == 0) {
                    var unresolved = source;
                    unresolved.pivot_end = claim.polarity.pivotEnd();
                    unresolved.sites = .{ null, null };
                    try pending.append(arena, .{ .member = unresolved, .contributor = old_edge });
                    continue;
                }
                for (images) |image| {
                    const member = stitch_rails.finalMember(paths, bars, placements, image.edge, claim.polarity.pivotEnd()) orelse continue;
                    try addCandidate(arena, &groups, member, old_edge);
                }
            } else {
                const member = stitch_rails.finalMember(paths, bars, placements, source.edge, claim.polarity.pivotEnd()) orelse source;
                try addCandidate(arena, &groups, member, source.edge);
            }
        }

        for (pending.items) |item| try addPending(arena, &groups, item);

        std.mem.sort(Group, groups.items, {}, groupLess);
        for (groups.items) |*group| {
            if (group.members.items.len < 2 or group.contributors.items.len < 2) continue;
            try appendClaim(arena, &out, claim.polarity, group.members.items);
        }
    }

    try appendNative(arena, &out, bridges, paths, bars, placements);
    for (out.items, 1..) |*claim, id| claim.id = @intCast(id);
    return out.toOwnedSlice(arena);
}

const Group = struct {
    pivot: ?sketch.NodeId,
    pi: ?ledger.AttachmentSite,
    kind: sketch.EdgeKind,
    arrow: sketch.ArrowKind,
    members: std.ArrayListUnmanaged(ledger.RailClaimMember) = .empty,
    contributors: std.ArrayListUnmanaged(sketch.EdgeId) = .empty,
};

const Pending = struct {
    member: ledger.RailClaimMember,
    contributor: sketch.EdgeId,
};

fn addCandidate(
    arena: std.mem.Allocator,
    groups: *std.ArrayListUnmanaged(Group),
    member: ledger.RailClaimMember,
    contributor: sketch.EdgeId,
) error{OutOfMemory}!void {
    const pivot = member.node(member.pivot_end);
    const pi = member.site(member.pivot_end);
    const arrow = member.arrow(member.pivot_end);
    var group: *Group = undefined;
    for (groups.items) |*item| {
        if (item.pivot == pivot and optionalSiteEqual(item.pi, pi) and
            item.kind == member.kind and item.arrow == arrow)
        {
            group = item;
            break;
        }
    } else {
        try groups.append(arena, .{ .pivot = pivot, .pi = pi, .kind = member.kind, .arrow = arrow });
        group = &groups.items[groups.items.len - 1];
    }
    if (!hasMember(group.members.items, member.edge)) try group.members.append(arena, member);
    if (!hasEdge(group.contributors.items, contributor)) try group.contributors.append(arena, contributor);
}

fn addPending(
    arena: std.mem.Allocator,
    groups: *std.ArrayListUnmanaged(Group),
    pending: Pending,
) error{OutOfMemory}!void {
    const pivot = pending.member.node(pending.member.pivot_end);
    var match: ?usize = null;
    for (groups.items, 0..) |group, i| {
        if (group.pivot != pivot or group.pi == null or
            group.kind != pending.member.kind or
            group.arrow != pending.member.arrow(pending.member.pivot_end)) continue;
        if (match != null) return; // More than one final site: do not guess.
        match = i;
    }
    if (match) |i| {
        const group = &groups.items[i];
        if (!hasMember(group.members.items, pending.member.edge)) try group.members.append(arena, pending.member);
        if (!hasEdge(group.contributors.items, pending.contributor)) try group.contributors.append(arena, pending.contributor);
        return;
    }
    try addCandidate(arena, groups, pending.member, pending.contributor);
}

fn appendClaim(
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(ledger.RailClaim),
    polarity: ledger.RailPolarity,
    source: []const ledger.RailClaimMember,
) error{OutOfMemory}!void {
    const members = try arena.dupe(ledger.RailClaimMember, source);
    std.mem.sort(ledger.RailClaimMember, members, {}, memberLess);
    if (sameClaimAlready(out.items, polarity, members)) return;
    try out.append(arena, .{
        .id = @intCast(out.items.len + 1),
        .polarity = polarity,
        .members = members,
    });
}

const NativeKey = struct {
    polarity: ledger.RailPolarity,
    pivot: sketch.NodeId,
    site: ledger.AttachmentSite,
    kind: sketch.EdgeKind,
    arrow: sketch.ArrowKind,
    port: ledger.CoCell,
    members: std.ArrayListUnmanaged(ledger.RailClaimMember) = .empty,
    traces: std.ArrayListUnmanaged([]const ledger.CoCell) = .empty,
};

fn appendNative(
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(ledger.RailClaim),
    bridges: []const sketch.EdgePath,
    paths: []const sketch.EdgePath,
    bars: []const sketch.Rail,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}!void {
    var groups: std.ArrayListUnmanaged(NativeKey) = .empty;
    const traces = try sketch_ports.finalCarrierTraces(arena, bridges, &.{});
    for (traces) |trace| {
        for ([2]ledger.RailPolarity{ .out, .in }) |polarity| {
            const member = stitch_rails.finalMember(paths, bars, placements, trace.id, polarity.pivotEnd()) orelse continue;
            const pivot_end = polarity.pivotEnd();
            const pivot = member.node(pivot_end) orelse continue;
            const site = member.site(pivot_end) orelse continue;
            const port: ledger.CoCell = if (polarity == .out)
                .{ .x = trace.first.x, .y = trace.first.y }
            else
                .{ .x = trace.last.x, .y = trace.last.y };
            const kind = member.kind;
            const arrow = member.arrow(pivot_end);
            var group: *NativeKey = undefined;
            for (groups.items) |*item| {
                if (item.polarity == polarity and item.pivot == pivot and
                    siteEqual(item.site, site) and item.kind == kind and item.arrow == arrow and
                    cellEqual(item.port, port) and try sharesAll(arena, item.traces.items, trace.cells, port))
                {
                    group = item;
                    break;
                }
            } else {
                try groups.append(arena, .{
                    .polarity = polarity,
                    .pivot = pivot,
                    .site = site,
                    .kind = kind,
                    .arrow = arrow,
                    .port = port,
                });
                group = &groups.items[groups.items.len - 1];
            }
            if (!hasMember(group.members.items, member.edge)) {
                try group.members.append(arena, member);
                try group.traces.append(arena, trace.cells);
            }
        }
    }

    std.mem.sort(NativeKey, groups.items, {}, nativeLess);
    for (groups.items) |*group| {
        if (group.members.items.len < 2) continue;
        const candidate: ledger.RailClaim = .{
            .id = 1,
            .polarity = group.polarity,
            .members = group.members.items,
        };
        if (!ledger.checkRailClaim(candidate).isValid()) continue;
        if (coveredByClaim(out.items, candidate)) continue;
        try appendClaim(arena, out, group.polarity, group.members.items);
    }
}

fn sharesAll(
    arena: std.mem.Allocator,
    existing: []const []const ledger.CoCell,
    candidate: []const ledger.CoCell,
    port: ledger.CoCell,
) error{OutOfMemory}!bool {
    for (existing) |trace| {
        if ((try sketch_ports.commonApproachCells(arena, trace, candidate, port)).len <= 1) return false;
    }
    return true;
}

fn sameClaimAlready(claims: []const ledger.RailClaim, polarity: ledger.RailPolarity, members: []const ledger.RailClaimMember) bool {
    for (claims) |claim| {
        if (claim.polarity != polarity or claim.members.len != members.len) continue;
        var same = true;
        for (members) |member| {
            if (!hasMember(claim.members, member.edge)) same = false;
        }
        if (same) return true;
    }
    return false;
}

fn coveredByClaim(claims: []const ledger.RailClaim, candidate: ledger.RailClaim) bool {
    const derived = ledger.checkRailClaim(candidate);
    for (claims) |claim| {
        const prior = ledger.checkRailClaim(claim);
        if (claim.polarity != candidate.polarity or prior.derived_pivot != derived.derived_pivot or
            !optionalSiteEqual(prior.derived_pi, derived.derived_pi)) continue;
        for (candidate.members) |member| {
            if (!hasMember(claim.members, member.edge)) break;
        } else return true;
    }
    return false;
}

fn hasMember(members: []const ledger.RailClaimMember, edge: sketch.EdgeId) bool {
    for (members) |member| if (member.edge == edge) return true;
    return false;
}

fn hasEdge(edges: []const sketch.EdgeId, edge: sketch.EdgeId) bool {
    for (edges) |item| if (item == edge) return true;
    return false;
}

fn siteEqual(a: ledger.AttachmentSite, b: ledger.AttachmentSite) bool {
    return a.node == b.node and a.side == b.side and a.offset == b.offset;
}

fn cellEqual(a: ledger.CoCell, b: ledger.CoCell) bool {
    return a.x == b.x and a.y == b.y;
}

fn optionalSiteEqual(a: ?ledger.AttachmentSite, b: ?ledger.AttachmentSite) bool {
    if (a == null or b == null) return a == null and b == null;
    return siteEqual(a.?, b.?);
}

fn groupLess(_: void, a: Group, b: Group) bool {
    if (a.pivot == null) return b.pivot != null;
    if (b.pivot == null) return false;
    if (a.pivot.? != b.pivot.?) return a.pivot.? < b.pivot.?;
    if (a.pi == null) return b.pi != null;
    if (b.pi == null) return false;
    if (a.pi.?.side != b.pi.?.side) return @intFromEnum(a.pi.?.side) < @intFromEnum(b.pi.?.side);
    if (a.pi.?.offset != b.pi.?.offset) return a.pi.?.offset < b.pi.?.offset;
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return @intFromEnum(a.arrow) < @intFromEnum(b.arrow);
}

fn nativeLess(_: void, a: NativeKey, b: NativeKey) bool {
    if (a.polarity != b.polarity) return @intFromEnum(a.polarity) < @intFromEnum(b.polarity);
    if (a.pivot != b.pivot) return a.pivot < b.pivot;
    if (a.site.side != b.site.side) return @intFromEnum(a.site.side) < @intFromEnum(b.site.side);
    if (a.site.offset != b.site.offset) return a.site.offset < b.site.offset;
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return @intFromEnum(a.arrow) < @intFromEnum(b.arrow);
}

fn memberLess(_: void, a: ledger.RailClaimMember, b: ledger.RailClaimMember) bool {
    return a.edge < b.edge;
}

test {
    _ = @import("bridge_claims_test.zig");
}
