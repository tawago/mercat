const std = @import("std");
const ledger = @import("base/ledger.zig");
const sketch = @import("sketch.zig");

pub const RailBundleResolution = union(enum) {
    set: ledger.BundleId,
    no_set,
    invariant,
};

pub fn resolveRailBundle(sets: []const ledger.Bundle, rail: sketch.Rail) RailBundleResolution {
    var superset: ?usize = null;
    var supersets: usize = 0;
    var exact: ?usize = null;
    var exacts: usize = 0;
    for (sets, 0..) |set, i| {
        if (!ledger.structuralUnscoped(set)) continue;
        if (!holdsAll(set.members, rail.taps)) continue;
        supersets += 1;
        superset = i;
        if (set.members.len == rail.taps.len) {
            exacts += 1;
            exact = i;
        }
    }
    const chosen: usize = if (exacts == 1) exact.? else if (exacts == 0 and supersets == 1) superset.? else {
        if (supersets != 0) return .invariant;
        var named: usize = 0;
        for (rail.taps) |tap| switch (ledger.resolveStructuralBundle(sets, tap.edge)) {
            .absent => {},
            .unique, .multiple => named += 1,
        };
        return if (named != 0) .invariant else .no_set;
    };
    const bundle = sets[chosen].bundle;
    if (bundle == ledger.no_bundle) return .invariant;
    return .{ .set = bundle };
}

fn holdsAll(members: []const ledger.EdgeId, taps: []const sketch.Tap) bool {
    for (taps) |tap| {
        var found = false;
        for (members) |m| if (m == tap.edge) {
            found = true;
        };
        if (!found) return false;
    }
    return true;
}

pub fn stamp(allocator: std.mem.Allocator, s: *sketch.Sketch) void {
    const numbered = ledger.numberBundles(allocator, s.bundle_sets) catch {
        s.bundle_stamp_state = .out_of_memory;
        return;
    };
    const rails_buf = allocator.alloc(sketch.Rail, s.rails.len) catch {
        discardNumbered(allocator, s.bundle_sets.len, numbered);
        s.bundle_stamp_state = .out_of_memory;
        return;
    };
    @memcpy(rails_buf, s.rails);

    var next: ledger.BundleId = @intCast(numbered.len + 1);
    for (rails_buf) |*slot| {
        switch (resolveRailBundle(numbered, slot.*)) {
            .set => |bundle| slot.bundle = bundle,
            .no_set => {
                slot.bundle = next;
                next += 1;
            },
            .invariant => {
                allocator.free(rails_buf);
                discardNumbered(allocator, s.bundle_sets.len, numbered);
                s.bundle_stamp_state = .rail_invariant;
                return;
            },
        }
    }

    s.bundle_sets = numbered;
    s.rails = rails_buf;
    s.bundle_stamp_state = .complete;
}

fn discardNumbered(allocator: std.mem.Allocator, original_len: usize, numbered: []const ledger.Bundle) void {
    if (original_len != 0) allocator.free(numbered);
}
