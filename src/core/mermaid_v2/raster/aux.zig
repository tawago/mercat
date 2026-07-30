//! Builder for the lattice's position-keyed side table (`lattice.Aux`).
//!
//! Producers hand facts to a `Collector` while they write cells; `finish`
//! sorts the accumulated records into the canonical (cell, kind, value)
//! order and hands the slice to the `Lattice`. The collector is the ONLY
//! writer of that channel — no later pass edits records, which is what
//! makes the anti-desync law in `lattice.zig` mechanically true.
//!
//! Collection is opt-in per rasterization (`raster.Options.collect_aux`).
//! A producer that is not collecting is handed a null `Sink`, so the
//! score path — which rasterizes every candidate purely for defect
//! counts — pays one null test per event and allocates nothing.
//!
//! Deliberately Sketch-blind (enforced by a `tools/lint/imports.zig` row):
//! this file may reach `lattice.zig` and nothing else. A builder that
//! could see the Sketch would be able to record what the layout INTENDED
//! rather than what the raster DID, and the channel would stop being
//! evidence.

const std = @import("std");
const lattice = @import("../lattice.zig");

/// Where a producer sends records. `null` means "this rasterization is
/// not collecting" — the one mechanism for switching the channel off, so
/// enabled-ness is never represented twice.
pub const Sink = ?*Collector;

/// Accumulates records in producer order; `finish` sorts them.
pub const Collector = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(lattice.Aux) = .empty,
    /// Records lost to allocation failure. The side table is report-only,
    /// so a failed append must not fail a render; it must also not lie, so
    /// the loss is counted rather than swallowed.
    dropped: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Collector {
        return .{ .allocator = allocator };
    }

    /// Sort into (cell, kind, value) order and return the finished table.
    /// `std.mem.sort` is stable, so records that tie on the key keep the
    /// order their producers wrote them in — the table is deterministic
    /// for a deterministic raster.
    pub fn finish(self: *Collector) []const lattice.Aux {
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
    c.records.append(c.allocator, .{
        .cell = cell,
        .value = value,
        .kind = kind,
        .detail = detail,
    }) catch {
        c.dropped += 1;
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
/// guarded-by: aux_test.zig "a Recorder with no sink files nothing"
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

test {
    _ = @import("aux_test.zig");
}
