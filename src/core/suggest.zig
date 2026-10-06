//! "Did you mean …?" support shared by the argument parser and config loader.
const std = @import("std");

/// Levenshtein distance for short strings (inputs longer than 64 bytes
/// return the longer length, which never wins a suggestion).
pub fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return @max(a.len, b.len);
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// The candidate closest to `word`, if it is plausibly a typo of it: within
/// two edits, or a third of the word's length for long words.
pub fn closest(word: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (candidates) |candidate| {
        const dist = editDistance(word, candidate);
        if (dist < best_distance) {
            best_distance = dist;
            best = candidate;
        }
    }
    const limit = @max(@as(usize, 2), word.len / 3);
    if (best_distance == 0 or best_distance > limit) return null;
    return best;
}

test "editDistance basics" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("abc", "abc"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("them", "theme"));
    try std.testing.expectEqual(@as(usize, 2), editDistance("widht", "width"));
    try std.testing.expectEqual(@as(usize, 3), editDistance("", "abc"));
}

test "closest picks plausible typos only" {
    const words = [_][]const u8{ "theme", "width", "frontmatter" };
    try std.testing.expectEqualStrings("theme", closest("them", &words).?);
    try std.testing.expectEqualStrings("frontmatter", closest("frontmater", &words).?);
    try std.testing.expectEqual(@as(?[]const u8, null), closest("zzzzzz", &words));
    try std.testing.expectEqual(@as(?[]const u8, null), closest("theme", &words));
}
