//! The row schedule of one break state: participant boxes, steps (label rows, then the message
//! line), activation tails, fragment sides and dividers, and every participant's ink reach at
//! every row. Rows are fixed before any column exists.

const std = @import("std");
const Allocator = std.mem.Allocator;
const seq = @import("seq.zig");
const Texts = @import("tb_text.zig").Texts;

pub const Kind = enum { box, bare, frame_top, divider, guard_more, frame_bottom, label, stroke, self_return, tail, note };

/// A message step's label rows start at `first`; its message line is `stroke`. A note's box
/// takes `first..stroke`.
pub const StepRows = struct { first: u32, labels: u32, stroke: u32 };

/// `reach` is how far the bar's right side stands from its lifeline; its left side stands one left.
pub const BarRows = struct { first: u32, last: u32, part: usize, reach: u8 };

pub const FrameRows = struct {
    top: u32,
    bottom: u32,
    /// The row of each operand's side: the top side, then each divider.
    sides: []u32,
};

pub const Rows = struct {
    kinds: []Kind,
    box_rows: u32,
    steps: []StepRows,
    bars: []BarRows,
    frames: []FrameRows,
    parts: usize,
    reach_l: []u8,
    reach_r: []u8,

    pub fn count(self: *const Rows) u32 {
        return @intCast(self.kinds.len);
    }

    /// The farthest a participant's ink reaches left of its lifeline over rows `r0..r1`.
    pub fn left(self: *const Rows, p: usize, r0: u32, r1: u32) u32 {
        return self.maxOver(.left, p, r0, r1);
    }

    pub fn right(self: *const Rows, p: usize, r0: u32, r1: u32) u32 {
        return self.maxOver(.right, p, r0, r1);
    }

    fn maxOver(self: *const Rows, side: enum { left, right }, p: usize, r0: u32, r1: u32) u32 {
        var m: u32 = 0;
        if (r1 >= r0 and r1 - r0 >= self.bars.len) {
            for (self.bars) |bar| {
                if (bar.part != p or bar.last < r0 or bar.first > r1) continue;
                m = @max(m, if (side == .left) 1 else bar.reach);
            }
            return m;
        }
        const reach = if (side == .left) self.reach_l else self.reach_r;
        var r = r0;
        while (r <= r1 and r < self.kinds.len) : (r += 1) m = @max(m, reach[r * self.parts + p]);
        return m;
    }
};

pub fn build(arena: Allocator, s: *const seq.Sequence, texts: *const Texts) !Rows {
    var kinds: std.ArrayList(Kind) = .empty;
    var box_rows: u32 = 3;
    for (s.names) |name| box_rows = @max(box_rows, texts.count(name) + 2);
    try kinds.appendNTimes(arena, .box, box_rows);
    try kinds.append(arena, .bare);

    const steps = try arena.alloc(StepRows, s.steps.len);
    const frames = try arena.alloc(FrameRows, s.frags.len);
    for (s.frags, frames) |f, *fr| fr.* = .{ .top = 0, .bottom = 0, .sides = try arena.alloc(u32, f.operands.len) };

    const tail_at = try arena.alloc(u32, s.items.len);
    for (s.items, 0..) |item, item_ix| switch (item) {
        .release => {
            const shared = item_ix > 0 and s.items[item_ix - 1] == .release;
            if (!shared) try kinds.append(arena, .tail);
            tail_at[item_ix] = @intCast(kinds.items.len - 1);
        },
        .step => |ix| {
            const first: u32 = @intCast(kinds.items.len);
            switch (s.steps[ix]) {
                .message => |msg| {
                    var labels = texts.count(msg.label);
                    if (labels == 0 and opensBar(s, ix)) labels = 1;
                    try kinds.appendNTimes(arena, .label, labels);
                    steps[ix] = .{ .first = first, .labels = labels, .stroke = first + labels };
                    try kinds.append(arena, .stroke);
                    if (msg.from == msg.to) try kinds.append(arena, .self_return);
                },
                .note => |note| {
                    const height = @max(texts.count(note.text), 1) + 2;
                    try kinds.appendNTimes(arena, .note, height);
                    steps[ix] = .{ .first = first, .labels = 0, .stroke = first + height - 1 };
                },
            }
        },
        .open => |f| {
            switch (kinds.items[kinds.items.len - 1]) {
                .bare, .frame_top, .divider, .guard_more => {},
                else => try kinds.append(arena, .bare),
            }
            frames[f].top = @intCast(kinds.items.len);
            frames[f].sides[0] = frames[f].top;
            try kinds.append(arena, .frame_top);
            try guardRows(arena, &kinds, texts, s.frags[f].operands[0].guard);
        },
        .divider => |d| {
            frames[d.frag].sides[d.operand] = @intCast(kinds.items.len);
            try kinds.append(arena, .divider);
            try guardRows(arena, &kinds, texts, s.frags[d.frag].operands[d.operand].guard);
        },
        .close => |f| {
            frames[f].bottom = @intCast(kinds.items.len);
            try kinds.append(arena, .frame_bottom);
        },
    };
    try kinds.append(arena, .bare);

    const bars = try arena.alloc(BarRows, s.bars.len);
    const n = s.partCount();
    const reach_l = try arena.alloc(u8, kinds.items.len * n);
    const reach_r = try arena.alloc(u8, kinds.items.len * n);
    @memset(reach_l, 0);
    @memset(reach_r, 0);
    for (s.bars, bars) |bar, *br| {
        const r_reach: u8 = @intCast(@min(1 + 3 * (@as(u32, bar.depth) - 1), 255));
        const first = if (bar.joined) joinedRow(s, bar, tail_at) else steps[bar.first].first;
        br.* = .{ .first = first, .last = tail_at[bar.release], .part = bar.part, .reach = r_reach };
        var r = br.first;
        while (r <= br.last) : (r += 1) {
            reach_l[r * n + bar.part] = 1;
            reach_r[r * n + bar.part] = @max(reach_r[r * n + bar.part], r_reach);
        }
    }

    return .{
        .kinds = kinds.items,
        .box_rows = box_rows,
        .steps = steps,
        .bars = bars,
        .frames = frames,
        .parts = n,
        .reach_l = reach_l,
        .reach_r = reach_r,
    };
}

fn guardRows(arena: Allocator, kinds: *std.ArrayList(Kind), texts: *const Texts, guard: ?seq.TextIx) !void {
    const g = guard orelse return;
    const lines = texts.count(g);
    if (lines > 1) try kinds.appendNTimes(arena, .guard_more, lines - 1);
}

/// The last row of the bar a joined bar reopens.
fn joinedRow(s: *const seq.Sequence, bar: seq.Bar, tail_at: []const u32) u32 {
    var row: u32 = 0;
    for (s.bars) |b| {
        if (b.part == bar.part and b.depth == bar.depth and b.last == bar.first and b.release < bar.release) row = @max(row, tail_at[b.release]);
    }
    return row;
}

fn opensBar(s: *const seq.Sequence, ix: seq.StepIx) bool {
    for (s.bars) |bar| if (bar.first == ix and !bar.joined) return true;
    return false;
}


test {
    _ = @import("tb_rows_test.zig");
}
