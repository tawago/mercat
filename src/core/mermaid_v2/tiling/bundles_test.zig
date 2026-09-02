//! Unit tests for the attributable carrier-record bundle tier.

const std = @import("std");
const ledger = @import("../base/ledger.zig");
const lattice = @import("../lattice.zig");
const sketch = @import("../sketch.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");
const bundles = @import("bundles.zig");

const testing = std.testing;
const W: u32 = 4;
const H: u32 = 2;

fn idx(x: u32, y: u32) u32 {
    return y * W + x;
}

const Fixture = struct {
    cells: [W * H]lattice.Cell = undefined,
    recs: [8]lattice.Aux = undefined,
    n_recs: usize = 0,
    sets: [2]ledger.Bundle = undefined,
    n_sets: usize = 0,
    bundles: ledger.RealizedBundles = .{},
    aux_state: lattice.AuxCollectionState = .complete,
    attempted: ?u64 = null,

    fn init(self: *Fixture) void {
        for (&self.cells) |*c| c.* = lattice.Cell.empty;
        self.cells[idx(1, 0)] = .{
            .occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid } },
            .neighbours = .{ .e = true, .w = true },
        };
        self.n_recs = 0;
        self.n_sets = 0;
        self.bundles = .{};
        self.aux_state = .complete;
        self.attempted = null;
    }

    fn add(self: *Fixture, cell_index: u32, edge: u32, filed: u8) void {
        self.recs[self.n_recs] = .{ .cell = cell_index, .value = edge, .kind = .carrier, .detail = filed };
        self.n_recs += 1;
    }

    fn lat(self: *Fixture) lattice.Lattice {
        return .{
            .width = W,
            .height = H,
            .cells = &self.cells,
            .aux = if (self.aux_state == .complete) self.recs[0..self.n_recs] else &.{},
            .aux_collection = .{
                .state = self.aux_state,
                .attempted_records = self.attempted orelse if (self.aux_state == .not_collected) 0 else self.n_recs,
            },
        };
    }

    fn sk(self: *Fixture) sketch.Sketch {
        return .{
            .bbox = .{ .x = 0, .y = 0, .w = W, .h = H },
            .direction = .TD,
            .nodes = &.{},
            .clusters = &.{},
            .edges = &.{},
            .bundles = self.bundles,
            .bundle_sets = self.sets[0..self.n_sets],
            .bundle_stamp_state = .complete,
            .diagnostics = &.{},
            .budget = .{ .max_width = 80, .rung = 0 },
        };
    }
};

fn run(f: *Fixture) counts.Counts {
    const lat = f.lat();
    var c: counts.Counts = .{};
    bundles.check(cell.View.init(&lat), f.sk(), &c);
    return c;
}

fn detail(kind: lattice.CarrierKind) u8 {
    return @intFromEnum(kind);
}

fn expectRecordPartition(c: counts.Counts) !void {
    try testing.expectEqual(
        c.n_bundle_carrier_records,
        c.u_bundle_record_owner_absent + c.u_bundle_record_restates_owner +
            c.n_bundle_carrier_pairs,
    );
    try testing.expectEqual(
        c.n_aux_records_attempted,
        c.n_aux_records_available + c.u_aux_records_lost,
    );
    try testing.expectEqual(
        @as(u32, 1),
        c.n_aux_collection_complete + c.u_aux_not_collected + c.u_aux_collection_oom,
    );
    try testing.expectEqual(
        @as(u32, 1),
        c.n_bundle_stamp_complete + c.u_bundle_stamp_unattempted +
            c.u_bundle_stamp_oom + c.u_bundle_stamp_rail_invariant +
            c.u_bundle_roster_inconsistent,
    );
}

fn expectPairPartitions(c: counts.Counts) !void {
    try testing.expectEqual(
        c.n_bundle_carrier_pairs,
        c.n_bundle_pairs_compared + c.u_bundle_identity_unavailable,
    );
    try testing.expectEqual(
        c.n_bundle_pairs_compared,
        c.m_bundle_identity_agreed + c.u_bundle_identity_disagreed,
    );
    try testing.expectEqual(
        c.n_bundle_carrier_pairs,
        c.n_bundle_details_compared + c.u_bundle_detail_untested +
            c.u_bundle_detail_invalid + c.u_bundle_detail_identity_unavailable,
    );
    try testing.expectEqual(
        c.n_bundle_details_compared,
        c.m_bundle_detail_agreed + c.u_bundle_detail_disagreed,
    );
}

const members_01 = [_]ledger.EdgeId{ 0, 1 };
const members_0 = [_]ledger.EdgeId{0};
const members_1 = [_]ledger.EdgeId{1};

test "bundles: all available carrier records enter the owner partition" {
    var f: Fixture = .{};
    f.init();
    f.add(idx(1, 0), 0, detail(.merged_licensed));
    f.add(idx(0, 0), 2, detail(.merged_foreign));
    f.add(idx(1, 0), 1, detail(.merged_foreign));
    const c = run(&f);

    try testing.expectEqual(@as(u32, 3), c.n_bundle_carrier_records);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_record_owner_absent);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_record_restates_owner);
    try testing.expectEqual(@as(u32, 1), c.n_bundle_carrier_pairs);
    try expectRecordPartition(c);
    try expectPairPartitions(c);
}

test "bundles: every CarrierKind detail outcome is attributable" {
    var f: Fixture = .{};
    f.init();
    f.add(idx(1, 0), 1, detail(.merged_licensed));
    f.add(idx(1, 0), 2, detail(.merged_foreign));
    f.add(idx(1, 0), 3, detail(.suppressed));
    f.add(idx(1, 0), 4, detail(.merged_untested));
    f.add(idx(1, 0), 5, 255);
    const c = run(&f);

    try testing.expectEqual(@as(u32, 5), c.n_bundle_carrier_pairs);
    try testing.expectEqual(@as(u32, 3), c.n_bundle_details_compared);
    try testing.expectEqual(@as(u32, 2), c.m_bundle_detail_agreed);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_detail_disagreed);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_detail_untested);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_detail_invalid);
    try expectRecordPartition(c);
    try expectPairPartitions(c);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "bundles: filed detail mismatch is counted in both directions" {
    var f: Fixture = .{};
    f.init();
    f.sets[0] = .{ .origin = .fan_rail, .bundle = 1, .members = &members_01 };
    f.n_sets = 1;
    f.add(idx(1, 0), 1, detail(.merged_foreign));
    var c = run(&f);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_detail_disagreed);

    f.n_recs = 0;
    f.n_sets = 0;
    f.add(idx(1, 0), 1, detail(.merged_licensed));
    c = run(&f);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_detail_disagreed);
}

test "bundles: identity-versus-derived remains an independent comparison" {
    var f: Fixture = .{};
    f.init();
    const bundle_members = [_]ledger.EdgeId{ 0, 1 };
    const selected = [_]ledger.SelectedBundle{.{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &bundle_members }};
    f.bundles = .{ .selected_bundles = &selected };
    f.sets[0] = .{ .origin = .fan_rail, .bundle = 1, .members = &members_0 };
    f.sets[1] = .{ .origin = .fan_rail, .bundle = 2, .members = &members_1 };
    f.n_sets = 2;
    f.add(idx(1, 0), 1, detail(.merged_foreign));
    const c = run(&f);

    try testing.expectEqual(@as(u32, 1), c.u_bundle_identity_disagreed);
    try testing.expectEqual(@as(u32, 1), c.m_bundle_detail_agreed);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    f.bundles = .{};
    f.sets[1].bundle = 1;
    const reverse_mismatch = run(&f);
    try testing.expectEqual(@as(u32, 1), reverse_mismatch.u_bundle_identity_disagreed);
    try testing.expectEqual(@as(u32, 1), reverse_mismatch.u_bundle_detail_disagreed);
}

test "bundles: unavailable AUX is attributed and never called an absent population" {
    inline for (.{ lattice.AuxCollectionState.not_collected, lattice.AuxCollectionState.out_of_memory }) |state| {
        var f: Fixture = .{};
        f.init();
        f.aux_state = state;
        f.attempted = if (state == .out_of_memory) 3 else 0;
        const c = run(&f);
        try testing.expectEqual(@as(u32, 0), c.u_bundle_population_absent);
        try testing.expectEqual(@as(u32, 1), c.u_bundle_record_aux_unavailable);
        try testing.expectEqual(@as(u32, 0), c.n_bundle_carrier_records);
        try testing.expectEqual(@as(u32, 0), c.n_bundle_pairs_compared);
        if (state == .not_collected) {
            try testing.expectEqual(@as(u32, 1), c.u_aux_not_collected);
            try testing.expectEqual(@as(u32, 0), c.n_aux_records_attempted);
        } else {
            try testing.expectEqual(@as(u32, 1), c.u_aux_collection_oom);
            try testing.expectEqual(@as(u32, 3), c.n_aux_records_attempted);
            try testing.expectEqual(@as(u32, 3), c.u_aux_records_lost);
        }
        try expectRecordPartition(c);
    }
}

test "bundles: complete empty AUX names the absent population" {
    var f: Fixture = .{};
    f.init();
    const c = run(&f);
    try testing.expectEqual(@as(u32, 0), c.n_bundle_carrier_records);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_population_absent);
    try testing.expectEqual(@as(u32, 0), c.u_aux_not_collected);
}

test "bundles: every unavailable stamp state partitions both comparisons" {
    inline for (.{
        sketch.BundleStampState.unattempted,
        sketch.BundleStampState.out_of_memory,
        sketch.BundleStampState.rail_invariant,
    }) |state| {
        var f: Fixture = .{};
        f.init();
        f.add(idx(1, 0), 1, detail(.merged_licensed));
        const lat = f.lat();
        var s = f.sk();
        s.bundle_stamp_state = state;
        var c: counts.Counts = .{};
        bundles.check(cell.View.init(&lat), s, &c);
        try testing.expectEqual(@as(u32, 1), c.u_bundle_identity_unavailable);
        try testing.expectEqual(@as(u32, 1), c.u_bundle_detail_identity_unavailable);
        switch (state) {
            .unattempted => try testing.expectEqual(@as(u32, 1), c.u_bundle_stamp_unattempted),
            .out_of_memory => try testing.expectEqual(@as(u32, 1), c.u_bundle_stamp_oom),
            .rail_invariant => try testing.expectEqual(@as(u32, 1), c.u_bundle_stamp_rail_invariant),
            .complete => unreachable,
        }
        try expectPairPartitions(c);
    }
}

test "bundles: complete stamp with an unnumbered roster is inconsistent" {
    var f: Fixture = .{};
    f.init();
    f.sets[0] = .{ .origin = .fan_rail, .members = &members_01 };
    f.n_sets = 1;
    f.add(idx(1, 0), 1, detail(.merged_licensed));
    const c = run(&f);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_roster_inconsistent);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_identity_unavailable);
    try testing.expectEqual(@as(u32, 1), c.u_bundle_detail_identity_unavailable);
    try expectPairPartitions(c);
}

test "bundles: audit leaves cells, records, and sketch payload unchanged" {
    var f: Fixture = .{};
    f.init();
    f.sets[0] = .{ .origin = .fan_rail, .bundle = 1, .members = &members_01 };
    f.n_sets = 1;
    f.add(idx(1, 0), 1, detail(.merged_foreign));
    const before_cells = f.cells;
    const before_recs = f.recs;
    const before_sets = f.sets;
    const n_recs = f.n_recs;
    const n_sets = f.n_sets;
    _ = run(&f);
    try testing.expectEqualSlices(lattice.Cell, &before_cells, &f.cells);
    try testing.expectEqualSlices(lattice.Aux, before_recs[0..n_recs], f.recs[0..n_recs]);
    try testing.expectEqualSlices(ledger.Bundle, before_sets[0..n_sets], f.sets[0..n_sets]);
}
