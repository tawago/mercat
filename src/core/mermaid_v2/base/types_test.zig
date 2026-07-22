//! Unit tests for `base/types.zig`.
//!
//! Split out of `base/types.zig` (the established `x.zig` → `x_test.zig` pattern:
//! see `layout.zig` → `layout/layout_test.zig`, `layout/fan.zig` →
//! `fan_test.zig`) so the primitive module stays under the stricter
//! mermaid_v2 500-line cap with room for new shared helpers.

const std = @import("std");
const prim = @import("types.zig");

const NodeId = prim.NodeId;
const EdgeId = prim.EdgeId;
const ClusterId = prim.ClusterId;
const Direction = prim.Direction;
const Dir4 = prim.Dir4;
const EdgeKind = prim.EdgeKind;
const EdgeRole = prim.EdgeRole;
const Shape = prim.Shape;
const displayWidth = prim.displayWidth;
const truncateToWidth = prim.truncateToWidth;
const wrapToWidth = prim.wrapToWidth;

test "prim: NodeId/EdgeId/ClusterId are u32" {
    const n: NodeId = std.math.maxInt(u32);
    const e: EdgeId = 0;
    const c: ClusterId = 42;
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), n);
    try std.testing.expectEqual(@as(u32, 0), e);
    try std.testing.expectEqual(@as(u32, 42), c);
}

test "prim: Direction variants" {
    const d: Direction = .LR;
    try std.testing.expect(d == .LR);
    try std.testing.expect(d != .TD);
}

test "prim: Dir4 variants" {
    const dirs = [_]Dir4{ .north, .east, .south, .west };
    try std.testing.expectEqual(@as(usize, 4), dirs.len);
}

test "prim: EdgeKind variants" {
    const k: EdgeKind = .dotted;
    try std.testing.expect(k != .solid);
    try std.testing.expect(k != .thick);
    try std.testing.expect(k != .invisible);
}

test "prim: EdgeRole variants exist" {
    const roles = [_]EdgeRole{
        .forward,      .back_edge,       .fan_out_trunk,
        .fan_out_rail, .fan_in_trunk,    .fan_in_rail,
        .self_loop,    .cluster_internal,
    };
    try std.testing.expectEqual(@as(usize, 8), roles.len);
}

test "prim: Shape variants" {
    const shapes = [_]Shape{
        .rect,           .round,       .stadium,     .subroutine,
        .cylinder,       .circle,      .asymmetric_left, .asymmetric_right,
        .rhombus,        .hexagon,     .parallelogram, .trapezoid,
    };
    try std.testing.expectEqual(@as(usize, 12), shapes.len);
}

test "prim: displayWidth pure ASCII" {
    try std.testing.expectEqual(@as(u32, 0), displayWidth(""));
    try std.testing.expectEqual(@as(u32, 5), displayWidth("hello"));
    try std.testing.expectEqual(@as(u32, 11), displayWidth("hello world"));
}

test "prim: displayWidth CJK is width-2 per char" {
    // "日本" = two CJK ideographs, each display-width 2.
    try std.testing.expectEqual(@as(u32, 4), displayWidth("日本"));
    // "한국어" = three Hangul syllables, each width 2.
    try std.testing.expectEqual(@as(u32, 6), displayWidth("한국어"));
}

test "prim: displayWidth mixed ASCII + CJK" {
    // "A日B" = 1 + 2 + 1 = 4 columns.
    try std.testing.expectEqual(@as(u32, 4), displayWidth("A日B"));
    // "x日本y" = 1 + 2 + 2 + 1 = 6.
    try std.testing.expectEqual(@as(u32, 6), displayWidth("x日本y"));
}

test "prim: truncateToWidth respects budget and codepoint boundary" {
    // Pure ASCII: exact prefix.
    try std.testing.expectEqualStrings("hel", truncateToWidth("hello", 3));
    try std.testing.expectEqualStrings("hello", truncateToWidth("hello", 99));
    try std.testing.expectEqualStrings("", truncateToWidth("hello", 0));

    // Mixed: budget 3 over "A日B" — "A" (1) + "日" (2) = 3 fits, "B" would
    // push to 4. Result is "A日" and must NOT split the multibyte "日".
    const out = truncateToWidth("A日B", 3);
    try std.testing.expectEqualStrings("A日", out);
    try std.testing.expectEqual(@as(u32, 3), displayWidth(out));
    // The returned slice ends exactly after a full UTF-8 codepoint.
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));

    // Budget 2 over "A日B": "A" (1) fits, "日" (2) would push to 3 — so the
    // wide char is dropped whole rather than split.
    const out2 = truncateToWidth("A日B", 2);
    try std.testing.expectEqualStrings("A", out2);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out2));

    // Budget 1 over a leading wide char: cannot fit width-2 char at all.
    try std.testing.expectEqualStrings("", truncateToWidth("日本", 1));
    try std.testing.expectEqualStrings("日", truncateToWidth("日本", 2));
}

test "prim: truncateToWidth empty input" {
    try std.testing.expectEqualStrings("", truncateToWidth("", 5));
    try std.testing.expectEqual(@as(u32, 0), displayWidth(truncateToWidth("", 5)));
}

test "prim: wrapToWidth ASCII word-wrap + width-0 guard" {
    const a = std.testing.allocator;
    const l1 = try wrapToWidth(a, "the quick brown fox", 10);
    defer a.free(l1);
    try std.testing.expectEqual(@as(usize, 2), l1.len); // "the quick" | "brown fox"
    try std.testing.expectEqualStrings("the quick", l1[0]);
    try std.testing.expectEqualStrings("brown fox", l1[1]);
    for (l1) |l| try std.testing.expect(displayWidth(l) <= 10);

    const l0 = try wrapToWidth(a, "anything here", 0); // degenerate guard
    defer a.free(l0);
    try std.testing.expectEqual(@as(usize, 1), l0.len);
    try std.testing.expectEqualStrings("anything here", l0[0]);
}

test "prim: wrapToWidth hard sentinel breaks combine with soft wrap" {
    const a = std.testing.allocator;
    const hard = try wrapToWidth(a, "alpha\nbeta gamma", 99); // \n always breaks
    defer a.free(hard);
    try std.testing.expectEqual(@as(usize, 2), hard.len);
    try std.testing.expectEqualStrings("alpha", hard[0]);
    try std.testing.expectEqualStrings("beta gamma", hard[1]);

    const both = try wrapToWidth(a, "one two\nthree four five", 8);
    defer a.free(both);
    // "one two" | "three" | "four" | "five"
    try std.testing.expectEqual(@as(usize, 4), both.len);
    try std.testing.expectEqualStrings("one two", both[0]);
    try std.testing.expectEqualStrings("three", both[1]);
    try std.testing.expectEqualStrings("five", both[3]);
    for (both) |l| try std.testing.expect(displayWidth(l) <= 8);
}

test "prim: wrapToWidth hard-splits a spaceless mega-word, bounds every line" {
    const a = std.testing.allocator;
    const mega = try wrapToWidth(a, "abcdefghij", 4); // "abcd"|"efgh"|"ij"
    defer a.free(mega);
    try std.testing.expectEqual(@as(usize, 3), mega.len);
    try std.testing.expectEqualStrings("abcd", mega[0]);
    try std.testing.expectEqualStrings("ij", mega[2]);
    for (mega) |l| try std.testing.expect(displayWidth(l) <= 4);

    const after = try wrapToWidth(a, "hi superlongword", 6);
    defer a.free(after);
    try std.testing.expectEqualStrings("hi", after[0]);
    for (after) |l| try std.testing.expect(displayWidth(l) <= 6);

    const cjk = try wrapToWidth(a, "日本語テスト", 4); // 2 cols/char
    defer a.free(cjk);
    for (cjk) |l| try std.testing.expect(displayWidth(l) <= 4);
}
