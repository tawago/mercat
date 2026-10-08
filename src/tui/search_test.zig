const std = @import("std");
const search_mod = @import("search.zig");
const line_mod = @import("../core/markdown/render/line.zig");
const Viewport = @import("widgets/viewport.zig").Viewport;

const Search = search_mod.Search;
const Prompt = search_mod.Prompt;
const Match = search_mod.Match;
const Line = line_mod.Line;
const Span = line_mod.Span;

fn lines3(storage: *[3][1]Span, a: []const u8, b: []const u8, c: []const u8) [3]Line {
    storage.* = .{ .{.{ .text = a, .style = .body }}, .{.{ .text = b, .style = .body }}, .{.{ .text = c, .style = .body }} };
    return .{ .{ .spans = &storage[0] }, .{ .spans = &storage[1] }, .{ .spans = &storage[2] } };
}

test "smart case: lowercase ignores case, any uppercase is exact" {
    try std.testing.expect(!search_mod.isCaseSensitive("mermaid"));
    try std.testing.expect(search_mod.isCaseSensitive("Mermaid"));
    try std.testing.expect(!search_mod.isCaseSensitive("über 2"));

    const allocator = std.testing.allocator;
    var spans: [3][1]Span = undefined;
    const lines = lines3(&spans, "Mermaid diagrams", "mermaid MERMAID", "none here");

    var search = Search.init(allocator);
    defer search.deinit();
    try search.setPattern("mermaid", &lines);
    try std.testing.expectEqual(@as(usize, 3), search.matches.items.len);
    try search.setPattern("Mermaid", &lines);
    try std.testing.expectEqual(@as(usize, 1), search.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), search.matches.items[0].line);
}

test "matches span boundaries and report display columns" {
    const allocator = std.testing.allocator;
    var spans = [_]Span{
        .{ .text = "│ 日本 mer", .style = .body },
        .{ .text = "maid and mermaid", .style = .code },
    };
    const lines = [_]Line{.{ .spans = &spans }};

    var search = Search.init(allocator);
    defer search.deinit();
    try search.setPattern("mermaid", &lines);
    try std.testing.expectEqual(@as(usize, 2), search.matches.items.len);
    // "│ 日本 " is 1 + 1 + 4 + 1 = 7 columns wide.
    try std.testing.expectEqual(Match{ .line = 0, .col_start = 7, .col_end = 14 }, search.matches.items[0]);
    try std.testing.expectEqual(Match{ .line = 0, .col_start = 19, .col_end = 26 }, search.matches.items[1]);

    try search.setPattern("日本", &lines);
    try std.testing.expectEqual(Match{ .line = 0, .col_start = 2, .col_end = 6 }, search.matches.items[0]);
}

test "matches do not overlap" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Match) = .empty;
    defer out.deinit(allocator);
    try search_mod.findInLine(allocator, &out, 4, "aaaa", "aa", true);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(usize, 2), out.items[1].col_start);
    try std.testing.expectEqual(@as(usize, 4), out.items[1].line);
}

test "next and previous wrap around the document" {
    const allocator = std.testing.allocator;
    var spans: [3][1]Span = undefined;
    const lines = lines3(&spans, "foo", "bar foo", "foo");

    var search = Search.init(allocator);
    defer search.deinit();
    try search.setPattern("foo", &lines);
    const view = Viewport{ .top = 0, .height = 3, .total = 3 };

    try std.testing.expectEqual(@as(usize, 0), search.step(.forward, view).?.line);
    try std.testing.expectEqual(@as(usize, 1), search.step(.forward, view).?.line);
    try std.testing.expectEqual(@as(usize, 2), search.step(.forward, view).?.line);
    try std.testing.expectEqual(@as(usize, 0), search.step(.forward, view).?.line);
    try std.testing.expectEqual(@as(usize, 2), search.step(.backward, view).?.line);
    try std.testing.expectEqual(@as(usize, 3), search.current.? + 1);

    const status = try search.statusText(allocator);
    defer allocator.free(status);
    try std.testing.expectEqualStrings("[3/3] /foo", status);
}

test "step restarts from the view when the current match scrolled away" {
    const allocator = std.testing.allocator;
    var spans: [3][1]Span = undefined;
    const lines = lines3(&spans, "foo", "x", "foo");
    var search = Search.init(allocator);
    defer search.deinit();
    try search.setPattern("foo", &lines);
    _ = search.selectFrom(0, .forward);

    const scrolled = Viewport{ .top = 2, .height = 1, .total = 3 };
    try std.testing.expectEqual(@as(usize, 2), search.step(.forward, scrolled).?.line);
    const at_middle = Viewport{ .top = 1, .height = 1, .total = 3 };
    try std.testing.expectEqual(@as(usize, 0), search.step(.backward, at_middle).?.line);
}

test "matchesOnLine and isCurrent drive highlighting" {
    const allocator = std.testing.allocator;
    var spans: [3][1]Span = undefined;
    const lines = lines3(&spans, "ab ab", "", "ab");
    var search = Search.init(allocator);
    defer search.deinit();
    try search.setPattern("ab", &lines);
    _ = search.selectFrom(0, .forward);
    _ = search.step(.forward, .{ .height = 3, .total = 3 });

    const row0 = search.matchesOnLine(0);
    try std.testing.expectEqual(@as(usize, 2), row0.len);
    try std.testing.expect(!search.isCurrent(row0[0]));
    try std.testing.expect(search.isCurrent(row0[1]));
    try std.testing.expectEqual(@as(usize, 0), search.matchesOnLine(1).len);
    try std.testing.expectEqual(@as(usize, 1), search.matchesOnLine(2).len);
}

test "reveal scrolls an off-screen match into view and leaves visible ones" {
    var view = Viewport{ .top = 0, .height = 9, .total = 100 };
    search_mod.reveal(&view, 5);
    try std.testing.expectEqual(@as(usize, 0), view.top);
    for ([_]usize{ 50, 99 }) |line| {
        search_mod.reveal(&view, line);
        try std.testing.expect(view.top <= line and line < view.top + view.height);
    }
}

test "prompt searches incrementally, Esc restores, Enter commits" {
    const allocator = std.testing.allocator;
    var storage: [40][1]Span = undefined;
    var lines: [40]Line = undefined;
    for (&storage, &lines, 0..) |*s, *l, i| {
        s.* = .{.{ .text = if (i == 30) "needle here" else if (i == 35) "other" else "hay", .style = .body }};
        l.* = .{ .spans = s };
    }

    var search = Search.init(allocator);
    defer search.deinit();
    try search.setPattern("other", &lines);
    var prompt = Prompt.init(allocator);
    defer prompt.deinit();
    var view = Viewport{ .top = 2, .height = 10, .total = 40 };

    try prompt.begin(&search, view);
    try prompt.insert("nee", &search, &view, &lines);
    try std.testing.expectEqual(@as(usize, 30), search.currentMatch().?.line);
    try std.testing.expect(view.top <= 30 and view.visibleEnd() > 30);

    try prompt.insert("x", &search, &view, &lines);
    try std.testing.expect(search.currentMatch() == null);
    try std.testing.expectEqual(@as(usize, 2), view.top);
    try std.testing.expect(try prompt.backspace(&search, &view, &lines));
    try std.testing.expectEqual(@as(usize, 30), search.currentMatch().?.line);

    try prompt.cancel(&search, &view, &lines);
    try std.testing.expect(!prompt.active);
    try std.testing.expectEqual(@as(usize, 2), view.top);
    try std.testing.expectEqualStrings("other", search.pattern.items);

    try prompt.begin(&search, view);
    try prompt.insert("NEEDLE", &search, &view, &lines);
    try std.testing.expect(search.currentMatch() == null);
    try prompt.clearQuery(&search, &view, &lines);
    try prompt.insert("needle", &search, &view, &lines);
    try prompt.commit(&search, &view, &lines);
    try std.testing.expect(!prompt.active);
    try std.testing.expectEqualStrings("needle", search.pattern.items);
    try std.testing.expectEqual(@as(usize, 30), search.currentMatch().?.line);
}

test "empty Enter clears the search; backspace on empty cancels" {
    const allocator = std.testing.allocator;
    var spans: [3][1]Span = undefined;
    const lines = lines3(&spans, "a", "foo", "c");
    var search = Search.init(allocator);
    defer search.deinit();
    try search.setPattern("foo", &lines);
    var prompt = Prompt.init(allocator);
    defer prompt.deinit();
    var view = Viewport{ .top = 0, .height = 3, .total = 3 };

    try prompt.begin(&search, view);
    try std.testing.expect(!(try prompt.backspace(&search, &view, &lines)));
    try std.testing.expect(!prompt.active);
    try std.testing.expectEqualStrings("foo", search.pattern.items);
    try std.testing.expectEqual(@as(usize, 1), search.currentMatch().?.line);

    try prompt.begin(&search, view);
    try prompt.commit(&search, &view, &lines);
    try std.testing.expect(!prompt.active);
    try std.testing.expect(!search.hasPattern());
    try std.testing.expectEqual(@as(usize, 0), search.matches.items.len);
    try std.testing.expect(search.currentMatch() == null);
}

test "backspace removes a whole UTF-8 character" {
    const allocator = std.testing.allocator;
    var spans: [3][1]Span = undefined;
    const lines = lines3(&spans, "a", "b", "c");
    var search = Search.init(allocator);
    defer search.deinit();
    var prompt = Prompt.init(allocator);
    defer prompt.deinit();
    var view = Viewport{ .top = 0, .height = 3, .total = 3 };
    try prompt.begin(&search, view);
    try prompt.insert("aé", &search, &view, &lines);
    _ = try prompt.backspace(&search, &view, &lines);
    try std.testing.expectEqualStrings("a", prompt.query.items);
}
