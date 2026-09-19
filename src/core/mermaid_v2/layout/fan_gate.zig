const std = @import("std");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const fan_mod = @import("fan.zig");

const Fan = fan_mod.Fan;

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
