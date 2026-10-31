//! Parsed elements → the index form: steps, bars bound to steps, the fragment tree and spans.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const seq = @import("seq.zig");

const PartIx = seq.PartIx;
const StepIx = seq.StepIx;
const TextIx = seq.TextIx;
const FragIx = seq.FragIx;

const Open = struct { part: PartIx, first: ?StepIx, depth: u8, joined: bool = false, engage: u32 };

const FragBuild = struct {
    kind: seq.FragmentKind,
    operands: std.ArrayList(seq.Operand) = .empty,
    parent: ?FragIx,
    depth: u8,
    lo: PartIx = std.math.maxInt(PartIx),
    hi: PartIx = 0,
};

pub fn normalize(arena: Allocator, diagram: *const model.SequenceDiagram) !seq.Sequence {
    var texts: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList(TextIx) = .empty;
    for (diagram.participants.items) |*p| {
        try names.append(arena, @intCast(texts.items.len));
        try texts.append(arena, p.displayName());
    }

    var steps: std.ArrayList(seq.Step) = .empty;
    var items: std.ArrayList(seq.Item) = .empty;
    var bars: std.ArrayList(seq.Bar) = .empty;
    var frags: std.ArrayList(FragBuild) = .empty;
    var frag_stack: std.ArrayList(FragIx) = .empty;
    var open_bars: std.ArrayList(Open) = .empty;
    var pending: std.ArrayList(PartIx) = .empty;
    var last_message: ?StepIx = null;

    for (diagram.elements.items) |element| switch (element) {
        .message => |msg| {
            const from = partIndex(diagram, msg.from) orelse continue;
            const to = partIndex(diagram, msg.to) orelse continue;
            const label: TextIx = @intCast(texts.items.len);
            try texts.append(arena, msg.text);
            const ix: StepIx = @intCast(steps.items.len);
            try steps.append(arena, .{ .message = .{ .from = from, .to = to, .kind = msg.arrow_type, .label = label } });
            try items.append(arena, .{ .step = ix });
            touch(frags.items, frag_stack.items, from);
            touch(frags.items, frag_stack.items, to);
            last_message = ix;
            for (open_bars.items) |*o| {
                if (o.first == null) o.first = ix;
            }
            for (pending.items) |part| try closeBar(arena, &bars, &open_bars, &items, part, ix);
            pending.clearRetainingCapacity();
        },
        .note => |note| {
            const a = partIndex(diagram, note.participant1) orelse continue;
            const b = if (note.participant2) |id| partIndex(diagram, id) orelse a else a;
            const text: TextIx = @intCast(texts.items.len);
            try texts.append(arena, note.text);
            const ix: StepIx = @intCast(steps.items.len);
            const position: seq.NotePosition = if (a != b) .over else note.position;
            try steps.append(arena, .{ .note = .{ .position = position, .first = @min(a, b), .last = @max(a, b), .text = text } });
            try items.append(arena, .{ .step = ix });
            touch(frags.items, frag_stack.items, a);
            touch(frags.items, frag_stack.items, b);
        },
        .activation => |act| {
            const part = partIndex(diagram, act.participant) orelse continue;
            if (act.is_activate) {
                var depth: u8 = 1;
                for (open_bars.items) |o| {
                    if (o.part == part) depth +|= 1;
                }
                const joined = reopens(bars.items, items.items, part, depth);
                try items.append(arena, .engage);
                try open_bars.append(arena, .{ .part = part, .first = last_message, .depth = depth, .joined = joined, .engage = @intCast(items.items.len - 1) });
            } else if (last_message) |ix| {
                try closeBar(arena, &bars, &open_bars, &items, part, ix);
            } else {
                try pending.append(arena, part);
            }
        },
        .fragment_open => |open| {
            const ix: FragIx = @intCast(frags.items.len);
            const parent: ?FragIx = if (frag_stack.items.len > 0) frag_stack.items[frag_stack.items.len - 1] else null;
            var build: FragBuild = .{ .kind = open.kind, .parent = parent, .depth = @intCast(@min(frag_stack.items.len, 255)) };
            try build.operands.append(arena, .{ .guard = try guardText(arena, &texts, open.guard) });
            try frags.append(arena, build);
            try frag_stack.append(arena, ix);
            try items.append(arena, .{ .open = ix });
        },
        .fragment_divider => |divider| {
            if (frag_stack.items.len == 0) continue;
            const ix = frag_stack.items[frag_stack.items.len - 1];
            const frag = &frags.items[ix];
            try frag.operands.append(arena, .{ .guard = try guardText(arena, &texts, divider.guard) });
            try items.append(arena, .{ .divider = .{ .frag = ix, .operand = @intCast(frag.operands.items.len - 1) } });
        },
        .fragment_close => {
            const ix = frag_stack.pop() orelse continue;
            try items.append(arena, .{ .close = ix });
        },
    };
    while (frag_stack.pop()) |ix| try items.append(arena, .{ .close = ix });

    if (steps.items.len > 0) {
        const last: StepIx = @intCast(steps.items.len - 1);
        while (open_bars.items.len > 0) {
            const o = open_bars.items[open_bars.items.len - 1];
            try closeBar(arena, &bars, &open_bars, &items, o.part, last);
        }
    }

    const out_frags = try arena.alloc(seq.Fragment, frags.items.len);
    for (frags.items, out_frags) |f, *out| {
        out.* = .{ .kind = f.kind, .operands = f.operands.items, .parent = f.parent, .depth = f.depth, .lo = f.lo, .hi = f.hi };
        if (f.lo > f.hi) {
            const outer: seq.Fragment = if (f.parent) |p| out_frags[p] else .{ .kind = f.kind, .operands = &.{}, .parent = null, .depth = 0, .lo = 0, .hi = 0 };
            out.lo = outer.lo;
            out.hi = outer.hi;
        }
    }
    std.mem.sort(seq.Bar, bars.items, {}, barBefore);

    return .{
        .texts = texts.items,
        .names = names.items,
        .steps = steps.items,
        .items = items.items,
        .bars = bars.items,
        .frags = out_frags,
    };
}

fn barBefore(_: void, a: seq.Bar, b: seq.Bar) bool {
    if (a.first != b.first) return a.first < b.first;
    if (a.part != b.part) return a.part < b.part;
    return a.depth < b.depth;
}

/// Closes the innermost open bar of `part` after step `last`; a bar not yet bound to a step
/// starts there too. Nothing open: the deactivate is ignored.
fn closeBar(arena: Allocator, bars: *std.ArrayList(seq.Bar), open_bars: *std.ArrayList(Open), items: *std.ArrayList(seq.Item), part: PartIx, last: StepIx) !void {
    var i = open_bars.items.len;
    while (i > 0) {
        i -= 1;
        const o = open_bars.items[i];
        if (o.part != part) continue;
        _ = open_bars.orderedRemove(i);
        const first = o.first orelse last;
        try items.append(arena, .release);
        try bars.append(arena, .{ .part = part, .first = first, .last = @max(first, last), .depth = o.depth, .joined = o.joined, .engage = o.engage, .release = @intCast(items.items.len - 1) });
        return;
    }
}

/// Whether the item before an activate, past other activates, is the deactivate of a bar of the same participant and depth.
fn reopens(bars: []const seq.Bar, items: []const seq.Item, part: PartIx, depth: u8) bool {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        switch (items[i]) {
            .engage => continue,
            .release => {
                for (bars) |b| if (b.release == i and b.part == part and b.depth == depth) return true;
                return false;
            },
            else => return false,
        }
    }
    return false;
}

fn touch(frags: []FragBuild, stack: []const FragIx, part: PartIx) void {
    for (stack) |ix| {
        frags[ix].lo = @min(frags[ix].lo, part);
        frags[ix].hi = @max(frags[ix].hi, part);
    }
}

fn guardText(arena: Allocator, texts: *std.ArrayList([]const u8), guard: []const u8) !?TextIx {
    if (guard.len == 0) return null;
    const ix: TextIx = @intCast(texts.items.len);
    try texts.append(arena, try std.mem.concat(arena, u8, &.{ "[", guard, "]" }));
    return ix;
}

fn partIndex(diagram: *const model.SequenceDiagram, id: []const u8) ?PartIx {
    const ix = diagram.getParticipantIndex(id) orelse return null;
    return @intCast(ix);
}

test {
    _ = @import("normalize_test.zig");
}
