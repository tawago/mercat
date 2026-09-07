//! Cell-writer contract for the label rasterizers (`labels.zig` for node
//! and cluster titles, `labels_edge.zig` and the `labels_onrun*.zig` pair
//! for edge and tap labels).
//!
//! Every label cell in a Lattice is claimed through exactly one of the
//! write functions below. They were three separate literals before — one
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
//! WHAT A CELL HOLDS. A label is a sequence of terminal graphemes, and a
//! `label_char` cell holds one grapheme HEAD: the scalar itself when the
//! grapheme is a single codepoint, or a reference into the lattice's
//! interned `glyphs` table when it is several (a base plus its combining
//! marks, a VS16 sequence, a ZWJ family, a flag, a skin tone). The text →
//! cells decision is made ONCE, by `prepare`, and every writer then walks
//! the same `Run.cells`; five writers each decoding the text for
//! themselves is how the codepoint-per-cell assumption drifted into the
//! cursor arithmetic in the first place. Cells claimed per grapheme = its
//! display width, with two frozen ASCII skews (`cellSpan`).
//!
//! OWNERSHIP. Each claimed glyph head also files a `.label_owner` record
//! naming the node, cluster or edge whose label it is. A `label_char` Cell
//! holds a grapheme head and nothing else, so ownership is exactly the fact
//! it cannot express — and the fact every downstream question about labels
//! ("whose text is this?", "does this run cross someone's label?") needs.
//! Continuation columns file nothing: `label_cont` is DEFINED as the tail
//! of the head immediately west, so its owner is already derivable from
//! the grid and a record would restate it.
//!
//! Imports: `std`, `prim`, `unicode`, `lattice.zig`, `aux.zig`.

const std = @import("std");
const prim = @import("prim");
const unicode = @import("unicode");
const lattice = @import("../lattice.zig");
const aux = @import("aux.zig");

/// Whose label a written glyph belongs to.
pub const Owner = struct {
    kind: lattice.LabelOwnerKind,
    id: u32,
};

/// Claim `(x, y)` for one label grapheme head and file its owner. `cp` is
/// the `label_char` value: a scalar or an interned-glyph reference.
/// @guarded-by: labels_write_test.zig "a glyph write resets every field of the cell it covers"
/// @guarded-by: labels_write_test.zig "a glyph write files one owner record; a continuation files none"
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
/// @guarded-by: labels_write_test.zig "a continuation write resets every field, exactly as a glyph write does"
pub fn writeCont(lat: *lattice.Lattice, x: u32, y: u32) void {
    lat.at(x, y).* = .{ .occupant = .label_cont, .neighbours = .{} };
}

/// Claim a glyph's whole `span`-cell footprint: the head at `(x, y)` and
/// the continuation columns that follow it. `span` comes from
/// `LabelCell.span` (via `prepare`) or `cellSpan`, the one number every
/// probe and every writer reserves by, so a wide glyph can never paint
/// more cells than it claimed.
/// @guarded-by: labels_write_test.zig "a span write claims head plus continuations and resets both"
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

/// Write a whole prepared label from `(x, y)` eastward: every cell's head
/// and continuations, exactly `run.cell_count` cells. The caller has
/// already verified that footprint may be claimed.
/// @guarded-by: labels_write_test.zig "a run write lays every cell out in order and claims exactly cell_count cells"
pub fn writeRun(
    lat: *lattice.Lattice,
    x: u32,
    y: u32,
    run: Run,
    owner: Owner,
    sink: aux.Sink,
) void {
    var cx: u32 = x;
    for (run.cells) |cell| {
        writeSpan(lat, cx, y, cell.value, cell.span, owner, sink);
        cx += cell.span;
    }
    std.debug.assert(cx == x + run.cell_count);
}

/// Map the line-break sentinel (0x0A) to a space; edge and cluster
/// labels don't support multi-line, unlike node labels (whose lines are
/// split on it before they reach a writer).
pub fn sentinelToSpace(cp: u21) u21 {
    return if (cp == prim.LINE_BREAK) @as(u21, ' ') else cp;
}

/// Lattice cells one single-codepoint grapheme occupies: an East-Asian-
/// Wide or emoji-presentation codepoint claims 2, everything else 1.
///
/// Deliberately NOT `prim.codepointWidth`: a tab (4 columns) stays ONE
/// cell and the C0 controls (0 columns, including the `prim.LINE_BREAK`
/// sentinel) stay one cell. That freezes the pre-existing cursor
/// arithmetic for every ASCII codepoint, which is what makes an
/// all-ASCII lattice bit-identical to the pre-continuation pipeline.
/// The tab column/cell skew is documented, not fixed.
/// @guarded-by: labels_eaw_test.zig "cellSpan is 1 for every ASCII codepoint including tab"
pub fn cellSpan(cp: u21) u32 {
    return if (prim.codepointWidth(cp) == 2) 2 else 1;
}

/// Lattice cells `text` occupies: the sum of its graphemes' spans, walked
/// exactly as `prepare` walks them. The one number every writer and every
/// free-space probe reserves by, so cells reserved and cells written can
/// never disagree.
/// @guarded-by: labels_eaw_test.zig "cellSpanOf equals prim.displayWidth for tab- and control-free text"
pub fn cellSpanOf(text: []const u8) u32 {
    var total: u32 = 0;
    var pieces = Pieces.init(text);
    while (pieces.next()) |piece| total += piece.span;
    return total;
}

/// One lattice write of a prepared label: the `label_char` value and the
/// cells it claims (head plus continuations).
pub const LabelCell = struct {
    value: u21,
    span: u8,
};

/// A label resolved to cells. `cells` is what the writers walk;
/// `cell_count` is the footprint every probe reserves; `width` is the
/// label's display columns as the layout measured it (`prim.displayWidth`),
/// which anchors are computed from — it differs from `cell_count` only by
/// the frozen tab/control skews.
pub const Run = struct {
    cells: []const LabelCell,
    cell_count: u32,
    width: u32,
};

/// Resolve `text` to cells: one `LabelCell` per grapheme, interning every
/// multi-codepoint grapheme into `table`. The sentinel becomes a space.
/// `cells` is allocated from `allocator` (the raster arena).
/// @guarded-by: labels_eaw_test.zig "a ZWJ family occupies two cells: head reference plus continuation, every byte interned"
pub fn prepare(allocator: std.mem.Allocator, table: *GlyphTable, text: []const u8) error{OutOfMemory}!Run {
    var cells: std.ArrayListUnmanaged(LabelCell) = .empty;
    errdefer cells.deinit(allocator);
    var total: u32 = 0;
    var pieces = Pieces.init(text);
    while (pieces.next()) |piece| {
        const value: u21 = if (piece.cp) |cp| sentinelToSpace(cp) else try table.intern(piece.bytes, piece.span);
        try cells.append(allocator, .{ .value = value, .span = piece.span });
        total += piece.span;
    }
    return .{
        .cells = try cells.toOwnedSlice(allocator),
        .cell_count = total,
        .width = prim.displayWidth(text),
    };
}

/// A `Run` for an ASCII literal, built at compile time: for synthetic
/// writers constructed outside a rasterization (tests), where there is no
/// table and nothing to intern. Every ASCII codepoint spans one cell.
pub fn asciiRun(comptime text: []const u8) Run {
    const cells = comptime blk: {
        var out: [text.len]LabelCell = undefined;
        for (text, 0..) |byte, i| {
            std.debug.assert(byte < 0x80);
            out[i] = .{ .value = sentinelToSpace(byte), .span = 1 };
        }
        break :blk out;
    };
    return .{ .cells = &cells, .cell_count = text.len, .width = text.len };
}

/// Builder for `Lattice.glyphs`: interns multi-codepoint graphemes,
/// deduplicated by bytes, and hands the finished slice to the lattice.
/// One builder per rasterization of a fresh lattice.
pub const GlyphTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(lattice.Glyph) = .empty,
    index_of: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) GlyphTable {
        return .{ .allocator = allocator };
    }

    /// Release scratch storage. Interned bytes are arena-owned, like every
    /// other lattice side table.
    pub fn deinit(self: *GlyphTable) void {
        self.index_of.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// The reference for `bytes`, copying them on first sight so the
    /// lattice never borrows a label string. A full reference space is
    /// reported as OutOfMemory: the table cannot grow past it.
    pub fn intern(self: *GlyphTable, bytes: []const u8, width: u8) error{OutOfMemory}!u21 {
        if (self.index_of.get(bytes)) |index| return lattice.glyphRef(index);
        const index = self.entries.items.len;
        if (index >= lattice.MAX_GLYPHS) return error.OutOfMemory;
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        try self.entries.append(self.allocator, .{ .bytes = owned, .width = width });
        errdefer _ = self.entries.pop();
        try self.index_of.put(self.allocator, owned, @intCast(index));
        return lattice.glyphRef(index);
    }

    /// The finished table, in reference order. Consumes the builder; on
    /// failure the builder is left intact for its owner's `deinit`.
    pub fn finish(self: *GlyphTable) error{OutOfMemory}![]const lattice.Glyph {
        const out = try self.entries.toOwnedSlice(self.allocator);
        self.index_of.deinit(self.allocator);
        return out;
    }
};

/// One cell-sized unit of a label on its way to the lattice: a grapheme,
/// or one malformed byte. `cp` is set when the piece is a single codepoint
/// (it stores as the scalar); null means the bytes are a multi-codepoint
/// grapheme to intern.
const Piece = struct {
    bytes: []const u8,
    cp: ?u21,
    span: u8,
};

/// Walks a label exactly as the width authority's compatibility measure
/// does (which is also how its strict measure segments text the strict
/// measure accepts): `LegacyCursor` graphemes, and one raw one-cell piece
/// for each malformed byte the cursor stops at, after which a fresh cursor
/// resumes. Cells claimed and columns measured therefore agree on every
/// string; the only skews left are the two `cellSpan` freezes, which is
/// why a single-codepoint piece is spanned by `cellSpan` and only a
/// multi-codepoint one by the cursor's width.
const Pieces = struct {
    text: []const u8,
    /// Byte offset of `cursor.text` within `text`.
    base: usize = 0,
    cursor: unicode.LegacyCursor,

    fn init(text: []const u8) Pieces {
        return .{ .text = text, .cursor = unicode.LegacyCursor.init(text) };
    }

    fn next(self: *Pieces) ?Piece {
        if (self.cursor.next()) |glyph| return pieceOf(glyph);
        const at = self.base + self.cursor.index;
        if (at >= self.text.len) return null;
        // The cursor stopped at a malformed byte: one cell carrying the raw
        // byte value, then resume on the next byte.
        self.base = at + 1;
        self.cursor = unicode.LegacyCursor.init(self.text[self.base..]);
        return .{ .bytes = self.text[at..self.base], .cp = @as(u21, self.text[at]), .span = 1 };
    }

    fn pieceOf(glyph: unicode.Glyph) Piece {
        std.debug.assert(glyph.bytes.len > 0);
        // A cursor grapheme is valid UTF-8, so its first sequence decodes.
        const first_len = std.unicode.utf8ByteSequenceLength(glyph.bytes[0]) catch unreachable;
        if (first_len == glyph.bytes.len) {
            const cp = std.unicode.utf8Decode(glyph.bytes) catch unreachable;
            return .{ .bytes = glyph.bytes, .cp = cp, .span = @intCast(cellSpan(cp)) };
        }
        std.debug.assert(glyph.width == 1 or glyph.width == 2);
        return .{ .bytes = glyph.bytes, .cp = null, .span = @intCast(glyph.width) };
    }
};

test {
    _ = @import("labels_write_test.zig");
}
