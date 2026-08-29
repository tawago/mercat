//! Extension of the Sketch IR root: CHANNEL IDENTITY over a finished Sketch.
//!
//! A bundle states WHO shares a run. Until a set has a name, the only way to
//! ask "do these two share a bundle HERE" is to re-scan both membership
//! lists at the point of decision — which is what the raster did, at four
//! sites, none of which could say WHICH bundle it had just licensed. This
//! file mints the names.
//!
//! Two facts are stamped, and both are the PRODUCER's, never a reader's:
//!
//!   * the roster — every `Bundle` gets its 1-based position as its
//!     `BundleId` (`ledger.numberBundles`). Positions are unique inside one
//!     Sketch by construction, which is exactly the property a stitch needs:
//!     two children that each numbered their own fans from one are re-numbered
//!     into a single roster, so a merged picture can never read two distinct
//!     bundles as one.
//!   * the rails — every `sketch.Rail` gets the bundle of the set that names
//!     its members, so raster's rail writer states the licence on its own
//!     ink by LOOKUP rather than by re-derivation.
//!
//! WHEN. At each point a Sketch's bundle list becomes final, and nowhere
//! else: `layout.zig` (flat and recursion-child layouts), `cluster/stitch.zig`
//! (the merged Sketch), `select.zig` (the plan replaces layout's sets), and
//! `select_filter.zig` (a withdrawn or re-realized plan does the same). A
//! roster that is rebuilt is re-numbered, because the old names named the old
//! decision.
//!
//! ABSTENTION, NOT GUESSWORK. Allocation failure or an invalid rail publishes
//! neither staged slice. `Sketch.bundle_stamp_state` names the outcome, and
//! readers trust the payload only when it is `.complete`.
//!
//! Allowed imports (tools/lint/imports.zig): `std`, `prim`, `base/ledger.zig`,
//! `sketch.zig`. Pure data in, pure data out — no geometry is read except the
//! tap edge ids that key a rail to its set.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const sketch = @import("sketch.zig");

/// Result of resolving one whole rail against a numbered roster. Off-roster
/// rails deliberately carry no `BundleId` here; the stamping transaction
/// mints their fresh identities after the roster band.
pub const RailBundleResolution = union(enum) {
    roster: ledger.BundleId,
    off_roster,
    invariant,
};

/// Resolve every tap, not merely the first matching one. A valid roster rail
/// has exactly one structural, unscoped set per tap and every tap resolves to
/// the same set. No matching tap is the separate, valid off-roster case; a
/// mixture, duplicate membership, or distinct sets invalidates the whole rail.
pub fn resolveRailBundle(sets: []const ledger.Bundle, rail: sketch.Rail) RailBundleResolution {
    var resolved_set: ?usize = null;
    var saw_absent = false;
    for (rail.taps) |tap| {
        switch (ledger.resolveStructuralBundle(sets, tap.edge)) {
            .absent => {
                if (resolved_set != null) return .invariant;
                saw_absent = true;
            },
            .multiple => return .invariant,
            .unique => |set_index| {
                if (saw_absent) return .invariant;
                if (resolved_set) |expected| {
                    if (set_index != expected) return .invariant;
                } else {
                    resolved_set = set_index;
                }
            },
        }
    }

    const set_index = resolved_set orelse return .off_roster;
    const bundle = sets[set_index].bundle;
    if (bundle == ledger.no_bundle) return .invariant;
    return .{ .roster = bundle };
}

/// Number `s.bundle_sets` and stamp every rail with the bundle it rides.
///
/// Idempotent in effect: re-stamping a Sketch whose roster is unchanged
/// produces the same names, because a name is a position. Cheap to call twice
/// (one allocation per list), which is why every finaliser calls it rather
/// than reasoning about whether an earlier one already did.
///
/// Both slices are staged before either is assigned. Any allocation failure or
/// rail invariant failure discards the staged payload and changes only
/// `bundle_stamp_state` on the input Sketch.
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

    // A rail whose members no set names still rides a bundle — its own. It is
    // minted past the end of the roster so it can collide with neither a set's
    // name nor another rail's, and it is a SHARED bundle (several taps ride
    // it), so the private band, which is one edge wide, cannot express it.
    // Regression pin, report-only: this is current, intended behaviour,
    // restated loudly because the census does not cover it. A rail
    // no structural set names is stamped OFF-roster, on a fresh bundle of its
    // own (below). That bundle never equals any edge it merges onto, so
    // EVERY merge such a rail makes reads `.merged_foreign` at the licence
    // sites (`crossings.licenceFor`, `rails.licenceAt`) and the crossing
    // audit's `d_run_fused_foreign`. Correct, by the same rule any two
    // strangers get — but corpus-unexercised until
    // the off-roster tests in `sketch_bundles_test.zig` and
    // `rails_test2.zig` gave it explicit coverage.
    var next: ledger.BundleId = @intCast(numbered.len + 1);
    for (rails_buf) |*slot| {
        switch (resolveRailBundle(numbered, slot.*)) {
            .roster => |bundle| slot.bundle = bundle,
            .off_roster => {
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
