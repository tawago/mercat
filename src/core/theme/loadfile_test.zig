const std = @import("std");
const loadfile = @import("loadfile.zig");

const parseThemeTables = loadfile.parseThemeTables;
const parseInlineArray = loadfile.parseInlineArray;
const readThemeFile = loadfile.readThemeFile;
const resolveThemeDir = loadfile.resolveThemeDir;

test "parseThemeTables lands [theme] keys in .top and keeps every slot table, known or not" {
    const text =
        \\[display]
        \\theme = "light"
        \\[theme]
        \\extends = "dark"
        \\palette = "truecolor"
        \\[theme.heading1]
        \\fg = "#ff0000"
        \\bold = true
        \\prefix = "> "
        \\[theme.not_a_real_slot]
        \\fg = "#abcdef"
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);

    const v = tables.view();
    try std.testing.expectEqual(@as(usize, 2), v.top.len);
    try std.testing.expectEqualStrings("extends", v.top[0].key);
    try std.testing.expectEqualStrings("dark", v.top[0].value);
    try std.testing.expectEqual(@as(usize, 2), v.slots.len);
    try std.testing.expectEqualStrings("heading1", v.slots[0].name);
    const kvs = v.slots[0].kvs.items;
    try std.testing.expectEqual(@as(usize, 3), kvs.len);
    try std.testing.expectEqualStrings("fg", kvs[0].key);
    try std.testing.expectEqualStrings("#ff0000", kvs[0].value);
    try std.testing.expectEqualStrings("bold", kvs[1].key);
    try std.testing.expectEqualStrings("> ", kvs[2].value);
    try std.testing.expectEqualStrings("not_a_real_slot", v.slots[1].name);
}

test "document-root keys before any header land in top-level [theme]" {
    const text =
        \\extends = "dracula"
        \\[theme.heading1]
        \\fg = "#ff0000"
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tables.top.items.len);
    try std.testing.expectEqualStrings("extends", tables.top.items[0].key);
    try std.testing.expectEqualStrings("dracula", tables.top.items[0].value);
    try std.testing.expectEqual(@as(usize, 1), tables.slots.items.len);
    try std.testing.expectEqualStrings("heading1", tables.slots.items[0].name);
}

test "a non-theme header after root keys turns collection off" {
    const text =
        \\extends = "dracula"
        \\[display]
        \\theme = "dark"
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), tables.top.items.len);
    try std.testing.expectEqualStrings("extends", tables.top.items[0].key);
    try std.testing.expectEqual(@as(usize, 0), tables.slots.items.len);
}

test "repeated [theme.link] blocks merge last-wins per key" {
    const text =
        \\[theme.link]
        \\fg = "#111111"
        \\underline = true
        \\[theme.link]
        \\fg = "#222222"
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tables.slots.items.len);
    const kvs = tables.slots.items[0].kvs.items;
    try std.testing.expectEqual(@as(usize, 2), kvs.len);
    try std.testing.expectEqualStrings("fg", kvs[0].key);
    try std.testing.expectEqualStrings("#222222", kvs[0].value);
    try std.testing.expectEqualStrings("underline", kvs[1].key);
}

test "readThemeFile round-trips a temp theme file; missing returns null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "solarized.toml",
        .data =
        \\[theme.heading1]
        \\fg = "#268bd2"
        ,
    });

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var tables = (try readThemeFile(std.testing.allocator, dir_path, "solarized")).?;
    defer tables.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), tables.slots.items.len);
    try std.testing.expectEqualStrings("heading1", tables.slots.items[0].name);

    const missing = try readThemeFile(std.testing.allocator, dir_path, "nonexistent");
    try std.testing.expect(missing == null);
}

test "theme-file values drop inline comments but keep a quoted `#`" {
    const text =
        \\[theme.heading1]
        \\fg = "#ff79c6" # pink
        \\bold = true # emphasis
        \\prefix = "#" # literal hash glyph
    ;
    var tables = try parseThemeTables(std.testing.allocator, text);
    defer tables.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tables.slots.items.len);
    const kvs = tables.slots.items[0].kvs.items;
    try std.testing.expectEqualStrings("#ff79c6", kvs[0].value);
    try std.testing.expectEqualStrings("true", kvs[1].value);
    try std.testing.expectEqualStrings("#", kvs[2].value);
}

test "parseInlineArray splits top-level commas and strips per-element quotes" {
    const alloc = std.testing.allocator;
    const items = (try parseInlineArray(alloc, "[\"\u{2022}\", \"\u{25E6}\", \"\u{2023}\"]")).?;
    defer {
        for (items) |it| alloc.free(it);
        alloc.free(items);
    }
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("\u{2022}", items[0]);
    try std.testing.expectEqualStrings("\u{25E6}", items[1]);
    try std.testing.expectEqualStrings("\u{2023}", items[2]);

    const commas = (try parseInlineArray(alloc, "[ \"a,b\" , \"c\" , ]")).?;
    defer {
        for (commas) |it| alloc.free(it);
        alloc.free(commas);
    }
    try std.testing.expectEqual(@as(usize, 2), commas.len);
    try std.testing.expectEqualStrings("a,b", commas[0]);

    const empty = (try parseInlineArray(alloc, "[]")).?;
    defer alloc.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expect((try parseInlineArray(alloc, "\"nope\"")) == null);
}

test "an array value survives the scanner, including a quoted `#` element" {
    const alloc = std.testing.allocator;
    var tables = try parseThemeTables(alloc,
        \\[theme.glyphs]
        \\bullets = ["#", "●"] # depth cycle
    );
    defer tables.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), tables.slots.items.len);
    const kv = tables.slots.items[0].kvs.items[0];
    try std.testing.expectEqualStrings("bullets", kv.key);
    try std.testing.expectEqualStrings("[\"#\", \"\u{25CF}\"]", kv.value);

    const items = (try parseInlineArray(alloc, kv.value)).?;
    defer {
        for (items) |it| alloc.free(it);
        alloc.free(items);
    }
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("#", items[0]);
}
