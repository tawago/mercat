//! Attributable channel tier of the report-only structural audit.
//!
//! Every available carrier record enters before any owner or identity gate.
//! The tier then asks two independent questions for each distinct pair:
//! whether recorded channel identity agrees with the membership derivation,
//! and whether the producer's `CarrierKind.detail` claim agrees with recorded
//! identity. Neither disagreement is promoted to a renderer defect.

const std = @import("std");
const ledger = @import("../base/ledger.zig");
const sketch = @import("../sketch.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");

fn satU32(value: u64) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn stampAvailable(s: sketch.Sketch, c: *counts.Counts) bool {
    switch (s.channel_stamp_state) {
        .unattempted => c.u_channel_stamp_unattempted += 1,
        .out_of_memory => c.u_channel_stamp_oom += 1,
        .rail_invariant => c.u_channel_stamp_rail_invariant += 1,
        .complete => {
            if (ledger.rosterNumbered(s.co_sets)) {
                c.n_channel_stamp_complete += 1;
                return true;
            }
            c.u_channel_roster_inconsistent += 1;
        },
    }
    return false;
}

fn compareDetail(detail: u8, recorded: ?bool, c: *counts.Counts) void {
    const kind = std.meta.intToEnum(cell.CarrierKind, detail) catch {
        c.u_channel_detail_invalid += 1;
        return;
    };
    const claim: bool = switch (kind) {
        .merged_licensed => true,
        .merged_foreign, .suppressed => false,
        .merged_untested => {
            c.u_channel_detail_untested += 1;
            return;
        },
    };
    const identity = recorded orelse {
        c.u_channel_detail_identity_unavailable += 1;
        return;
    };
    c.n_channel_details_compared += 1;
    if (claim == identity) {
        c.m_channel_detail_agreed += 1;
    } else {
        c.u_channel_detail_disagreed += 1;
    }
}

/// Count all carrier records, then classify every available record exactly
/// once. Pure read: the `View` exposes only copied cells and const records.
pub fn check(v: cell.View, s: sketch.Sketch, c: *counts.Counts) void {
    const aux = v.auxCollection();
    c.n_aux_records_attempted = satU32(aux.attempted_records);
    c.n_aux_records_available = if (aux.state == .complete)
        satU32(@intCast(v.auxRecords().len))
    else
        0;
    switch (aux.state) {
        .not_collected => c.u_aux_not_collected += 1,
        .out_of_memory => {
            c.u_aux_collection_oom += 1;
            c.u_aux_records_lost = satU32(aux.lostRecords());
        },
        .complete => c.n_aux_collection_complete += 1,
    }

    const identity_available = stampAvailable(s, c);
    if (aux.state != .complete) {
        c.u_channel_record_aux_unavailable += 1;
        return;
    }

    for (v.auxRecords()) |r| {
        if (r.kind != .carrier) continue;
        c.n_channel_carrier_records += 1;
        const t = v.atIndex(r.cell) orelse {
            c.u_channel_record_owner_absent += 1;
            continue;
        };
        const held = t.edge orelse {
            c.u_channel_record_owner_absent += 1;
            continue;
        };
        if (r.value == held) {
            c.u_channel_record_restates_owner += 1;
            continue;
        }

        c.n_channel_carrier_pairs += 1;
        var recorded: ?bool = null;
        if (identity_available) {
            const x = r.cell % v.width();
            const y = r.cell / v.width();
            const at: ledger.CoCell = .{ .x = @intCast(x), .y = @intCast(y) };
            const identity = ledger.channelsAgree(s.co_sets, held, r.value, at);
            recorded = identity;
            const derived = ledger.derivedSameChannel(s.joins, s.co_sets, held, r.value, at);
            c.n_channel_pairs_compared += 1;
            if (identity == derived) {
                c.m_channel_identity_agreed += 1;
            } else {
                c.u_channel_identity_disagreed += 1;
            }
        } else {
            c.u_channel_identity_unavailable += 1;
        }
        compareDetail(r.detail, recorded, c);
    }

    if (c.n_channel_carrier_records == 0) c.u_channel_population_absent += 1;
}
