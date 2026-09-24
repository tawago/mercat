//! The reader on small hand-drawn grids.

const std = @import("std");
const check = @import("check");

fn arrow(a: []const u8, b: []const u8) check.Relation {
    return .{ .a = .{ .label = a }, .end_a = .none, .b = .{ .label = b }, .end_b = .filled, .stroke = .solid };
}

fn judge(arena: *std.heap.ArenaAllocator, labels: []const []const u8, edges: []const check.Relation, text: []const u8) !check.Judgement {
    return check.judge(arena.allocator(), .{ .labels = labels, .edges = edges }, text);
}

const star =
    \\         ┌───┐
    \\         │ A │
    \\         └─┬─┘
    \\  ┌────────┼────────┐
    \\  │        │        │
    \\  ▼        ▼        ▼
    \\┌───┐    ┌───┐    ┌───┐
    \\│ B │    │ C │    │ D │
    \\└───┘    └───┘    └───┘
;

test "a fan-out rail reads back as its members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = try judge(&arena, &.{ "A", "B", "C", "D" }, &.{ arrow("A", "B"), arrow("A", "C"), arrow("A", "D") }, star);
    try std.testing.expectEqual(check.Verdict.faithful, j.verdict);
}

test "a declared edge the ink does not draw is lost" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = try judge(&arena, &.{ "A", "B", "C", "D" }, &.{ arrow("A", "B"), arrow("A", "C"), arrow("A", "D"), arrow("B", "C") }, star);
    try std.testing.expectEqual(check.Verdict.lying, j.verdict);
    try std.testing.expectEqual(@as(usize, 1), j.lost.len);
}

test "a stroke joining another source's rail fabricates a relation" {
    const text =
        \\┌───┐    ┌───┐
        \\│ A │    │ D │
        \\└─┬─┘    └─┬─┘
        \\  │       ┌┘
        \\ ┌┴───────┤
        \\ │        │
        \\ ▼        ▼
        \\┌───┐   ┌───┐
        \\│ B │   │ C │
        \\└───┘   └───┘
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = try judge(&arena, &.{ "A", "D", "B", "C" }, &.{ arrow("A", "B"), arrow("A", "C"), arrow("D", "C") }, text);
    try std.testing.expectEqual(check.Verdict.lying, j.verdict);
    try std.testing.expectEqual(@as(usize, 1), j.fabricated.len);
    try std.testing.expectEqual(@as(usize, 0), j.lost.len);
}

test "a fan-in rail does not relate its sources to each other" {
    const text =
        \\┌───┐    ┌───┐
        \\│ B │    │ C │
        \\└─┬─┘    └─┬─┘
        \\  └────┬───┘
        \\       ▼
        \\     ┌───┐
        \\     │ A │
        \\     └───┘
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = try judge(&arena, &.{ "B", "C", "A" }, &.{ arrow("B", "A"), arrow("C", "A") }, text);
    try std.testing.expectEqual(check.Verdict.faithful, j.verdict);
}

test "a crossing is read straight through" {
    const text =
        \\    ┌───┐
        \\    │ A │
        \\    └─┬─┘
        \\┌───┐ │  ┌───┐
        \\│ C ├───►│ D │
        \\└───┘ │  └───┘
        \\      ▼
        \\    ┌───┐
        \\    │ B │
        \\    └───┘
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = try judge(&arena, &.{ "A", "B", "C", "D" }, &.{ arrow("A", "B"), arrow("C", "D") }, text);
    try std.testing.expectEqual(check.Verdict.faithful, j.verdict);
}

test "a clipped grid is not charged for what the clip hides" {
    const text =
        \\┌───┐
        \\│ A ├──────»
        \\└───┘
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = try judge(&arena, &.{ "A", "B" }, &.{arrow("A", "B")}, text);
    try std.testing.expect(j.clipped);
    try std.testing.expectEqual(check.Verdict.faithful, j.verdict);
}

test "a box naming no declared node makes the grid undecodable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = try judge(&arena, &.{ "A", "B", "C", "E" }, &.{ arrow("A", "B"), arrow("A", "C"), arrow("A", "E") }, star);
    try std.testing.expectEqual(check.Verdict.undecodable, j.verdict);
    try std.testing.expectEqual(@as(usize, 1), j.unknown_boxes.len);
}

test "wrapped and broken labels name their node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(try check.key(a, "one<br/>two three"), try check.key(a, "one\ntwo\nthree"));
}
