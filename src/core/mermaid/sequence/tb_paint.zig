//! Paints one placed top-down state, layer by layer, onto the owner overlay, then copies it onto
//! the shared canvas: boxes, lifelines, activations, message lines, labels and notes,
//! boundaries.

const std = @import("std");
const Allocator = std.mem.Allocator;
const seq = @import("seq.zig");
const Texts = @import("tb_text.zig").Texts;
const Rows = @import("tb_rows.zig").Rows;
const Layout = @import("tb_columns.zig").Layout;
const ink_mod = @import("ink.zig");

const Ink = ink_mod.Ink;
const Error = ink_mod.Error;
const rect = ink_mod.rect;
const rounded = ink_mod.rounded;
const square = ink_mod.square;

pub const glyph = struct {
    pub const lifeline: u21 = '┆';
    pub const solid: u21 = '─';
    pub const dashed: u21 = '┄';
    pub const head_right: u21 = '►';
    pub const head_left: u21 = '◄';
    pub const cross: u21 = '×';
    pub const open_right: u21 = '>';
    pub const open_left: u21 = '<';
};

const Painter = struct {
    ink: *Ink,
    s: *const seq.Sequence,
    texts: *const Texts,
    rows: *const Rows,
    layout: *const Layout,

    fn rr(self: *const Painter, p: usize, row: u32) i32 {
        return @intCast(self.rows.right(p, row, row));
    }

    fn rl(self: *const Painter, p: usize, row: u32) i32 {
        return @intCast(self.rows.left(p, row, row));
    }
};

pub fn paint(allocator: Allocator, arena: Allocator, s: *const seq.Sequence, texts: *const Texts, rows: *const Rows, layout: *const Layout) ![]const u8 {
    var ink = try Ink.init(arena, layout.width, rows.count());
    const p = Painter{ .ink = &ink, .s = s, .texts = texts, .rows = rows, .layout = layout };
    try boxes(&p);
    try lifelines(&p);
    try bars(&p);
    for (s.steps, 0..) |step, ix| switch (step) {
        .message => |msg| if (msg.from == msg.to) try selfMessage(&p, msg, ix) else try message(&p, msg, ix),
        .note => {},
    };
    for (s.steps, 0..) |step, ix| switch (step) {
        .message => |msg| try labelLines(&p, msg.label, ix),
        .note => |note| try noteBox(&p, note, ix),
    };
    for (s.frags, 0..) |_, f| try frame(&p, f);
    return ink.toText(allocator);
}

fn boxes(p: *const Painter) Error!void {
    const bottom: i32 = @intCast(p.rows.box_rows - 1);
    for (p.s.names, 0..) |name, i| {
        const x = p.layout.x[i];
        const left = x - p.layout.half_l[i];
        try rect(p.ink, left, 0, x + p.layout.half_r[i], bottom, rounded, .box, false);
        const lines = p.texts.of(name);
        const inner: i32 = @intCast(p.texts.widest(name));
        const top: i32 = 1 + @divFloor(bottom - 1 - @as(i32, @intCast(lines.len)), 2);
        for (lines, 0..) |line, k| {
            const col = left + 2 + @divFloor(inner - @as(i32, @intCast(line.width)), 2);
            try ink_mod.Ink.text(p.ink, col, top + @as(i32, @intCast(k)), line, .label);
        }
    }
}

fn lifelines(p: *const Painter) Error!void {
    for (p.layout.x, 0..) |x, i| {
        var r = p.rows.box_rows;
        while (r < p.rows.count()) : (r += 1) {
            if (p.rl(i, r) == 0) try p.ink.put(x, @intCast(r), glyph.lifeline, .lifeline);
        }
    }
}

fn bars(p: *const Painter) Error!void {
    for (p.s.bars, p.rows.bars) |bar, br| {
        const c = p.layout.x[bar.part] + @as(i32, bar.depth) - 1;
        if (!bar.joined) {
            try rect(p.ink, c - 1, @intCast(br.first), c + 1, @intCast(br.last), square, .bar, false);
            var r: i32 = @intCast(br.first + 1);
            while (r < br.last) : (r += 1) {
                if (p.ink.owner(c, r) == .bar) p.ink.at(c, r).?.* = .{};
            }
            continue;
        }
        const join: i32 = @intCast(br.first);
        p.ink.at(c - 1, join).?.glyph = '├';
        p.ink.at(c + 1, join).?.glyph = '┤';
        const last: i32 = @intCast(br.last);
        if (last == join) continue;
        try rect(p.ink, c - 1, join + 1, c + 1, last, square, .bar, false);
        if (last == join + 1) continue;
        p.ink.at(c - 1, join + 1).?.glyph = '│';
        p.ink.at(c, join + 1).?.* = .{};
        p.ink.at(c + 1, join + 1).?.glyph = '│';
    }
}

fn lineGlyph(kind: seq.ArrowKind) u21 {
    return if (kind.isDashed()) glyph.dashed else glyph.solid;
}

/// The receiver-end cell: an arrowhead, a cross, an open end, or the line itself.
pub fn decoration(kind: seq.ArrowKind, rightward: bool) u21 {
    return switch (kind) {
        .solid_arrow, .dashed_arrow => if (rightward) glyph.head_right else glyph.head_left,
        .solid_cross, .dashed_cross => glyph.cross,
        .solid_open, .dashed_open => if (rightward) glyph.open_right else glyph.open_left,
        .solid_line, .dashed_line => lineGlyph(kind),
    };
}

fn message(p: *const Painter, msg: seq.Message, ix: usize) Error!void {
    const row = p.rows.steps[ix].stroke;
    const y: i32 = @intCast(row);
    const rightward = msg.to > msg.from;
    const lo = @min(msg.from, msg.to);
    const hi = @max(msg.from, msg.to);
    const start = p.layout.x[lo] + p.rr(lo, row) + 1;
    const end = p.layout.x[hi] - p.rl(hi, row) - 1;
    const tip = if (rightward) end else start;
    var c = start;
    while (c <= end) : (c += 1) {
        if (p.ink.owner(c, y) == .bar) continue;
        try p.ink.put(c, y, if (c == tip) decoration(msg.kind, rightward) else lineGlyph(msg.kind), .stroke);
    }
}

fn selfMessage(p: *const Painter, msg: seq.Message, ix: usize) Error!void {
    const sr = p.rows.steps[ix];
    const y: i32 = @intCast(sr.stroke);
    const corner = p.layout.loop_col[ix];
    const out = corner - 2;
    const line = lineGlyph(msg.kind);
    try p.ink.put(out, y, line, .stroke);
    try p.ink.put(out + 1, y, line, .stroke);
    try p.ink.put(corner, y, '┐', .stroke);
    try p.ink.put(out, y + 1, decoration(msg.kind, false), .stroke);
    try p.ink.put(out + 1, y + 1, line, .stroke);
    try p.ink.put(corner, y + 1, '┘', .stroke);
}

fn labelLines(p: *const Painter, t: seq.TextIx, ix: usize) Error!void {
    const sr = p.rows.steps[ix];
    for (p.texts.of(t), 0..) |line, k| {
        try p.ink.text(p.layout.label_col[ix], @intCast(sr.first + k), line, .label);
    }
}

fn noteBox(p: *const Painter, note: seq.Note, ix: usize) Error!void {
    const sr = p.rows.steps[ix];
    const box = p.layout.notes[ix];
    try rect(p.ink, box.left, @intCast(sr.first), box.right, @intCast(sr.stroke), square, .note, true);
    const inner = box.right - box.left + 1 - 4;
    for (p.texts.of(note.text), 0..) |line, k| {
        const col = box.left + 2 + @divFloor(inner - @as(i32, @intCast(line.width)), 2);
        const y: i32 = @intCast(sr.first + 1 + k);
        var i: i32 = 0;
        while (i < line.width) : (i += 1) {
            const cell = p.ink.at(col + i, y) orelse continue;
            if (cell.owner == .note) cell.* = .{};
        }
        try p.ink.text(col, y, line, .note);
    }
}

fn frame(p: *const Painter, f: usize) Error!void {
    const fc = p.layout.frames[f];
    const fr = p.rows.frames[f];
    const frag = p.s.frags[f];
    var r = fr.top + 1;
    while (r < fr.bottom) : (r += 1) {
        if (std.mem.indexOfScalar(u32, fr.sides, r) != null) continue;
        try p.ink.put(fc.left, @intCast(r), '│', .frame);
        try p.ink.put(fc.right, @intCast(r), '│', .frame);
    }
    for (frag.operands, fr.sides, 0..) |op, side, oi| {
        const y: i32 = @intCast(side);
        const fill: u21 = if (oi == 0) '─' else '┄';
        var guard_lo: i32 = std.math.maxInt(i32);
        var guard_hi: i32 = std.math.minInt(i32);
        if (op.guard) |g| {
            guard_lo = p.layout.guard_col[f][oi];
            guard_hi = guard_lo + @as(i32, @intCast(p.texts.of(g)[0].width)) - 1;
        }
        var kind_lo: i32 = std.math.maxInt(i32);
        var kind_hi: i32 = std.math.minInt(i32);
        if (oi == 0) {
            kind_lo = fc.left + 3;
            kind_hi = kind_lo + @as(i32, @intCast(frag.kind.word().len)) - 1;
        }
        var c = fc.left;
        while (c <= fc.right) : (c += 1) {
            if ((c >= kind_lo and c <= kind_hi) or (c >= guard_lo and c <= guard_hi)) continue;
            const pad = c == kind_lo - 1 or c == kind_hi + 1 or c == guard_lo - 1 or c == guard_hi + 1;
            const g: u21 = if (c == fc.left)
                (if (oi == 0) '┌' else '├')
            else if (c == fc.right)
                (if (oi == 0) '┐' else '┤')
            else if (pad) ' ' else fill;
            try p.ink.put(c, y, g, .frame);
        }
        if (oi == 0) try p.ink.text(kind_lo, y, .{ .bytes = frag.kind.word(), .width = @intCast(frag.kind.word().len) }, .frame);
        if (op.guard) |g| {
            for (p.texts.of(g), 0..) |line, k| {
                try p.ink.text(p.layout.guard_col[f][oi], y + @as(i32, @intCast(k)), line, if (k == 0) .frame else .label);
            }
        }
    }
    const bottom: i32 = @intCast(fr.bottom);
    var c = fc.left;
    while (c <= fc.right) : (c += 1) {
        const g: u21 = if (c == fc.left) '└' else if (c == fc.right) '┘' else '─';
        try p.ink.put(c, bottom, g, .frame);
    }
}
