const std = @import("std");
const ledger = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const fan_mod = @import("fan.zig");
const fan_gate = @import("fan_gate.zig");
const bundle_commit = @import("bundle_commit.zig");
const ports = @import("ports.zig");
const port_plan = @import("port_plan.zig");

pub const BundleDecision = struct {
    fans: []const fan_mod.Fan,
    bundles: ledger.RealizedBundles,
    attachments: []const ports.DerivedAttachment,
    port_active: bool,
    plan_realized: bool,
};

pub fn decide(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    permits: ?*const ledger.BundlePermits,
) error{OutOfMemory}!BundleDecision {
    const detected: []fan_mod.Fan = if (graph.direction == .TD) try fan_mod.detect(a, graph, lg) else &.{};
    const effective = try bundle_commit.effectivePlan(a, graph, permits);
    const plan: ?*const ledger.BundlePermits = if (effective) |*p| p else null;
    const bundles = try bundle_commit.realize(a, graph, plan, lg.reversed_edges, try longEdges(a, lg));
    const fans = try fan_gate.keepRealizableLong(a, detected, bundles);
    const private_peers = hasPrivatePeers(fans);
    const port_active = hasPortWork(bundles) or private_peers;
    return .{
        .fans = fans,
        .bundles = bundles,
        .attachments = attachmentsFor(a, graph, lg, plan, bundles, fans, port_active, private_peers),
        .port_active = port_active,
        .plan_realized = if (plan) |p|
            p.scope == .flat or (p.scope == .piece and bundles.selected_bundles.len != 0)
        else
            false,
    };
}

fn attachmentsFor(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    plan: ?*const ledger.BundlePermits,
    bundles: ledger.RealizedBundles,
    fans: []const fan_mod.Fan,
    port_active: bool,
    private_peers: bool,
) []const ports.DerivedAttachment {
    if (plan) |p| if (port_active) {
        const all = ports.derive(a, graph, p.*, bundles, graph.direction, lg.reversed_edges) catch &.{};
        return port_plan.withoutDischarged(a, all, bundles) catch all;
    };
    if (private_peers) return port_plan.deriveFanAttachments(a, graph, graph.direction, lg.reversed_edges, fans) catch &.{};
    return &.{};
}

fn longEdges(a: std.mem.Allocator, lg: sugiyama.LayeredGraph) error{OutOfMemory}![]const ledger.EdgeId {
    var out: std.ArrayListUnmanaged(ledger.EdgeId) = .empty;
    for (lg.nodes) |n| switch (n) {
        .virtual => |v| if (v.index == 0) try out.append(a, v.edge),
        .real => {},
    };
    return out.toOwnedSlice(a);
}

fn hasPortWork(bundles: ledger.RealizedBundles) bool {
    if (bundles.selected_bundles.len != 0) return true;
    for (bundles.memberships) |membership| {
        inline for ([2]?ledger.MembershipDisposition{ membership.source, membership.target }) |disposition| {
            if (disposition) |value| if (value == .independent) return true;
        }
    }
    return false;
}

fn hasPrivatePeers(fans: []const fan_mod.Fan) bool {
    for (fans) |f| for (f.peers) |peer| if (!peer.shared) return true;
    return false;
}
