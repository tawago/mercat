const std = @import("std");
const prim = @import("prim");
const unicode = @import("unicode");
const lattice = @import("../lattice.zig");
const aux = @import("aux.zig");

pub const Owner = struct {
    kind: lattice.LabelOwnerKind,
    id: u32,
};

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

/// @guarded-by: labels_write_test.zig "a continuation write resets every field, exactly as a glyph write does"
pub fn writeCont(lat: *lattice.Lattice, x: u32, y: u32) void {
    lat.at(x, y).* = .{ .occupant = .label_cont, .neighbours = .{} };
}

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

pub fn sentinelToSpace(cp: u21) u21 {
    return if (cp == prim.LINE_BREAK) @as(u21, ' ') else cp;
}

/// @guarded-by: labels_eaw_test.zig "cellSpan is 1 for every ASCII codepoint including tab"
pub fn cellSpan(cp: u21) u32 {
    return if (prim.codepointWidth(cp) == 2) 2 else 1;
}

pub const LabelCell = struct {
    value: u21,
    span: u8,
};

pub const Run = struct {
    cells: []const LabelCell,
    cell_count: u32,
    width: u32,
};

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

pub const GlyphTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(lattice.Glyph) = .empty,
    index_of: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) GlyphTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GlyphTable) void {
        self.index_of.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

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

    pub fn finish(self: *GlyphTable) error{OutOfMemory}![]const lattice.Glyph {
        const out = try self.entries.toOwnedSlice(self.allocator);
        self.index_of.deinit(self.allocator);
        return out;
    }
};

const Piece = struct {
    bytes: []const u8,
    cp: ?u21,
    span: u8,
};

const Pieces = struct {
    text: []const u8,
    base: usize = 0,
    cursor: unicode.LegacyCursor,

    fn init(text: []const u8) Pieces {
        return .{ .text = text, .cursor = unicode.LegacyCursor.init(text) };
    }

    fn next(self: *Pieces) ?Piece {
        if (self.cursor.next()) |glyph| return pieceOf(glyph);
        const at = self.base + self.cursor.index;
        if (at >= self.text.len) return null;
        self.base = at + 1;
        self.cursor = unicode.LegacyCursor.init(self.text[self.base..]);
        return .{ .bytes = self.text[at..self.base], .cp = @as(u21, self.text[at]), .span = 1 };
    }

    fn pieceOf(glyph: unicode.Glyph) Piece {
        std.debug.assert(glyph.bytes.len > 0);
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
