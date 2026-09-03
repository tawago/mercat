//! fan_gate.zig — which detected fans holding a long peer go on to the
//! rail path, and which skip edges the fan rows already shelter.
//!
//! A long peer taps a rail or nothing: the per-peer polyline path assumes
//! a next-layer leaf. So a fan with a long peer is kept only where the plan
//! selected exactly its shared peers as one bundle (the condition
//! `fan_rail.resolve` builds a rail under); otherwise it degrades to what
//! it was before long peers existed — no fan, private routing. With no
//! plan to read (a motif-packed candidate, a recursion piece, a plan
//! failure) the same degradation applies: that arm routes without
//! clearance gates, and a member stroke there has nothing to keep it out
//! of a box, so long peers wait for the plan-driven path.
//!
//! Allowed imports (layout zone): std + sem_graph + siblings.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const fan_mod = @import("fan.zig");

const Fan = fan_mod.Fan;

/// Keep a fan holding a long peer only where a selected bundle names exactly
/// its shared peers (the condition `fan_rail.resolve` builds a rail under);
/// fans without long peers pass untouched, and so does every fan when there
/// is no plan to read (the no-plan arm builds rails for any fan). A fan
/// dropped here is routed privately, as before long peers existed.
pub fn keepRealizableLong(a: std.mem.Allocator, fans: []Fan, bundles: ledger.RealizedBundles) error{OutOfMemory}![]Fan {
    var out: std.ArrayListUnmanaged(Fan) = .empty;
    for (fans) |f| {
        var has_long = false;
        for (f.peers) |p| if (p.long) {
            has_long = true;
        };
        if (!has_long or selectedAsOne(f, bundles)) try out.append(a, f);
    }
    return out.toOwnedSlice(a);
}

/// The long members of every fan-IN: skip edges whose descent ends on a
/// rail's continuing tap rather than at a wall.
pub fn longFanInMembers(a: std.mem.Allocator, fans: []const Fan) error{OutOfMemory}![]const sg.EdgeId {
    var out: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
    for (fans) |f| {
        if (f.direction != .in) continue;
        for (f.peers) |p| if (p.long and p.shared) try out.append(a, p.edge_id);
    }
    return out.toOwnedSlice(a);
}

fn selectedAsOne(f: Fan, bundles: ledger.RealizedBundles) bool {
    if (bundles.memberships.len == 0) return false;
    var shared_len: usize = 0;
    for (f.peers) |p| if (p.shared) {
        shared_len += 1;
    };
    for (bundles.selected_bundles) |sel| {
        if (sel.members.len != shared_len) continue;
        var all = true;
        for (f.peers) |p| {
            if (!p.shared) continue;
            if (std.mem.indexOfScalar(ledger.EdgeId, sel.members, p.edge_id) == null) all = false;
        }
        if (all) return true;
    }
    return false;
}


test {
    std.testing.refAllDecls(@This());
}
