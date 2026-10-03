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
const known_lying = [_]u64{ 1, 4, 9, 14, 17, 19, 21, 23, 24, 30, 33, 36, 47, 50, 52, 54, 55, 56, 62, 64, 69, 75, 77, 80, 86, 87, 89, 90, 93, 94, 95, 98, 99, 108, 109, 110, 111, 112, 113, 117 };

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
    for (widths) |w| {
        const j = try check.judge(arena, want, try render(arena, source, w));
        if (j.verdict != .faithful) return true;
    }
    return false;
}

test "generated flowcharts read back as declared, apart from the known lies" {
    try ratchet("readback", &known_lying, seeds, lies);
}

test "the reader recognises every glyph the renderer draws" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for (0..seeds) |s| {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const source = try gen.flowchart(arena, s, .{});
        const want = try parsed(arena, source) orelse continue;
        for (widths) |w| {
            const j = try check.judge(arena, want, try render(arena, source, w));
            for (j.findings) |f| if (f.kind == .unknown_glyph) {
                std.debug.print("seed {d} at width {d}: unknown glyph at {d},{d}\n", .{ s, w, f.row, f.col });
                return error.TestUnexpectedResult;
            };
            try std.testing.expectEqual(@as(usize, 0), j.unknown_boxes.len);
        }
    }
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

test "reordering edge statements does not change the declared relation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for (0..seeds / 2) |s| {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const source = try gen.flowchart(arena, s, .{ .labelled = true });
        const a = try parsed(arena, source) orelse continue;
        const b = try declared(arena, try shuffleStatements(arena, source, s));
        try std.testing.expectEqual(a.edges.len, b.edges.len);
        try std.testing.expectEqual(a.labels.len, b.labels.len);
        for (a.edges) |e| try std.testing.expectEqual(countEdge(a.edges, e), countEdge(b.edges, e));
    }
}

// Moves top-level statements after the header into a seeded order, keeping
// subgraph blocks whole.
fn shuffleStatements(arena: std.mem.Allocator, source: []const u8, seed: u64) ![]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var out: std.ArrayList(u8) = .empty;
    var tail: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var header = true;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " ");
        const opens = std.mem.startsWith(u8, t, "subgraph");
        const closes = std.mem.eql(u8, t, "end");
        if (header or depth > 0 or opens or t.len == 0 or std.mem.startsWith(u8, t, "%%")) {
            try out.appendSlice(arena, line);
            try out.append(arena, '\n');
            header = false;
            if (opens) depth += 1;
            if (closes) depth -= 1;
            continue;
        }
        try tail.append(arena, line);
    }
    var prng = std.Random.DefaultPrng.init(seed ^ 0x9e3779b97f4a7c15);
    prng.random().shuffle([]const u8, tail.items);
    for (tail.items) |line| {
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.items;
}

fn countEdge(edges: []const check.Relation, e: check.Relation) usize {
    var n: usize = 0;
    for (edges) |x| {
        if (std.mem.eql(u8, x.a.label, e.a.label) and std.mem.eql(u8, x.b.label, e.b.label) and
            x.end_a == e.end_a and x.end_b == e.end_b and x.stroke == e.stroke) n += 1;
    }
    return n;
}
