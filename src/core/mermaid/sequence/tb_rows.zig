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
    const top_at = try arena.alloc(u32, s.items.len);
    var here: Here = .{ .at = box_rows };
    for (s.items, 0..) |item, item_ix| switch (item) {
        .engage => top_at[item_ix] = switch (here) {
            .line => |l| if (noteNext(s, item_ix) or passes(s, l.step, item_ix)) try ownRow(arena, &kinds, &here) else l.row,
            .under => try ownRow(arena, &kinds, &here),
            .at => |r| r,
            .next => @intCast(kinds.items.len),
        },
        .release => {
            const shared = (item_ix > 0 and s.items[item_ix - 1] == .release) or spare(here, kinds.items);
            if (!shared) try kinds.append(arena, .tail);
            var floor: u32 = 0;
            for (s.bars) |bar| if (bar.release == item_ix) {
                floor = @max(floor, top_at[bar.engage] + 1);
            };
            while (kinds.items.len - 1 < floor) try kinds.append(arena, .tail);
            tail_at[item_ix] = @intCast(kinds.items.len - 1);
            here = .{ .at = tail_at[item_ix] };
        },
        .step => |ix| {
            const first: u32 = @intCast(kinds.items.len);
            switch (s.steps[ix]) {
                .message => |msg| {
                    const labels = texts.count(msg.label);
                    try kinds.appendNTimes(arena, .label, labels);
                    steps[ix] = .{ .first = first, .labels = labels, .stroke = first + labels };
                    try kinds.append(arena, .stroke);
                    here = .{ .line = .{ .row = first + labels, .step = ix } };
                    if (msg.from == msg.to) {
                        try kinds.append(arena, .self_return);
                        here = .under;
                    }
                },
                .note => |note| {
                    const height = @max(texts.count(note.text), 1) + 2;
                    try kinds.appendNTimes(arena, .note, height);
                    steps[ix] = .{ .first = first, .labels = 0, .stroke = first + height - 1 };
                    here = .next;
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
            here = .next;
        },
        .divider => |d| {
            frames[d.frag].sides[d.operand] = @intCast(kinds.items.len);
            try kinds.append(arena, .divider);
            try guardRows(arena, &kinds, texts, s.frags[d.frag].operands[d.operand].guard);
            here = .next;
        },
        .close => |f| {
            frames[f].bottom = @intCast(kinds.items.len);
            try kinds.append(arena, .frame_bottom);
            here = .next;
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
        const r_reach: u8 = @intCast(@min(@as(u32, bar.depth), 255));
        br.* = .{ .first = top_at[bar.engage], .last = tail_at[bar.release], .part = bar.part, .reach = r_reach };
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

/// Where an activate puts its bar's top: on a message's line row, on a row of its own, on a given
/// row, or on the next row placed.
const Here = union(enum) { line: struct { row: u32, step: seq.StepIx }, under, at: u32, next };

/// Whether the last row is a bare row of its own that a bar top took and no step has used yet.
fn spare(here: Here, kinds: []const Kind) bool {
    return here == .at and here.at == kinds.len - 1 and kinds[here.at] == .bare;
}

/// Whether the message line of `step` passes the lifeline of the participant an activate opens, without ending there.
fn passes(s: *const seq.Sequence, step: seq.StepIx, engage: usize) bool {
    const msg = s.steps[step].message;
    for (s.bars) |bar| if (bar.engage == engage) return @min(msg.from, msg.to) < bar.part and bar.part < @max(msg.from, msg.to);
    return false;
}

fn ownRow(arena: Allocator, kinds: *std.ArrayList(Kind), here: *Here) !u32 {
    try kinds.append(arena, .bare);
    here.* = .{ .at = @intCast(kinds.items.len - 1) };
    return here.at;
}

/// Whether the first step after an activate, past other activates and deactivates, is a note.
fn noteNext(s: *const seq.Sequence, item_ix: usize) bool {
    for (s.items[item_ix + 1 ..]) |item| switch (item) {
        .engage, .release => continue,
        .step => |ix| return s.steps[ix] == .note,
        else => return false,
    };
    return false;
}


test {
    _ = @import("tb_rows_test.zig");
}
