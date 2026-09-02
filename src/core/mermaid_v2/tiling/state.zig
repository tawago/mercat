//! Ink-attribution-state conformance for the report-only structural audit.
//!
//! The producer records each ink cell's semantic state in the IR
//! (`lattice.InkState`, the cell-grid boundary); consumers read it. This tier is the ONE
//! retained re-derivation, kept deliberately as a conformance comparator
//! (IR-contracts side-channel item 6 shape): it re-derives what the old
//! geometric heuristics would have said and COUNTS every disagreement,
//! trusting neither side silently. Divergences are `m_` measurements, not
//! defects — the heuristics are known-imperfect (arity is not an owner
//! set), and a hand-built test lattice legitimately carries no states.
//! Production renders pin `m_state_untagged == 0` from
//! `tiling_crosscheck_test.zig`.
//!
//! Allowed imports: tiling zone (`std`, `../lattice.zig`, siblings).

const std = @import("std");
const lattice = @import("../lattice.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");

/// State conformance for ONE ink cell (stroke/arrow/ring kinds; the scan
/// dispatch guarantees the kind).
pub fn check(t: cell.Typed, aux_complete: bool, c: *counts.Counts) void {
    c.n_state_ink_cells += 1;

    if (t.state == .none) {
        c.m_state_untagged += 1;
        return;
    }

    switch (t.kind) {
        .ring_node, .ring_frame => {
            if (t.state != .node) c.m_state_ring_not_node += 1;
        },
        .stroke, .arrow => {
            const arity_junction = @popCount(t.ink) > 2;
            const recorded_junction = t.state == .junction;
            if (arity_junction != recorded_junction) c.m_state_junction_vs_arity += 1;

            switch (t.state) {
                .junction => if (!aux_complete) {
                    c.u_state_aux_unavailable += 1;
                } else if (hasCarrier(t, .suppressed)) {
                    c.m_state_junction_with_suppressed_carrier += 1;
                },
                .crossing => if (!aux_complete) {
                    c.u_state_aux_unavailable += 1;
                } else if (!hasCarrier(t, .suppressed)) {
                    c.m_state_crossing_unevidenced += 1;
                },
                .rail_interior => {
                    const role_rail = if (t.edge_role) |r| switch (r) {
                        .fan_out_rail, .fan_in_rail => true,
                        else => false,
                    } else false;
                    if (role_rail) return;
                    if (!aux_complete) {
                        c.u_state_aux_unavailable += 1;
                    } else if (t.ofKind(.rail_member).len == 0 and !hasCarrier(t, .merged_licensed)) {
                        c.m_state_rail_unevidenced += 1;
                    }
                },
                else => {},
            }
        },
        else => {},
    }
}

fn hasCarrier(t: cell.Typed, kind: lattice.CarrierKind) bool {
    for (t.carriers()) |r| {
        if (std.meta.intToEnum(lattice.CarrierKind, r.detail) catch continue == kind) return true;
    }
    return false;
}

const testing = std.testing;

test "state: an untagged ink cell is counted and asks nothing further" {
    var c: counts.Counts = .{};
    check(.{ .kind = .stroke, .ink = 0b0101, .mask = 0b0101 }, true, &c);
    try testing.expectEqual(@as(u32, 1), c.n_state_ink_cells);
    try testing.expectEqual(@as(u32, 1), c.m_state_untagged);
    try testing.expectEqual(@as(u32, 0), c.m_state_junction_vs_arity);
}

test "state: recorded junction and the arity heuristic are compared, not trusted" {
    var c: counts.Counts = .{};
    check(.{ .kind = .stroke, .ink = 0b0111, .mask = 0b0111, .state = .junction }, true, &c);
    try testing.expectEqual(@as(u32, 0), c.m_state_junction_vs_arity);
    check(.{ .kind = .stroke, .ink = 0b0111, .mask = 0b0111, .state = .stroke }, true, &c);
    try testing.expectEqual(@as(u32, 1), c.m_state_junction_vs_arity);
    check(.{ .kind = .stroke, .ink = 0b0101, .mask = 0b0101, .state = .junction }, true, &c);
    try testing.expectEqual(@as(u32, 2), c.m_state_junction_vs_arity);
}

test "state: a crossing wants its suppressed carrier; absence is counted, aux-unavailable abstains" {
    var c: counts.Counts = .{};
    const rec = [_]lattice.Aux{.{ .cell = 0, .value = 9, .kind = .carrier, .detail = @intFromEnum(lattice.CarrierKind.suppressed) }};
    check(.{ .kind = .stroke, .ink = 0b1010, .mask = 0b1010, .state = .crossing, .aux = &rec }, true, &c);
    try testing.expectEqual(@as(u32, 0), c.m_state_crossing_unevidenced);
    check(.{ .kind = .stroke, .ink = 0b1010, .mask = 0b1010, .state = .crossing }, true, &c);
    try testing.expectEqual(@as(u32, 1), c.m_state_crossing_unevidenced);
    check(.{ .kind = .stroke, .ink = 0b1010, .mask = 0b1010, .state = .crossing }, false, &c);
    try testing.expectEqual(@as(u32, 1), c.u_state_aux_unavailable);
}

test "state: a ring cell records node; anything else is drift" {
    var c: counts.Counts = .{};
    check(.{ .kind = .ring_node, .ink = 0b0011, .mask = 0b0011, .state = .node }, true, &c);
    try testing.expectEqual(@as(u32, 0), c.m_state_ring_not_node);
    check(.{ .kind = .ring_frame, .ink = 0b0011, .mask = 0b0011, .state = .stroke }, true, &c);
    try testing.expectEqual(@as(u32, 1), c.m_state_ring_not_node);
}

test "state: rail interior is satisfied by a rail role, else asks the side table" {
    var c: counts.Counts = .{};
    check(.{ .kind = .stroke, .ink = 0b1010, .mask = 0b1010, .state = .rail_interior, .edge_role = .fan_out_rail }, true, &c);
    try testing.expectEqual(@as(u32, 0), c.m_state_rail_unevidenced);
    const rec = [_]lattice.Aux{.{ .cell = 0, .value = 4, .kind = .rail_member, .detail = 0 }};
    check(.{ .kind = .stroke, .ink = 0b1010, .mask = 0b1010, .state = .rail_interior, .edge_role = .forward, .aux = &rec }, true, &c);
    try testing.expectEqual(@as(u32, 0), c.m_state_rail_unevidenced);
    check(.{ .kind = .stroke, .ink = 0b1010, .mask = 0b1010, .state = .rail_interior, .edge_role = .forward }, true, &c);
    try testing.expectEqual(@as(u32, 1), c.m_state_rail_unevidenced);
}

test "state: a junction beside a surviving suppressed carrier is the co-location misgeometry" {
    var c: counts.Counts = .{};
    const sup = [_]lattice.Aux{.{ .cell = 0, .value = 9, .kind = .carrier, .detail = @intFromEnum(lattice.CarrierKind.suppressed) }};
    check(.{ .kind = .stroke, .ink = 0b0111, .mask = 0b0111, .state = .junction, .aux = &sup }, true, &c);
    try testing.expectEqual(@as(u32, 1), c.m_state_junction_with_suppressed_carrier);
    const lic = [_]lattice.Aux{.{ .cell = 0, .value = 9, .kind = .carrier, .detail = @intFromEnum(lattice.CarrierKind.merged_licensed) }};
    check(.{ .kind = .stroke, .ink = 0b0111, .mask = 0b0111, .state = .junction, .aux = &lic }, true, &c);
    try testing.expectEqual(@as(u32, 1), c.m_state_junction_with_suppressed_carrier);
    check(.{ .kind = .stroke, .ink = 0b0111, .mask = 0b0111, .state = .junction }, false, &c);
    try testing.expectEqual(@as(u32, 1), c.u_state_aux_unavailable);
}

test "state: a suppressed carrier does not evidence a rail interior" {
    var c: counts.Counts = .{};
    const sup = [_]lattice.Aux{.{ .cell = 0, .value = 9, .kind = .carrier, .detail = @intFromEnum(lattice.CarrierKind.suppressed) }};
    check(.{ .kind = .stroke, .ink = 0b1010, .mask = 0b1010, .state = .rail_interior, .edge_role = .forward, .aux = &sup }, true, &c);
    try testing.expectEqual(@as(u32, 1), c.m_state_rail_unevidenced);
    const lic = [_]lattice.Aux{.{ .cell = 0, .value = 9, .kind = .carrier, .detail = @intFromEnum(lattice.CarrierKind.merged_licensed) }};
    check(.{ .kind = .stroke, .ink = 0b1010, .mask = 0b1010, .state = .rail_interior, .edge_role = .forward, .aux = &lic }, true, &c);
    try testing.expectEqual(@as(u32, 1), c.m_state_rail_unevidenced);
}
