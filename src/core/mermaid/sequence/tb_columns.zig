//! Columns of one break state: every gap as wide as its widest demand and no wider, lifelines at
//! the prefix sums, and the columns of labels, guards, notes and boundaries.
//!
//! Gap `g` sits left of lifeline `g`; gap 0 is the left pad and gap `n` the right pad.

const std = @import("std");
const Allocator = std.mem.Allocator;
const seq = @import("seq.zig");
const Texts = @import("tb_text.zig").Texts;
const tb_rows = @import("tb_rows.zig");
const Rows = tb_rows.Rows;
const frames = @import("tb_frames.zig");

pub const box_gap: i32 = 2;
const max_rounds = 256;

/// `text_at` is the first column of every text line when activations pierce the box; null centers each line.
pub const NoteBox = struct { left: i32, right: i32, text_at: ?i32 = null };

pub const Layout = struct {
    margin: u32,
    x: []i32,
    /// Per participant: box columns either side of its lifeline.
    half_l: []i32,
    half_r: []i32,
    /// Per message step: the gap its label sits in (self: the gap right of its participant).
    label_gap: []usize,
    /// Per step: a label's first column, or a note box's left column.
    label_col: []i32,
    notes: []NoteBox,
    /// Per self step: the column of the loop's corner.
    loop_col: []i32,
    guard_col: [][]i32,
    frames: []frames.FrameCols,
    width: u32,
    /// Per gap (0..n): its drawn width and the texts that set its demands.
    gap_width: []i32,
    owners: []std.ArrayList(seq.TextIx),
};

const Builder = struct {
    arena: Allocator,
    s: *const seq.Sequence,
    texts: *const Texts,
    rows: *const Rows,
    m: i32,
    n: usize,
    dem: []i32,
    owners: []std.ArrayList(seq.TextIx),

    fn own(self: *Builder, gap: usize, t: seq.TextIx) !void {
        if (self.texts.count(t) == 0) return;
        try self.owners[gap].append(self.arena, t);
    }

    fn need(self: *Builder, gap: usize, v: i32) void {
        self.dem[gap] = @max(self.dem[gap], v);
    }

    fn rr(self: *const Builder, p: usize, r0: u32, r1: u32) i32 {
        return @intCast(self.rows.right(p, r0, r1));
    }

    fn rl(self: *const Builder, p: usize, r0: u32, r1: u32) i32 {
        return @intCast(self.rows.left(p, r0, r1));
    }

    /// Gap `g` (between two lifelines) keeps `empty` empty cells between its inks over rows r0..r1.
    fn room(self: *Builder, g: usize, r0: u32, r1: u32, empty: i32) void {
        self.need(g, self.rr(g - 1, r0, r1) + 1 + empty + self.rl(g, r0, r1));
    }

    fn widest(self: *const Builder, t: seq.TextIx) i32 {
        return @intCast(self.texts.widest(t));
    }
};

pub fn place(arena: Allocator, s: *const seq.Sequence, texts: *const Texts, rows: *const Rows, margin: u32) !Layout {
    const n = s.partCount();
    var b = Builder{
        .arena = arena,
        .s = s,
        .texts = texts,
        .rows = rows,
        .m = @intCast(margin),
        .n = n,
        .dem = try arena.alloc(i32, n + 1),
        .owners = try arena.alloc(std.ArrayList(seq.TextIx), n + 1),
    };
    @memset(b.dem, 0);
    for (b.owners) |*o| o.* = .empty;

    const half_l = try arena.alloc(i32, n);
    const half_r = try arena.alloc(i32, n);
    for (s.names, 0..) |name, p| {
        const bw = b.widest(name) + 4;
        half_l[p] = @divFloor(bw, 2);
        half_r[p] = bw - half_l[p] - 1;
    }
    b.need(0, half_l[0]);
    try b.own(0, s.names[0]);
    try b.own(n, s.names[n - 1]);
    for (1..n) |g| {
        b.need(g, half_r[g - 1] + 1 + box_gap + half_l[g]);
        try b.own(g, s.names[g - 1]);
        try b.own(g, s.names[g]);
    }

    const label_gap = try arena.alloc(usize, s.steps.len);
    @memset(label_gap, 0);
    for (s.steps, 0..) |step, ix| try fixedStep(&b, step, rows.steps[ix], &label_gap[ix]);
    for (s.frags, 0..) |f, fi| {
        for (f.operands, 0..) |op, oi| {
            const g = op.guard orelse continue;
            const top = rows.frames[fi].sides[oi];
            const slot = f.lo + 1;
            try b.own(slot, g);
            if (slot < n) b.room(slot, top, top + texts.count(g) - 1, b.widest(g) + 2 * b.m);
        }
    }

    const fixed = try arena.dupe(i32, b.dem);
    var floating: std.ArrayList(Floating) = .empty;
    for (s.steps, 0..) |step, ix| {
        const msg = switch (step) {
            .message => |msg| msg,
            .note => continue,
        };
        if (@max(msg.from, msg.to) - @min(msg.from, msg.to) < 2 or texts.count(msg.label) == 0) continue;
        const sr = rows.steps[ix];
        try floating.append(arena, .{ .step = ix, .msg = msg, .r0 = sr.first, .r1 = sr.first + sr.labels - 1, .need = b.widest(msg.label) + 2 * b.m });
    }
    for (floating.items) |f| label_gap[f.step] = preferred(&b, f);

    var layout = Layout{
        .margin = margin,
        .x = try arena.alloc(i32, n),
        .half_l = half_l,
        .half_r = half_r,
        .label_gap = label_gap,
        .label_col = try arena.alloc(i32, s.steps.len),
        .notes = try arena.alloc(NoteBox, s.steps.len),
        .loop_col = try arena.alloc(i32, s.steps.len),
        .guard_col = try arena.alloc([]i32, s.frags.len),
        .frames = try arena.alloc(frames.FrameCols, s.frags.len),
        .width = 0,
        .gap_width = try arena.alloc(i32, n + 1),
        .owners = b.owners,
    };
    for (s.frags, layout.guard_col) |f, *gc| gc.* = try arena.alloc(i32, f.operands.len);
    const step_lo = try arena.alloc(i32, s.steps.len);
    const step_hi = try arena.alloc(i32, s.steps.len);
    const guard_end = try arena.alloc([]i32, s.frags.len);
    for (s.frags, guard_end) |f, *ge| ge.* = try arena.alloc(i32, f.operands.len);
    const step_frames = try frames.stepFrames(arena, s);

    var widen: std.ArrayList(frames.Widen) = .empty;
    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        settle(&b, fixed, floating.items, label_gap);
        const grew = spanNotes(&b, &layout, fixed);
        placeColumns(&b, &layout, step_lo, step_hi, guard_end);
        widen.clearRetainingCapacity();
        try frames.place(s, rows, layout.x, .{ .step_lo = step_lo, .step_hi = step_hi, .guard_end = guard_end }, step_frames, layout.frames, &widen, arena);
        if (widen.items.len == 0 and !grew) break;
        for (widen.items) |w| fixed[w.gap] = @max(fixed[w.gap], gapOf(&layout, w.gap) + w.by);
    } else return error.ColumnsDoNotSettle;
    for (floating.items) |f| try b.own(label_gap[f.step], f.msg.label);

    var right: i32 = 0;
    for (layout.x, half_r) |x, h| right = @max(right, x + h);
    for (step_hi) |hi| right = @max(right, hi);
    for (layout.frames) |fc| right = @max(right, fc.right);
    for (guard_end) |ends| for (ends) |e| {
        right = @max(right, e);
    };
    layout.width = @intCast(right + 1);
    layout.gap_width[0] = layout.x[0];
    for (1..n) |g| layout.gap_width[g] = layout.x[g] - layout.x[g - 1];
    layout.gap_width[n] = right - layout.x[n - 1];
    return layout;
}

/// A label whose message line crosses several gaps: it needs `need` empty cells over rows r0..r1
/// of the gap it takes.
const Floating = struct { step: usize, msg: seq.Message, r0: u32, r1: u32, need: i32 };

fn settle(b: *Builder, fixed: []const i32, floating: []const Floating, label_gap: []usize) void {
    var pass: usize = 0;
    while (true) : (pass += 1) {
        @memcpy(b.dem, fixed);
        for (floating) |f| b.room(label_gap[f.step], f.r0, f.r1, f.need);
        if (pass == max_rounds) return;
        var moved = false;
        for (floating) |f| {
            const g = preferred(b, f);
            moved = moved or g != label_gap[f.step];
            label_gap[f.step] = g;
        }
        if (!moved) return;
    }
}

fn preferred(b: *const Builder, f: Floating) usize {
    const lo = @min(f.msg.from, f.msg.to);
    const hi = @max(f.msg.from, f.msg.to);
    var best: usize = 0;
    var best_room: i32 = std.math.minInt(i32);
    var k: usize = 0;
    while (k < hi - lo) : (k += 1) {
        const g = if (f.msg.from < f.msg.to) lo + 1 + k else hi - k;
        const r = b.dem[g] - 1 - b.rr(g - 1, f.r0, f.r1) - b.rl(g, f.r0, f.r1);
        if (r > best_room) {
            best = g;
            best_room = r;
        }
    }
    return best;
}

fn fixedStep(b: *Builder, step: seq.Step, sr: tb_rows.StepRows, label_gap: *usize) !void {
    const n = b.n;
    switch (step) {
        .message => |msg| {
            const w = b.widest(msg.label);
            if (msg.from == msg.to) {
                const p = msg.from;
                label_gap.* = p + 1;
                try b.own(p + 1, msg.label);
                if (p + 1 < n) b.room(p + 1, sr.first, sr.stroke + 1, @max(3, b.m + w) + b.m);
                return;
            }
            const lo = @min(msg.from, msg.to);
            const hi = @max(msg.from, msg.to);
            label_gap.* = hi;
            if (hi - lo == 1 and b.texts.count(msg.label) > 0) {
                try b.own(hi, msg.label);
                b.room(hi, sr.first, sr.first + sr.labels - 1, w + 2 * b.m);
            }
        },
        .note => |note| {
            const bw = b.widest(note.text) + 4;
            const r0 = sr.first;
            const r1 = sr.stroke;
            const a = note.first;
            switch (notePosition(b, note, r0, r1)) {
                .right_of => {
                    try b.own(a + 1, note.text);
                    if (a + 1 < n) b.room(a + 1, r0, r1, bw + 2);
                },
                .left_of => {
                    try b.own(a, note.text);
                    if (a == 0) b.need(0, b.rl(0, r0, r1) + 1 + bw) else b.room(a, r0, r1, bw + 2);
                },
                .over => {
                    const z = note.last;
                    const hl: i32 = if (a == z) @divFloor(bw, 2) else 2 + b.rl(a, r0, r1);
                    const hr: i32 = if (a == z) bw - hl - 1 else 2 + b.rr(z, r0, r1);
                    try b.own(a, note.text);
                    try b.own(z + 1, note.text);
                    var g = a + 1;
                    while (g <= z) : (g += 1) try b.own(g, note.text);
                    if (a == 0) b.need(0, hl) else b.need(a, b.rr(a - 1, r0, r1) + hl + 2);
                    if (z + 1 < n) b.need(z + 1, hr + 2 + b.rl(z + 1, r0, r1));
                },
            }
        },
    }
}

/// A note over several participants widens the gaps between its first participant and the
/// first activation inside it (its last participant when none) evenly until its text fits there.
/// Returns whether any gap grew; the grown widths join `fixed`.
fn spanNotes(b: *Builder, layout: *Layout, fixed: []i32) bool {
    lifelines(b, layout);
    var grew = false;
    for (b.s.steps, b.rows.steps) |step, sr| {
        const note = switch (step) {
            .note => |note| note,
            .message => continue,
        };
        if (note.first == note.last) continue;
        const span = noteSpan(b, layout.x, note, sr.first, sr.stroke);
        const short = b.widest(note.text) - (span.end - span.start + 1);
        if (short <= 0) continue;
        grew = true;
        const k: i32 = @intCast(span.stop - note.first);
        var g = note.first + 1;
        var i: i32 = 0;
        while (g <= span.stop) : ({
            g += 1;
            i += 1;
        }) {
            const add = @divFloor(short, k) + @intFromBool(i < @mod(short, k));
            b.dem[g] = gapOf(layout, g) + add;
            fixed[g] = @max(fixed[g], b.dem[g]);
        }
        lifelines(b, layout);
    }
    return grew;
}

/// Where a note over several participants writes its text: from `start` to `end`, clear of
/// every activation; `stop` is the participant whose ink bounds it on the right.
const NoteSpan = struct { start: i32, end: i32, stop: usize, pierced: bool };

fn noteSpan(b: *const Builder, x: []const i32, note: seq.Note, r0: u32, r1: u32) NoteSpan {
    const a = note.first;
    const ra = b.rr(a, r0, r1);
    const start = if (ra > 0) x[a] + ra + 2 else x[a];
    var p = a + 1;
    while (p <= note.last) : (p += 1) {
        if (b.rl(p, r0, r1) > 0) return .{ .start = start, .end = x[p] - b.rl(p, r0, r1) - 2, .stop = p, .pierced = true };
    }
    return .{ .start = start, .end = x[note.last], .stop = note.last, .pierced = ra > 0 };
}

/// A note over one participant whose activation stands at its rows moves right of the activation.
fn notePosition(b: *const Builder, note: seq.Note, r0: u32, r1: u32) seq.NotePosition {
    if (note.position == .over and note.first == note.last and b.rl(note.first, r0, r1) > 0) return .right_of;
    return note.position;
}

fn lifelines(b: *const Builder, layout: *Layout) void {
    layout.x[0] = b.dem[0];
    for (1..b.n) |g| layout.x[g] = layout.x[g - 1] + b.dem[g];
}

/// Label, loop, note and guard columns from the lifelines, and the ink span of every step.
fn placeColumns(b: *Builder, layout: *Layout, step_lo: []i32, step_hi: []i32, guard_end: [][]i32) void {
    const s = b.s;
    const x = layout.x;
    for (s.steps, 0..) |step, ix| {
        const sr = b.rows.steps[ix];
        switch (step) {
            .message => |msg| {
                const w = b.widest(msg.label);
                if (msg.from == msg.to) {
                    const r = b.rr(msg.from, sr.first, sr.stroke + 1);
                    layout.loop_col[ix] = x[msg.from] + r + 3;
                    layout.label_col[ix] = x[msg.from] + r + 1 + b.m;
                    step_lo[ix] = x[msg.from];
                    step_hi[ix] = @max(layout.loop_col[ix], if (w > 0) layout.label_col[ix] + w - 1 else 0);
                    continue;
                }
                const g = layout.label_gap[ix];
                const r1 = sr.first + @max(sr.labels, 1) - 1;
                layout.label_col[ix] = x[g - 1] + b.rr(g - 1, sr.first, r1) + 1 + b.m;
                step_lo[ix] = x[@min(msg.from, msg.to)];
                step_hi[ix] = x[@max(msg.from, msg.to)];
            },
            .note => |note| {
                const bw = b.widest(note.text) + 4;
                const a = note.first;
                const box: NoteBox = switch (notePosition(b, note, sr.first, sr.stroke)) {
                    .right_of => blk: {
                        const left = x[a] + b.rr(a, sr.first, sr.stroke) + 2;
                        break :blk .{ .left = left, .right = left + bw - 1 };
                    },
                    .left_of => blk: {
                        const right = x[a] - b.rl(a, sr.first, sr.stroke) - 2;
                        break :blk .{ .left = right - bw + 1, .right = right };
                    },
                    .over => blk: {
                        if (a == note.last) {
                            const left = x[a] - @divFloor(bw, 2);
                            break :blk .{ .left = left, .right = left + bw - 1 };
                        }
                        const span = noteSpan(b, x, note, sr.first, sr.stroke);
                        const left = x[a] - b.rl(a, sr.first, sr.stroke) - 2;
                        const right = x[note.last] + b.rr(note.last, sr.first, sr.stroke) + 2;
                        break :blk .{ .left = left, .right = right, .text_at = if (span.pierced) span.start else null };
                    },
                };
                layout.notes[ix] = box;
                layout.label_col[ix] = box.left;
                step_lo[ix] = box.left;
                step_hi[ix] = box.right;
            },
        }
    }
    for (s.frags, 0..) |f, fi| {
        for (f.operands, 0..) |op, oi| {
            guard_end[fi][oi] = std.math.minInt(i32);
            const g = op.guard orelse continue;
            const top = b.rows.frames[fi].sides[oi];
            const col = x[f.lo] + b.rr(f.lo, top, top + b.texts.count(g) - 1) + 1 + b.m;
            layout.guard_col[fi][oi] = col;
            guard_end[fi][oi] = col + b.widest(g) - 1;
        }
    }
}

fn gapOf(layout: *const Layout, g: usize) i32 {
    return if (g == 0) layout.x[0] else layout.x[g] - layout.x[g - 1];
}

test {
    _ = @import("tb_columns_test.zig");
}
