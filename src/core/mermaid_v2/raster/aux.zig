//! Builder for the lattice's position-keyed side table (`lattice.Aux`).
//!
//! Producers hand facts to a `Collector` while they write cells; `finish`
//! sorts the accumulated records into the canonical (cell, kind, value)
//! order and hands the slice to the `Lattice`. The collector is the ONLY
//! writer of that bundle — no later pass edits records, which is what
//! makes the anti-desync law in `lattice.zig` mechanically true.
//!
//! Every rasterization collects: the table is part of the raster IR, not
//! an optional extra. A null `Sink` remains only for synthetic per-cell
//! writers constructed outside a rasterization.
//!
//! Deliberately Sketch-blind (enforced by a `tools/lint/imports.zig` row):
//! this file may reach `lattice.zig` and nothing else. A builder that
//! could see the Sketch would be able to record what the layout INTENDED
//! rather than what the raster DID, and the bundle would stop being
//! evidence.

const std = @import("std");
const lattice = @import("../lattice.zig");

/// Where a producer sends records. `null` means "this rasterization is
/// not collecting" — the one mechanism for switching the bundle off, so
/// enabled-ness is never represented twice.
pub const Sink = ?*Collector;

/// Accumulates records in producer order; `finish` sorts them.
pub const Collector = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(lattice.Aux) = .empty,
    state: lattice.AuxCollectionState = .complete,
    /// Every `record` call made through this collector, including the append
    /// that poisoned it and all later allocation-free attempts.
    attempted_records: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Collector {
        return .{ .allocator = allocator };
    }

    /// Release retained scratch storage. Finished table slices borrow that
    /// storage, so callers using a non-arena allocator must deinitialize only
    /// after the table is no longer needed.
    pub fn deinit(self: *Collector) void {
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Value report attached to the lattice alongside `finish()`'s table.
    pub fn report(self: *const Collector) lattice.AuxCollectionReport {
        return .{
            .state = self.state,
            .attempted_records = self.attempted_records,
        };
    }

    /// Sort into (cell, kind, value) order and return the complete table. A
    /// poisoned collector returns an empty table, never its retained prefix.
    /// `std.mem.sort` is stable, so records that tie on the key keep the
    /// order their producers wrote them in — the table is deterministic
    /// for a deterministic raster.
    pub fn finish(self: *Collector) []const lattice.Aux {
        if (self.state == .out_of_memory) {
            std.debug.assert(self.records.items.len == 0);
            return &.{};
        }
        std.debug.assert(self.state == .complete);
        const items = self.records.items;
        std.mem.sort(lattice.Aux, items, {}, lattice.Aux.lessThan);
        return items;
    }
};

/// Record one fact at `cell` (a row-major linear index, see
/// `Lattice.cellIndex`). A no-op on a null sink.
///
/// Callers must respect the anti-desync law: `kind`/`value`/`detail` may
/// only describe something the Cell at `cell` cannot itself express.
pub fn record(
    sink: Sink,
    cell: u32,
    kind: lattice.AuxKind,
    value: u32,
    detail: u8,
) void {
    const c = sink orelse return;
    c.attempted_records += 1;
    if (c.state == .out_of_memory) return;

    c.records.append(c.allocator, .{
        .cell = cell,
        .value = value,
        .kind = kind,
        .detail = detail,
    }) catch {
        c.records.deinit(c.allocator);
        c.records = .empty;
        c.state = .out_of_memory;
    };
}

/// A `Sink` plus the grid width.
///
/// Most producers hold the whole `Lattice` and can key a record with
/// `Lattice.cellIndex`. The per-cell writers do not: they are handed a
/// `*Cell` and its (x, y) precisely so they cannot reach anything else on
/// the grid. Bundling the width with the sink lets them key a record
/// positionally without regaining that reach, and keeps the widening of
/// their signatures to one parameter.
///
/// The default is inert (`sink = null`), so a synthetic caller writes
/// `.{}` and files nothing.
/// @guarded-by: aux_test.zig "a Recorder with no sink files nothing"
pub const Recorder = struct {
    sink: Sink = null,
    width: u32 = 0,

    pub fn init(sink: Sink, lat: *const lattice.Lattice) Recorder {
        return .{ .sink = sink, .width = lat.width };
    }

    /// Record one fact at (x, y). A no-op on an inert recorder.
    pub fn at(
        self: Recorder,
        x: u32,
        y: u32,
        kind: lattice.AuxKind,
        value: u32,
        detail: u8,
    ) void {
        record(self.sink, y * self.width + x, kind, value, detail);
    }
};

const testing = std.testing;

test "Aux is compact and ordered by (cell, kind, value)" {
    try testing.expectEqual(@as(usize, 12), @sizeOf(lattice.Aux));
    const a: lattice.Aux = .{ .cell = 3, .value = 9, .kind = .port };
    const smaller: lattice.Aux = .{ .cell = 3, .value = 4, .kind = .port };
    const later: lattice.Aux = .{ .cell = 4, .value = 0, .kind = .port };
    try testing.expect(lattice.Aux.lessThan({}, smaller, a));
    try testing.expect(!lattice.Aux.lessThan({}, a, smaller));
    try testing.expect(lattice.Aux.lessThan({}, a, later));
    try testing.expect(!lattice.Aux.lessThan({}, a, a));
}

test "Lattice defaults to AUX not collected and copies collection reports" {
    var buf: [1]lattice.Cell = .{lattice.Cell.empty};
    const fresh = lattice.Lattice{ .width = 1, .height = 1, .cells = &buf };
    try testing.expectEqual(@as(usize, 0), fresh.aux.len);
    try testing.expectEqual(lattice.AuxCollectionState.not_collected, fresh.aux_collection.state);

    const failed: lattice.AuxCollectionReport = .{ .state = .out_of_memory, .attempted_records = 7 };
    const original = lattice.Lattice{
        .width = 1,
        .height = 1,
        .cells = &buf,
        .aux_collection = failed,
    };
    const copied = original;
    try testing.expectEqual(failed.state, copied.aux_collection.state);
    try testing.expectEqual(failed.attempted_records, copied.aux_collection.attempted_records);
}

test "collector sorts records and keeps producer order on ties" {
    var c = Collector.init(testing.allocator);
    defer c.deinit();
    record(&c, 9, .port, 1, 0);
    record(&c, 4, .port, 7, 0);
    record(&c, 4, .port, 2, 0);
    record(&c, 4, .port, 2, 11);
    record(&c, 4, .port, 2, 22);

    const table = c.finish();
    try testing.expectEqual(@as(usize, 5), table.len);
    try testing.expectEqual(lattice.AuxCollectionState.complete, c.report().state);
    try testing.expectEqual(@as(u64, 5), c.report().attempted_records);
    try testing.expectEqual(@as(u32, 2), table[0].value);
    try testing.expectEqual(@as(u32, 7), table[3].value);
    try testing.expectEqual(@as(u32, 9), table[4].cell);
    try testing.expectEqual(@as(u8, 0), table[0].detail);
    try testing.expectEqual(@as(u8, 11), table[1].detail);
    try testing.expectEqual(@as(u8, 22), table[2].detail);
}

test "a null sink is the off switch" {
    record(null, 0, .port, 1, 0);
    record(null, 7, .port, 2, 0);
}

fn recordMany(c: *Collector, count: usize) void {
    for (0..count) |i| record(c, @intCast(count - i), .carrier, @intCast(i), @truncate(i));
}

test "collector distinguishes complete empty from OOM and counts after poison" {
    var complete = Collector.init(testing.allocator);
    defer complete.deinit();
    try testing.expectEqual(@as(usize, 0), complete.finish().len);
    try testing.expectEqual(lattice.AuxCollectionState.complete, complete.report().state);
    try testing.expectEqual(@as(u64, 0), complete.report().attempted_records);

    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    var poisoned = Collector.init(failing.allocator());
    defer poisoned.deinit();
    recordMany(&poisoned, 7);
    try testing.expectEqual(lattice.AuxCollectionState.out_of_memory, poisoned.report().state);
    try testing.expectEqual(@as(usize, 0), poisoned.finish().len);
    try testing.expectEqual(@as(u64, 7), poisoned.report().attempted_records);
    try testing.expectEqual(@as(usize, 0), poisoned.records.capacity);

    const allocations = failing.alloc_index;
    record(&poisoned, 99, .port, 99, 0);
    try testing.expectEqual(allocations, failing.alloc_index);
    try testing.expectEqual(@as(u64, 8), poisoned.report().attempted_records);
}

test "collector allocation sweep poisons every growth without a prefix" {
    const count = 128;
    var measured_allocator = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
    var measured = Collector.init(measured_allocator.allocator());
    recordMany(&measured, count);
    try testing.expectEqual(@as(usize, count), measured.finish().len);
    const growth_points = measured_allocator.alloc_index;
    try testing.expect(growth_points > 1);
    measured.deinit();

    for (0..growth_points) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        var c = Collector.init(failing.allocator());
        recordMany(&c, count);
        try testing.expect(failing.has_induced_failure);
        try testing.expectEqual(lattice.AuxCollectionState.out_of_memory, c.report().state);
        try testing.expectEqual(@as(u64, count), c.report().attempted_records);
        try testing.expectEqual(@as(usize, 0), c.finish().len);
        try testing.expectEqual(@as(usize, 0), c.records.capacity);

        const allocations = failing.alloc_index;
        record(&c, 999, .port, 999, 0);
        try testing.expectEqual(allocations, failing.alloc_index);
        try testing.expectEqual(@as(u64, count + 1), c.report().attempted_records);
        c.deinit();
    }
}

test {
    _ = @import("aux_test.zig");
}
