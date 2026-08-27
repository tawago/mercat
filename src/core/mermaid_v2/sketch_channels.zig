//! Extension of the Sketch IR root: CHANNEL IDENTITY over a finished Sketch.
//!
//! A co-set states WHO shares a run. Until a set has a name, the only way to
//! ask "do these two share a channel HERE" is to re-scan both membership
//! lists at the point of decision — which is what the raster did, at four
//! sites, none of which could say WHICH channel it had just licensed. This
//! file mints the names.
//!
//! Two facts are stamped, and both are the PRODUCER's, never a reader's:
//!
//!   * the roster — every `CoSet` gets its 1-based position as its
//!     `ChannelId` (`ledger.numberChannels`). Positions are unique inside one
//!     Sketch by construction, which is exactly the property a stitch needs:
//!     two children that each numbered their own fans from one are re-numbered
//!     into a single roster, so a merged picture can never read two distinct
//!     channels as one.
//!   * the rails — every `sketch.Rail` gets the channel of the set that names
//!     its members, so raster's bus-bar writer states the licence on its own
//!     ink by LOOKUP rather than by re-derivation.
//!
//! WHEN. At each point a Sketch's co-set list becomes final, and nowhere
//! else: `layout.zig` (flat and recursion-child layouts), `cluster/stitch.zig`
//! (the merged Sketch), `select.zig` (the plan replaces layout's sets), and
//! `select_filter.zig` (a withdrawn or re-realized plan does the same). A
//! roster that is rebuilt is re-numbered, because the old names named the old
//! decision.
//!
//! ABSTENTION, NOT GUESSWORK. Allocation failure or an invalid rail publishes
//! neither staged slice. `Sketch.channel_stamp_state` names the outcome, and
//! readers trust the payload only when it is `.complete`.
//!
//! Allowed imports (tools/lint/imports.zig): `std`, `prim`, `base/ledger.zig`,
//! `sketch.zig`. Pure data in, pure data out — no geometry is read except the
//! tap edge ids that key a rail to its set.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const sketch = @import("sketch.zig");

/// Result of resolving one whole rail against a numbered roster. Off-roster
/// rails deliberately carry no `ChannelId` here; the stamping transaction
/// mints their fresh identities after the roster band.
pub const RailChannelResolution = union(enum) {
    roster: ledger.ChannelId,
    off_roster,
    invariant,
};

/// Resolve every tap, not merely the first matching one. A valid roster rail
/// has exactly one structural, unscoped set per tap and every tap resolves to
/// the same set. No matching tap is the separate, valid off-roster case; a
/// mixture, duplicate membership, or distinct sets invalidates the whole rail.
pub fn resolveRailChannel(sets: []const ledger.CoSet, bb: sketch.Rail) RailChannelResolution {
    var resolved_set: ?usize = null;
    var saw_absent = false;
    for (bb.taps) |tap| {
        switch (ledger.resolveStructuralSet(sets, tap.edge)) {
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
    const channel = sets[set_index].channel;
    if (channel == ledger.no_channel) return .invariant;
    return .{ .roster = channel };
}

/// Number `s.co_sets` and stamp every rail with the channel it rides.
///
/// Idempotent in effect: re-stamping a Sketch whose roster is unchanged
/// produces the same names, because a name is a position. Cheap to call twice
/// (one allocation per list), which is why every finaliser calls it rather
/// than reasoning about whether an earlier one already did.
///
/// Both slices are staged before either is assigned. Any allocation failure or
/// rail invariant failure discards the staged payload and changes only
/// `channel_stamp_state` on the input Sketch.
pub fn stamp(allocator: std.mem.Allocator, s: *sketch.Sketch) void {
    const numbered = ledger.numberChannels(allocator, s.co_sets) catch {
        s.channel_stamp_state = .out_of_memory;
        return;
    };
    const bars = allocator.alloc(sketch.Rail, s.busbars.len) catch {
        discardNumbered(allocator, s.co_sets.len, numbered);
        s.channel_stamp_state = .out_of_memory;
        return;
    };
    @memcpy(bars, s.busbars);

    // A rail whose members no set names still rides a channel — its own. It is
    // minted past the end of the roster so it can collide with neither a set's
    // name nor another rail's, and it is a SHARED channel (several taps ride
    // it), so the private band, which is one edge wide, cannot express it.
    // Regression pin, report-only: this is current, intended behaviour,
    // restated loudly because the census does not cover it. A rail
    // no structural set names is stamped OFF-roster, on a fresh channel of its
    // own (below). That channel never equals any edge it merges onto, so
    // EVERY merge such a rail makes reads `.merged_foreign` at the licence
    // sites (`crossings.licenceFor`, `busbars.licenceAt`) and the crossing
    // audit's `d_run_fused_foreign`. Correct, by the same rule any two
    // strangers get — but corpus-unexercised until
    // the off-roster tests in `sketch_channels_test.zig` and
    // `busbars_test2.zig` gave it explicit coverage.
    var next: ledger.ChannelId = @intCast(numbered.len + 1);
    for (bars) |*slot| {
        switch (resolveRailChannel(numbered, slot.*)) {
            .roster => |channel| slot.channel = channel,
            .off_roster => {
                slot.channel = next;
                next += 1;
            },
            .invariant => {
                allocator.free(bars);
                discardNumbered(allocator, s.co_sets.len, numbered);
                s.channel_stamp_state = .rail_invariant;
                return;
            },
        }
    }

    s.co_sets = numbered;
    s.busbars = bars;
    s.channel_stamp_state = .complete;
}

fn discardNumbered(allocator: std.mem.Allocator, original_len: usize, numbered: []const ledger.CoSet) void {
    if (original_len != 0) allocator.free(numbered);
}
