//! Painted-arm validator: every arm a stroke cell paints must be explained
//! by the owners the raster recorded at that cell.
//!
//! A junction glyph (three or four arms) asserts that the owner set changes
//! there — a second edge joins or leaves. The Cell names one owner; every
//! further edge with ink in that cell is on the side table (`.carrier` with
//! merged bits, `.rail_member`, `.tap`). A junction glyph whose owner set
//! has one member asserts a join that does not exist: the reader traces a
//! relation no source declares. That is a fabrication, priced with the
//! foreign junction (confluence severity note), not a refusal.
//!
//! A one-armed stroke cell is a run that stops in open space: no port, no
//! decoration and no foreign occupant ended it — the producer's route
//! simply turned back or ran out. Both forms are the two ends of one
//! producer defect, a route that visits a cell twice, so one counter carries
//! them: the tee no second edge joins and the stub nothing stops.
//!
//! Only `.edge_segment` cells are read. A node border carries several
//! writers' port arms by design, a cluster frame holds welded ink under the
//! frame-solid convention, and a decoration cell's lateral arms are the
//! decoration-cell tally's (`arrow_base.lateral_arms`).
//!
//! PAINTED post-raster scan over the final `Lattice` and its side table;
//! reads, never mutates. When the side table was not collected, the owner
//! set is unknowable and no junction is counted; the stub form needs no
//! records and is counted regardless. Allowed imports: `std`, `lattice.zig`
//! (raster zone).

const std = @import("std");
const lattice = @import("../lattice.zig");

/// The side-table records filed at linear cell index `idx` (the table is
/// sorted by cell first).
fn recordsAt(aux: []const lattice.Aux, idx: u32) []const lattice.Aux {
    var lo: usize = 0;
    var hi: usize = aux.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (aux[mid].cell < idx) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < aux.len and aux[end].cell == idx) end += 1;
    return aux[lo..end];
}

/// True when some record at `idx` names an edge other than `owner` whose
/// bits are in the cell's mask: a merged carrier (any flavour but
/// `suppressed`, which contributed no bits), a rail member riding the run,
/// or a tap branching from it.
fn hasSecondOwner(aux: []const lattice.Aux, idx: u32, owner: lattice.EdgeId) bool {
    for (recordsAt(aux, idx)) |r| {
        if (r.value == owner) continue;
        switch (r.kind) {
            .carrier => if (r.detail != @intFromEnum(lattice.CarrierKind.suppressed)) return true,
            .rail_member, .tap => return true,
            .port, .label_owner, .intrusion => {},
        }
    }
    return false;
}

/// Count the stroke cells whose painted arms no owner set explains: a
/// junction glyph with exactly one owner, or a run that stops in open space.
/// @guarded-by: arms_test.zig "a tee one edge owns is unexplained; a merged carrier, a rail member or a tap explains it"
/// @guarded-by: arms_test.zig "a one-armed stroke is a run that stops in open space; a straight run and a corner are not"
/// @guarded-by: arms_test.zig "a suppressed carrier contributes no bits, so it explains no arm"
/// @guarded-by: arms_test.zig "without a collected side table a tee is not judged; a stub still is"
/// @guarded-by: arms_test.zig "a border tee, a frame cross and a head's lateral arm are other tallies' business"
pub fn unexplained(lat: *const lattice.Lattice) u32 {
    var count: u32 = 0;
    const table_complete = lat.aux_collection.state == .complete;
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.atConst(x, y);
            const owner = switch (cell.occupant) {
                .edge_segment => |seg| seg.edge,
                else => continue,
            };
            const arms = @popCount(cell.neighbours.toMask());
            if (arms <= 1) {
                count += 1;
            } else if (arms >= 3 and table_complete) {
                if (!hasSecondOwner(lat.aux, lat.cellIndex(x, y), owner)) count += 1;
            }
        }
    }
    return count;
}

test {
    _ = @import("arms_test.zig");
}
