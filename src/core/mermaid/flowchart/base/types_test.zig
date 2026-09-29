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
        .forward,         .back_edge,        .fan_out_rail,
        .fan_out_dropper, .fan_in_rail,      .fan_in_dropper,
        .self_loop,       .cluster_internal,
    };
    try std.testing.expectEqual(@as(usize, 8), roles.len);
}

test "prim: Shape variants" {
    const shapes = [_]Shape{
        .rect,     .round,   .stadium,         .subroutine,
        .cylinder, .circle,  .asymmetric_left, .asymmetric_right,
        .rhombus,  .hexagon, .parallelogram,   .trapezoid,
    };
    try std.testing.expectEqual(@as(usize, 12), shapes.len);
}

test "prim: displayWidth pure ASCII" {
    try std.testing.expectEqual(@as(u32, 0), displayWidth(""));
    try std.testing.expectEqual(@as(u32, 5), displayWidth("hello"));
    try std.testing.expectEqual(@as(u32, 11), displayWidth("hello world"));
}

test "prim: displayWidth CJK is width-2 per char" {
    try std.testing.expectEqual(@as(u32, 4), displayWidth("日本"));
    try std.testing.expectEqual(@as(u32, 6), displayWidth("한국어"));
}

test "prim: displayWidth mixed ASCII + CJK" {
    try std.testing.expectEqual(@as(u32, 4), displayWidth("A日B"));
    try std.testing.expectEqual(@as(u32, 6), displayWidth("x日本y"));
}

test "prim: truncateToWidth respects budget and codepoint boundary" {
    try std.testing.expectEqualStrings("hel", truncateToWidth("hello", 3));
    try std.testing.expectEqualStrings("hello", truncateToWidth("hello", 99));
    try std.testing.expectEqualStrings("", truncateToWidth("hello", 0));

    const out = truncateToWidth("A日B", 3);
    try std.testing.expectEqualStrings("A日", out);
    try std.testing.expectEqual(@as(u32, 3), displayWidth(out));
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));

    const out2 = truncateToWidth("A日B", 2);
    try std.testing.expectEqualStrings("A", out2);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out2));

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
    try std.testing.expectEqual(@as(usize, 2), l1.len);
    try std.testing.expectEqualStrings("the quick", l1[0]);
    try std.testing.expectEqualStrings("brown fox", l1[1]);
    for (l1) |l| try std.testing.expect(displayWidth(l) <= 10);

    const l0 = try wrapToWidth(a, "anything here", 0);
    defer a.free(l0);
    try std.testing.expectEqual(@as(usize, 1), l0.len);
    try std.testing.expectEqualStrings("anything here", l0[0]);
}

test "prim: wrapToWidth hard sentinel breaks combine with soft wrap" {
    const a = std.testing.allocator;
    const hard = try wrapToWidth(a, "alpha\nbeta gamma", 99);
    defer a.free(hard);
    try std.testing.expectEqual(@as(usize, 2), hard.len);
    try std.testing.expectEqualStrings("alpha", hard[0]);
    try std.testing.expectEqualStrings("beta gamma", hard[1]);

    const both = try wrapToWidth(a, "one two\nthree four five", 8);
    defer a.free(both);
    try std.testing.expectEqual(@as(usize, 4), both.len);
    try std.testing.expectEqualStrings("one two", both[0]);
    try std.testing.expectEqualStrings("three", both[1]);
    try std.testing.expectEqualStrings("five", both[3]);
    for (both) |l| try std.testing.expect(displayWidth(l) <= 8);
}

test "prim: wrapToWidth hard-splits a spaceless mega-word, bounds every line" {
    const a = std.testing.allocator;
    const mega = try wrapToWidth(a, "abcdefghij", 4);
    defer a.free(mega);
    try std.testing.expectEqual(@as(usize, 3), mega.len);
    try std.testing.expectEqualStrings("abcd", mega[0]);
    try std.testing.expectEqualStrings("ij", mega[2]);
    for (mega) |l| try std.testing.expect(displayWidth(l) <= 4);

    const after = try wrapToWidth(a, "hi superlongword", 6);
    defer a.free(after);
    try std.testing.expectEqualStrings("hi", after[0]);
    for (after) |l| try std.testing.expect(displayWidth(l) <= 6);

    const cjk = try wrapToWidth(a, "日本語テスト", 4);
    defer a.free(cjk);
    for (cjk) |l| try std.testing.expect(displayWidth(l) <= 4);
}

test "prim: displayWidth measures graphemes the way a terminal shows them" {
    try std.testing.expectEqual(@as(u32, 2), displayWidth("\u{1F680}"));
    try std.testing.expectEqual(@as(u32, 9), displayWidth("\u{1F680} Launch"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("\u{2705}"));
    try std.testing.expectEqual(@as(u32, 4), displayWidth("cafe\u{0301}"));
    try std.testing.expectEqual(@as(u32, 4), displayWidth("café"));
    try std.testing.expectEqual(@as(u32, 5), displayWidth("nai\u{0308}ve"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("\u{2764}\u{FE0F}"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("\u{1F1EF}\u{1F1F5}"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("\u{1F44D}\u{1F3FD}"));
}

test "prim: codepointWidth agrees with the authority for a scalar in isolation" {
    try std.testing.expectEqual(@as(u32, 2), prim.codepointWidth(0x1F680));
    try std.testing.expectEqual(@as(u32, 2), prim.codepointWidth('日'));
    try std.testing.expectEqual(@as(u32, 1), prim.codepointWidth('A'));
    try std.testing.expectEqual(@as(u32, 1), prim.codepointWidth(0x00BB));
    try std.testing.expectEqual(@as(u32, 4), prim.codepointWidth('\t'));
    try std.testing.expectEqual(@as(u32, 0), prim.codepointWidth(prim.LINE_BREAK));
}

test "prim: truncateToWidth never splits inside a grapheme" {
    try std.testing.expectEqualStrings("caf", truncateToWidth("cafe\u{0301}", 3));
    try std.testing.expectEqualStrings("cafe\u{0301}", truncateToWidth("cafe\u{0301}", 4));
    try std.testing.expectEqualStrings("", truncateToWidth("\u{1F680}x", 1));
    try std.testing.expectEqualStrings("\u{1F680}", truncateToWidth("\u{1F680}x", 2));
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    try std.testing.expectEqualStrings("", truncateToWidth(family ++ "!", 1));
    try std.testing.expectEqualStrings(family, truncateToWidth(family ++ "!", 2));
    try std.testing.expectEqualStrings("", truncateToWidth("\u{1F1EF}\u{1F1F5}", 1));
    try std.testing.expectEqualStrings("", truncateToWidth("\u{2764}\u{FE0F}", 1));
    try std.testing.expectEqualStrings("\u{2764}\u{FE0F}", truncateToWidth("\u{2764}\u{FE0F}", 2));
    for ([_][]const u8{ "cafe\u{0301}", family, "\u{1F1EF}\u{1F1F5}", "\u{2764}\u{FE0F}" }) |text| {
        var w: u32 = 0;
        while (w <= 3) : (w += 1) {
            const cut = truncateToWidth(text, w);
            try std.testing.expect(cut.len == 0 or cut.len == text.len);
        }
    }
}

test "prim: wrapToWidth hard-splits a word on grapheme boundaries" {
    const a = std.testing.allocator;
    const lines = try wrapToWidth(a, "e\u{0301}e\u{0301}e\u{0301}", 2);
    defer a.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("e\u{0301}e\u{0301}", lines[0]);
    try std.testing.expectEqualStrings("e\u{0301}", lines[1]);

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const one = try wrapToWidth(a, family ++ family, 1);
    defer a.free(one);
    try std.testing.expectEqual(@as(usize, 2), one.len);
    try std.testing.expectEqualStrings(family, one[0]);
    try std.testing.expectEqualStrings(family, one[1]);
}

test "prim: wrapToWidth never exceeds its cap on text the strict measure rejects" {
    const a = std.testing.allocator;
    const inputs = [_][]const u8{
        "e\u{0301}\u{200B}e\u{0301}e\u{0301}",
        "\u{00AD}e\u{0301}e\u{0301}e\u{0301}",
        "e\u{0301}\x01e\u{0301}e\u{0301}",
        "e\u{0301}\xffe\u{0301}e\u{0301} \x80\x80e\u{0301}",
    };
    for (inputs) |text| {
        var cap: u32 = 1;
        while (cap <= 4) : (cap += 1) {
            const lines = try wrapToWidth(a, text, cap);
            defer a.free(lines);
            for (lines) |line| try std.testing.expect(displayWidth(line) <= cap);
        }
    }
    const three = try wrapToWidth(a, "\u{00AD}e\u{0301}e\u{0301}e\u{0301}", 3);
    defer a.free(three);
    try std.testing.expectEqual(@as(usize, 2), three.len);
    try std.testing.expectEqualStrings("\u{00AD}e\u{0301}e\u{0301}", three[0]);
    try std.testing.expectEqualStrings("e\u{0301}", three[1]);
}
