//! Cell-writer contract for the label rasterizers (`labels.zig` for node
//! and cluster titles, `labels_edge.zig` for edge and tap labels).
//!
//! Every label cell in a Lattice is claimed through exactly one of the
//! three functions below. They were three separate literals before — one
//! per writer — which is how a field could quietly be reset in two of them
//! and inherited in the third. Collected here, the contract is one
//! statement:
//!
//!   A LABEL WRITE REPLACES THE WHOLE CELL. A label glyph is opaque: it
//!   conducts nothing and inherits nothing from the ink it covers, so the
//!   neighbour mask is cleared and `stroke_kind` / `shape` go back to their
//!   defaults along with it. The write is unconditional — the CALLER owns
//!   the decision about whether the cell may be claimed (node writers
//!   demand their own interior, edge writers demand emptiness plus blank
//!   flanks; the ON-RUN edge writer, labels_onrun.zig, demands emptiness
//!   for every covered cell EXCEPT exactly one verified own-edge private
//!   dropper `edge_segment`, which it legally interrupts), and no policy
//!   lives here.
//!
//! OWNERSHIP. Each claimed glyph head also files a `.label_owner` record
//! naming the node, cluster or edge whose label it is. A `label_char` Cell
//! holds a codepoint and nothing else, so ownership is exactly the fact it
//! cannot express — and the fact every downstream question about labels
//! ("whose text is this?", "does this run cross someone's label?") needs.
//! Continuation columns file nothing: `label_cont` is DEFINED as the tail
//! of the head immediately west, so its owner is already derivable from
//! the grid and a record would restate it.
//!
//! Imports: `std`, `lattice.zig`, `aux.zig`.

const std = @import("std");
const lattice = @import("../lattice.zig");
const aux = @import("aux.zig");

/// Whose label a written glyph belongs to.
pub const Owner = struct {
    kind: lattice.LabelOwnerKind,
    id: u32,
};

/// Claim `(x, y)` for one label codepoint and file its owner.
/// guarded-by: labels_write_test.zig "a glyph write resets every field of the cell it covers"
/// guarded-by: labels_write_test.zig "a glyph write files one owner record; a continuation files none"
pub fn writeGlyph(
    lat: *lattice.Lattice,
    x: u32,
    y: u32,
    cp: u21,
    owner: Owner,
    sink: aux.Sink,
) void {
    lat.at(x, y).* = .{ .occupant = .{ .label_char = cp }, .neighbours = .{} };
    aux.record(sink, lat.cellIndex(x, y), .label_owner, owner.id, @intFromEnum(owner.kind));
}

/// Claim `(x, y)` as the continuation column of the East-Asian-Wide glyph
/// whose head sits immediately west. Same whole-cell reset: a continuation
/// is as opaque as the head it belongs to. Files no record (see the module
/// doc's ownership note).
/// guarded-by: labels_write_test.zig "a continuation write resets every field, exactly as a glyph write does"
pub fn writeCont(lat: *lattice.Lattice, x: u32, y: u32) void {
    lat.at(x, y).* = .{ .occupant = .label_cont, .neighbours = .{} };
}

/// Claim a glyph's whole `span`-cell footprint: the head at `(x, y)` and
/// the continuation columns that follow it. `span` comes from
/// `labels.cellSpan`, the one number every probe and every writer reserves
/// by, so a wide glyph can never paint more cells than it claimed.
/// guarded-by: labels_write_test.zig "a span write claims head plus continuations and resets both"
pub fn writeSpan(
    lat: *lattice.Lattice,
    x: u32,
    y: u32,
    cp: u21,
    span: u32,
    owner: Owner,
    sink: aux.Sink,
) void {
    writeGlyph(lat, x, y, cp, owner, sink);
    var i: u32 = 1;
    while (i < span) : (i += 1) writeCont(lat, x + i, y);
}

test {
    _ = @import("labels_write_test.zig");
}
