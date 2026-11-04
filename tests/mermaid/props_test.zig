//! Properties of rendered flowcharts, checked on seeded generated sources.
//! Nothing here pins bytes: each property compares a render with its own
//! source, or with another render of the same graph.

const std = @import("std");
const check = @import("check");
const flowchart = @import("flowchart");
const gen = @import("gen.zig");
const declared = @import("declared.zig").declared;

const seeds = 120;
const widths = [_]u32{ 120, 48 };

// Seeds whose render at some width in `widths` does not read back as
// declared today. Each list below may only shrink: a seed that starts to
// hold must leave its list, and no seed may join one.
const known_lying = [_]u64{ 1, 4, 9, 14, 17, 19, 21, 23, 24, 30, 33, 47, 50, 52, 54, 55, 56, 62, 64, 75, 80, 86, 87, 89, 90, 93, 94, 95, 98, 99, 108, 109, 110, 111, 112, 113, 117 };

// Seeds whose labelled drawing changes when only node ids change.
const known_renaming = [_]u64{ 0, 17, 18, 19, 38, 46 };

fn render(arena: std.mem.Allocator, source: []const u8, width: u32) ![]const u8 {
    std.testing.log_level = .err;
    const result = try flowchart.render(arena, source, .{ .max_width = width });
    return arena.dupe(u8, result.output);
}

// The declared relation, or null when the parser refuses the source; a
// refused source must render as the fallback, never as a partial drawing.
fn parsed(arena: std.mem.Allocator, source: []const u8) !?check.Declared {
    return declared(arena, source) catch {
        std.testing.log_level = .err;
        const result = try flowchart.render(arena, source, .{});
        try std.testing.expect(result.is_fallback);
        return null;
    };
}

// Runs `fails` on every seed and holds the failing set to `known`.
fn ratchet(comptime what: []const u8, known: []const u64, count: u64, fails: *const fn (std.mem.Allocator, u64) anyerror!bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var joined: std.ArrayList(u64) = .empty;
    defer joined.deinit(std.testing.allocator);
    var left: std.ArrayList(u64) = .empty;
    defer left.deinit(std.testing.allocator);
    for (0..count) |seed| {
        _ = arena_state.reset(.retain_capacity);
        const failed = try fails(arena_state.allocator(), seed);
        const listed = std.mem.indexOfScalar(u64, known, seed) != null;
        if (failed and !listed) try joined.append(std.testing.allocator, seed);
        if (!failed and listed) try left.append(std.testing.allocator, seed);
    }
    if (joined.items.len > 0) std.debug.print(what ++ ": seeds that now fail: {any}\n", .{joined.items});
    if (left.items.len > 0) std.debug.print(what ++ ": seeds that now hold; drop them from the list: {any}\n", .{left.items});
    try std.testing.expectEqual(@as(usize, 0), joined.items.len + left.items.len);
}

fn lies(arena: std.mem.Allocator, seed: u64) !bool {
    const source = try gen.flowchart(arena, seed, .{});
    const want = try parsed(arena, source) orelse return false;
    var lied = false;
    for (widths) |w| {
        const j = try check.judge(arena, want, try render(arena, source, w));
        // Every glyph the renderer draws must be one the reader knows, on every seed and width.
        for (j.findings) |f| if (f.kind == .unknown_glyph) {
            std.debug.print("seed {d} at width {d}: unknown glyph at {d},{d}\n", .{ seed, w, f.row, f.col });
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(@as(usize, 0), j.unknown_boxes.len);
        lied = lied or j.verdict != .faithful;
    }
    return lied;
}

test "generated flowcharts read back as declared in known glyphs, apart from the known lies" {
    try ratchet("readback", &known_lying, seeds, lies);
}

test "rendering is deterministic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for (0..seeds / 4) |s| {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const source = try gen.flowchart(arena, s, .{});
        try std.testing.expectEqualStrings(try render(arena, source, 80), try render(arena, source, 80));
    }
}

const renamed = [_][]const u8{ "zz", "k1", "M", "w_2", "Q7", "a", "long_name", "B2", "c", "d9", "T", "s", "u3", "v", "y", "g", "h" };

fn renames(arena: std.mem.Allocator, seed: u64) !bool {
    const plain = try gen.flowchart(arena, seed, .{ .labelled = true });
    if (try parsed(arena, plain) == null) return false;
    const other = try gen.flowchart(arena, seed, .{ .labelled = true, .ids = &renamed });
    return !std.mem.eql(u8, try render(arena, plain, 100), try render(arena, other, 100));
}

test "renaming node ids does not change a labelled drawing, apart from the known cases" {
    try ratchet("renaming", &known_renaming, seeds / 2, renames);
}

fn readsBack(arena: std.mem.Allocator, source: []const u8, width: u32) !check.Verdict {
    const want = (try parsed(arena, source)).?;
    return (try check.judge(arena, want, try render(arena, source, width))).verdict;
}

test "back edges into and out of one node keep apart; same-source back edges share one trunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in_and_out =
        \\flowchart LR
        \\  Submit[SubmitOrder] --> Validate[ValidatePayment]
        \\  Validate --> Charge[ChargeCard]
        \\  Charge --> Ship[ScheduleShipment]
        \\  Ship --> Done[OrderComplete]
        \\  Charge -->|declined| Validate
        \\  Ship -->|no stock| Submit
        \\  Done -->|refund| Charge
        \\
    ;
    const one_source =
        \\flowchart TD
        \\  Start --> Build --> Test --> Lint --> Package --> Deploy
        \\  Deploy -->|rollback| Package
        \\  Deploy -->|retest| Test
        \\  Deploy -->|rebuild| Build
        \\  Deploy -->|restart| Start
        \\
    ;
    for ([_]u32{ 60, 90, 120 }) |w| {
        try std.testing.expectEqual(check.Verdict.faithful, try readsBack(a, in_and_out, w));
        try std.testing.expectEqual(check.Verdict.faithful, try readsBack(a, one_source, w));
    }
    const out = try render(a, one_source, 120);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "┤"));
}

test "a self-loop takes the side its node's back edges leave free" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\flowchart LR
        \\  Poll[PollQueue] --> Poll
        \\  Poll --> Work[ProcessJob]
        \\  Work --> Work
        \\  Work --> Ack[AckMessage]
        \\  Ack --> Poll
        \\  Work -->|fail| Poll
        \\  Ack -->|nack| Work
        \\
    ;
    for ([_]u32{ 60, 120 }) |w| try std.testing.expectEqual(check.Verdict.faithful, try readsBack(a, source, w));
    const out = try render(a, source, 120);
    var rows = std.mem.splitScalar(u8, out, '\n');
    const top = rows.next().?;
    try std.testing.expect(std.mem.indexOf(u8, top, "┌") != null);
}
