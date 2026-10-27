//! The left-right sequence diagram: participant boxes stacked at the left, lifelines running
//! right, one column per message, labels one word per row beside their message lines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const seq = @import("seq.zig");
const ladder = @import("../shared/ladder.zig");
const tb_text = @import("tb_text.zig");
const ink_mod = @import("ink.zig");

const Ink = ink_mod.Ink;
const Line = tb_text.Line;

pub const glyph = struct {
    pub const lifeline: u21 = '┄';
    pub const solid: u21 = '│';
    pub const dashed: u21 = '┆';
    pub const head_down: u21 = '▼';
    pub const head_up: u21 = '▲';
    pub const cross: u21 = '×';
    pub const open_down: u21 = 'v';
    pub const open_up: u21 = '^';
};

/// One message of the drawing. `col` is its message line's column (a self message: its loop's
/// right column); `gap` is the gap below participant `gap`.
const Msg = struct {
    from: usize,
    to: usize,
    kind: seq.ArrowKind,
    words: []const Line,
    wide: i32,
    gap: usize,
    hemmed: bool = false,
    offset: i32 = 0,
    r0: i32 = 0,
    r1: i32 = -1,
    col: i32 = 0,

    fn isSelf(self: Msg) bool {
        return self.from == self.to;
    }

    fn down(self: Msg) bool {
        return self.to > self.from;
    }

    fn lo(self: Msg) i32 {
        return if (self.isSelf()) self.col - 2 else self.col;
    }

    /// Columns a hemmed label takes left and right of its line; an even word puts the extra column right.
    fn halfL(self: Msg) i32 {
        return @divFloor(self.wide - 1, 2);
    }

    fn halfR(self: Msg) i32 {
        return @divFloor(self.wide, 2);
    }
};

const Plan = struct {
    msgs: []Msg,
    names: []const []const Line,
    box_w: i32,
    box_h: []i32,
    life: []i32,
    width: u32,
    height: u32,

    fn start(self: *const Plan) i32 {
        return self.box_w + 1;
    }

    fn above(self: *const Plan, p: usize) i32 {
        return @divFloor(self.box_h[p] - 1, 2);
    }

    fn below(self: *const Plan, p: usize) i32 {
        return self.box_h[p] - 1 - self.above(p);
    }

    /// The rows of message `m`'s line strictly between its lifelines.
    fn lineRows(self: *const Plan, m: Msg) [2]i32 {
        if (m.isSelf()) return .{ self.life[m.from] + 1, self.life[m.from] + 1 };
        const a = self.life[@min(m.from, m.to)];
        const b = self.life[@max(m.from, m.to)];
        return .{ a + 1, b - 1 };
    }

    fn crosses(self: *const Plan, line: Msg, label: Msg) bool {
        if (label.words.len == 0) return false;
        const r = self.lineRows(line);
        return r[0] <= label.r1 and label.r0 <= r[1];
    }
};

pub fn render(allocator: Allocator, s: *const seq.Sequence, max_width: u32) !ladder.Fit {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var plan = try layout(arena, s);
    if (plan.width > max_width) return .{ .too_wide = plan.width };
    return .{ .drawn = try paint(allocator, arena, &plan) };
}

fn layout(arena: Allocator, s: *const seq.Sequence) !Plan {
    const texts = try tb_text.Texts.init(arena, s.texts);
    const n = s.partCount();
    const names = try arena.alloc([]const Line, n);
    const box_h = try arena.alloc(i32, n);
    var widest_name: i32 = 0;
    for (s.names, names, box_h) |t, *name, *h| {
        name.* = texts.of(t);
        h.* = @intCast(@max(name.len, 1) + 2);
        widest_name = @max(widest_name, @as(i32, @intCast(texts.widest(t))));
    }

    var msgs: std.ArrayList(Msg) = .empty;
    for (s.steps) |step| {
        const msg = step.message;
        const words = try splitWords(arena, texts.of(msg.label));
        var wide: i32 = 0;
        for (words) |w| wide = @max(wide, @as(i32, @intCast(w.width)));
        const gap: usize = if (msg.to > msg.from) msg.to - 1 else msg.to;
        try msgs.append(arena, .{ .from = msg.from, .to = msg.to, .kind = msg.kind, .words = words, .wide = wide, .gap = gap });
    }

    var plan = Plan{
        .msgs = msgs.items,
        .names = names,
        .box_w = widest_name + 4,
        .box_h = box_h,
        .life = try arena.alloc(i32, n),
        .width = 0,
        .height = 0,
    };
    const down_used = try arena.alloc(i32, n);
    const up_used = try arena.alloc(i32, n);
    var round: usize = 0;
    while (round <= plan.msgs.len) : (round += 1) {
        rows(&plan, down_used, up_used);
        columns(&plan);
        if (!hem(&plan)) break;
    }
    measure(&plan, up_used);
    return plan;
}

/// Every word of every line, in reading order.
fn splitWords(arena: Allocator, lines: []const Line) ![]const Line {
    var out: std.ArrayList(Line) = .empty;
    for (lines) |line| {
        var it = std.mem.tokenizeScalar(u8, line.bytes, ' ');
        while (it.next()) |word| try out.append(arena, .{ .bytes = word, .width = tb_text.width(word) });
    }
    return out.items;
}

/// Label rows per gap: downward labels upward from the lower lifeline, upward and self labels
/// downward from the upper one, in declared order; then every lifeline row.
fn rows(plan: *Plan, down_used: []i32, up_used: []i32) void {
    @memset(down_used, 0);
    @memset(up_used, 0);
    for (plan.msgs) |*m| {
        const k: i32 = @intCast(m.words.len);
        if (k == 0 and !m.isSelf()) continue;
        const used = if (m.down()) &down_used[m.gap] else &up_used[m.gap];
        m.offset = if (m.hemmed and !m.isSelf()) @max(used.*, 1) else used.*;
        used.* = m.offset + @max(k, 1);
    }
    plan.life[0] = plan.above(0);
    for (1..plan.life.len) |p| {
        const room = @max(plan.below(p - 1) + plan.above(p), down_used[p - 1] + up_used[p - 1]);
        plan.life[p] = plan.life[p - 1] + 1 + room;
    }
    for (plan.msgs) |*m| {
        const k: i32 = @intCast(m.words.len);
        if (m.down()) {
            m.r1 = plan.life[m.to] - m.offset - 1;
            m.r0 = m.r1 - k + 1;
        } else {
            m.r0 = plan.life[m.to] + 1 + m.offset;
            m.r1 = m.r0 + k - 1;
        }
    }
}

/// Message lines left to right, as close as the rules allow: no empty column between lines
/// pointing opposite ways, one between lines pointing the same way, wider only where a label
/// needs the columns.
fn columns(plan: *Plan) void {
    var reach: i32 = 0;
    for (plan.msgs) |m| reach = @max(reach, m.wide + 2);
    const start = plan.start();
    for (plan.msgs, 0..) |*m, k| {
        const span_l = m.lo() - m.col;
        var cand: i32 = start - span_l;
        if (k > 0) {
            const prev = plan.msgs[k - 1];
            const prev_down = prev.down();
            const this_down = m.down() or m.isSelf();
            cand = @max(cand, prev.col + 1 + @as(i32, @intFromBool(prev_down == this_down)) - span_l);
        }
        if (m.words.len > 0) {
            if (m.hemmed and !m.isSelf()) cand = @max(cand, start + m.halfL()) else if (m.down()) cand = @max(cand, start + m.wide);
        }
        var j = k;
        while (j > 0) {
            j -= 1;
            const other = plan.msgs[j];
            if (other.col + reach + 2 < cand) break;
            if (m.hemmed and !m.isSelf() and plan.crosses(other, m.*)) cand = @max(cand, other.col + m.halfL() + 1);
            if (other.hemmed and plan.crosses(m.*, other)) {
                const right = if (other.isSelf()) other.wide else other.halfR();
                cand = @max(cand, other.col + right + 1 - span_l);
            }
        }
        m.col = cand;
    }
}

/// Marks every label a neighbouring message line crosses within its width; true when any new.
fn hem(plan: *Plan) bool {
    var any = false;
    for (plan.msgs, 0..) |*m, k| {
        if (m.hemmed or m.words.len == 0) continue;
        if (m.down()) {
            const left = m.col - m.wide;
            var j = k;
            while (j > 0) {
                j -= 1;
                const other = plan.msgs[j];
                if (other.col < left) break;
                if (plan.crosses(other, m.*)) m.hemmed = true;
            }
        } else {
            const right = m.col + m.wide;
            for (plan.msgs[k + 1 ..]) |other| {
                if (other.lo() > right) break;
                if (plan.crosses(other, m.*)) m.hemmed = true;
            }
        }
        any = any or m.hemmed;
    }
    return any;
}

fn measure(plan: *Plan, up_used: []const i32) void {
    var right: i32 = plan.box_w;
    for (plan.msgs) |m| {
        right = @max(right, m.col);
        if (m.words.len == 0) continue;
        if (m.hemmed and !m.isSelf()) right = @max(right, m.col + m.halfR()) else if (!m.down()) right = @max(right, m.col + m.wide);
    }
    plan.width = @intCast(right + 2);
    const last = plan.life.len - 1;
    plan.height = @intCast(plan.life[last] + 1 + @max(plan.below(last), up_used[last]));
}

fn lineGlyph(kind: seq.ArrowKind) u21 {
    return if (kind.isDashed()) glyph.dashed else glyph.solid;
}

/// The receiver-end cell: an arrowhead, a cross, an open end, or the line itself.
pub fn decoration(kind: seq.ArrowKind, downward: bool) u21 {
    return switch (kind) {
        .solid_arrow, .dashed_arrow => if (downward) glyph.head_down else glyph.head_up,
        .solid_cross, .dashed_cross => glyph.cross,
        .solid_open, .dashed_open => if (downward) glyph.open_down else glyph.open_up,
        .solid_line, .dashed_line => lineGlyph(kind),
    };
}

fn paint(allocator: Allocator, arena: Allocator, plan: *const Plan) ![]const u8 {
    var ink = try Ink.init(arena, plan.width, plan.height);
    for (plan.names, 0..) |name, p| {
        const top = plan.life[p] - plan.above(p);
        try ink_mod.rect(&ink, 0, top, plan.box_w - 1, plan.life[p] + plan.below(p), ink_mod.rounded, .box, false);
        const inner = plan.box_w - 4;
        for (name, 0..) |line, i| {
            const col = 2 + @divFloor(inner - @as(i32, @intCast(line.width)), 2);
            try ink.text(col, top + 1 + @as(i32, @intCast(i)), line, .label);
        }
        var c = plan.box_w;
        while (c < plan.width) : (c += 1) try ink.put(c, plan.life[p], glyph.lifeline, .lifeline);
    }
    for (plan.msgs) |m| {
        if (m.isSelf()) {
            const y = plan.life[m.from];
            try ink.put(m.col - 2, y + 1, '└', .stroke);
            try ink.put(m.col - 1, y + 1, if (m.kind.isDashed()) '┄' else '─', .stroke);
            try ink.put(m.col, y + 1, '┘', .stroke);
            try ink.put(m.col, y, decoration(m.kind, false), .stroke);
            continue;
        }
        const r = plan.lineRows(m);
        var y = r[0];
        while (y <= r[1]) : (y += 1) try ink.put(m.col, y, lineGlyph(m.kind), .stroke);
        try ink.put(m.col, plan.life[m.to], decoration(m.kind, m.down()), .stroke);
    }
    for (plan.msgs) |m| {
        for (m.words, 0..) |word, i| {
            const y = m.r0 + @as(i32, @intCast(i));
            const w: i32 = @intCast(word.width);
            const col = if (m.hemmed and !m.isSelf()) blk: {
                if (ink.at(m.col, y)) |cell| if (cell.owner == .stroke) {
                    cell.* = .{};
                };
                break :blk m.col - @divFloor(w - 1, 2);
            } else if (m.down()) m.col - w else m.col + 1;
            try ink.text(col, y, word, .label);
        }
    }
    return ink.toText(allocator);
}

test {
    _ = @import("lr_test.zig");
}
