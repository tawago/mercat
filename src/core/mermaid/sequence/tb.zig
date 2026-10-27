//! The top-down sequence diagram: the degradation loop over break states, each laid out rows
//! first, then columns, then measured; only the first state that fits is painted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const seq = @import("seq.zig");
const ladder = @import("../shared/ladder.zig");
const Texts = @import("tb_text.zig").Texts;
const tb_rows = @import("tb_rows.zig");
const tb_columns = @import("tb_columns.zig");
const tb_paint = @import("tb_paint.zig");

pub const comfort_margin: u32 = 3;

pub fn render(allocator: Allocator, s: *const seq.Sequence, max_width: u32) !ladder.Fit {
    var text_arena = std.heap.ArenaAllocator.init(allocator);
    defer text_arena.deinit();
    var state_arena = std.heap.ArenaAllocator.init(allocator);
    defer state_arena.deinit();

    var texts = try Texts.init(text_arena.allocator(), s.texts);
    var narrowest: u32 = std.math.maxInt(u32);
    var margin = comfort_margin;
    while (true) {
        _ = state_arena.reset(.retain_capacity);
        const arena = state_arena.allocator();
        const rows = try tb_rows.build(arena, s, &texts);
        const layout = try tb_columns.place(arena, s, &texts, &rows, margin);
        if (layout.width <= max_width) return .{ .drawn = try tb_paint.paint(allocator, arena, s, &texts, &rows, &layout) };
        narrowest = @min(narrowest, layout.width);
        if (margin > 1) {
            margin -= 1;
            continue;
        }
        if (!try breakWidest(arena, &texts, &layout)) break;
    }
    return .{ .too_wide = narrowest };
}

/// Breaks the widest breakable text of the widest gap (pads included, the leftmost of equals);
/// a gap whose texts cannot break gives way to the next widest.
fn breakWidest(arena: Allocator, texts: *Texts, layout: *const tb_columns.Layout) !bool {
    const order = try arena.alloc(usize, layout.gap_width.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, layout, struct {
        fn wider(l: *const tb_columns.Layout, a: usize, b: usize) bool {
            if (l.gap_width[a] != l.gap_width[b]) return l.gap_width[a] > l.gap_width[b];
            return a < b;
        }
    }.wider);
    for (order) |g| {
        const owners = try arena.dupe(seq.TextIx, layout.owners[g].items);
        std.mem.sort(seq.TextIx, owners, texts, struct {
            fn wider(t: *Texts, a: seq.TextIx, b: seq.TextIx) bool {
                const wa = t.widest(a);
                const wb = t.widest(b);
                if (wa != wb) return wa > wb;
                return a < b;
            }
        }.wider);
        for (owners) |t| {
            if (texts.canBreak(t)) return try texts.breakOnce(t);
        }
    }
    return false;
}

test {
    _ = @import("tb_test.zig");
}
