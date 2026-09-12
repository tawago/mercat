const std = @import("std");

const unicode_version = "17.0.0";
const vendor_dir = "vendor/unicode/17.0.0";
const generated_dir = "src/lib/unicode/generated";

const Range = struct {
    first: u21,
    last: u21,
    value: u8,
};

const Source = struct {
    name: []const u8,
    url: []const u8,
    sha256: []const u8,
};

const sources = [_]Source{
    .{ .name = "GraphemeBreakProperty.txt", .url = "https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakProperty.txt", .sha256 = "d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89" },
    .{ .name = "DerivedCoreProperties.txt", .url = "https://www.unicode.org/Public/17.0.0/ucd/DerivedCoreProperties.txt", .sha256 = "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08" },
    .{ .name = "EastAsianWidth.txt", .url = "https://www.unicode.org/Public/17.0.0/ucd/EastAsianWidth.txt", .sha256 = "ea7ce50f3444a050333448dffef1cadd9325af55cbb764b4a2280faf52170a33" },
    .{ .name = "emoji-data.txt", .url = "https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt", .sha256 = "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b" },
    .{ .name = "emoji-variation-sequences.txt", .url = "https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-variation-sequences.txt", .sha256 = "bb3d09ef03f206012c7532dd52dc0a21c9efddba0135ea4cf0d9201b8b9bba7e" },
    .{ .name = "emoji-sequences.txt", .url = "https://www.unicode.org/Public/17.0.0/emoji/emoji-sequences.txt", .sha256 = "12cc8267dc33cbd11ed32bcf6fc5dc2ad9c7a77bae1bdfba2f41b1b9b3ead8dd" },
    .{ .name = "emoji-zwj-sequences.txt", .url = "https://www.unicode.org/Public/17.0.0/emoji/emoji-zwj-sequences.txt", .sha256 = "5b25441daed2322b068c5e70cda522946a4f0274df864445a1965a92e5fc5cad" },
    .{ .name = "GraphemeBreakTest.txt", .url = "https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakTest.txt", .sha256 = "e2d134d2c52919bace503ebb6a551c1855fe1a1faec18478c78fff254a1793ec" },
    .{ .name = "LICENSE.txt", .url = "https://www.unicode.org/license.txt", .sha256 = "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96" },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const out_dir = if (args.len >= 2) args[1] else generated_dir;
    try generate(allocator, out_dir);
}

pub fn generate(allocator: std.mem.Allocator, out_dir: []const u8) !void {
    try verifySources(allocator);
    try std.fs.cwd().makePath(out_dir);
    try cleanGeneratedOutput(allocator, out_dir);

    var gcb: std.ArrayList(Range) = .empty;
    defer gcb.deinit(allocator);
    try parsePropertyFile(allocator, "GraphemeBreakProperty.txt", &gcb, gcbValue);

    var incb: std.ArrayList(Range) = .empty;
    defer incb.deinit(allocator);
    try parsePropertyFile(allocator, "DerivedCoreProperties.txt", &incb, incbValue);

    var wide: std.ArrayList(Range) = .empty;
    defer wide.deinit(allocator);
    try parsePropertyFile(allocator, "EastAsianWidth.txt", &wide, wideValue);

    var emoji_presentation: std.ArrayList(Range) = .empty;
    defer emoji_presentation.deinit(allocator);
    try parsePropertyFile(allocator, "emoji-data.txt", &emoji_presentation, emojiPresentationValue);

    var extended_pictographic: std.ArrayList(Range) = .empty;
    defer extended_pictographic.deinit(allocator);
    try parsePropertyFile(allocator, "emoji-data.txt", &extended_pictographic, extendedPictographicValue);

    var emoji_modifier: std.ArrayList(Range) = .empty;
    defer emoji_modifier.deinit(allocator);
    try parsePropertyFile(allocator, "emoji-data.txt", &emoji_modifier, emojiModifierValue);

    var emoji_component: std.ArrayList(Range) = .empty;
    defer emoji_component.deinit(allocator);
    try parsePropertyFile(allocator, "emoji-data.txt", &emoji_component, emojiComponentValue);

    var default_ignorable: std.ArrayList(Range) = .empty;
    defer default_ignorable.deinit(allocator);
    try parsePropertyFile(allocator, "DerivedCoreProperties.txt", &default_ignorable, defaultIgnorableValue);

    var variation_bases: std.ArrayList(Range) = .empty;
    defer variation_bases.deinit(allocator);
    try parseVariationBases(allocator, &variation_bases);

    var basic: std.ArrayList(Range) = .empty;
    defer basic.deinit(allocator);
    var sequences: std.ArrayList([]const u21) = .empty;
    defer {
        for (sequences.items) |seq| allocator.free(seq);
        sequences.deinit(allocator);
    }
    try parseEmojiSequences(allocator, "emoji-sequences.txt", &basic, &sequences);
    try parseEmojiSequences(allocator, "emoji-zwj-sequences.txt", &basic, &sequences);

    std.mem.sort(Range, gcb.items, {}, lessRange);
    std.mem.sort(Range, incb.items, {}, lessRange);
    std.mem.sort(Range, wide.items, {}, lessRange);
    std.mem.sort(Range, emoji_presentation.items, {}, lessRange);
    std.mem.sort(Range, extended_pictographic.items, {}, lessRange);
    std.mem.sort(Range, emoji_modifier.items, {}, lessRange);
    std.mem.sort(Range, emoji_component.items, {}, lessRange);
    std.mem.sort(Range, default_ignorable.items, {}, lessRange);
    std.mem.sort(Range, variation_bases.items, {}, lessRange);
    std.mem.sort(Range, basic.items, {}, lessRange);

    try writeRangeModules(allocator, out_dir, "gcb", gcb.items, 2);
    try writeRangeModules(allocator, out_dir, "incb", incb.items, 2);
    try writeRangeModules(allocator, out_dir, "wide", wide.items, 1);
    try writeRangeModules(allocator, out_dir, "emoji_presentation", emoji_presentation.items, 1);
    try writeRangeModules(allocator, out_dir, "extended_pictographic", extended_pictographic.items, 1);
    try writeRangeModules(allocator, out_dir, "emoji_modifier", emoji_modifier.items, 1);
    try writeRangeModules(allocator, out_dir, "emoji_component", emoji_component.items, 1);
    try writeRangeModules(allocator, out_dir, "default_ignorable", default_ignorable.items, 1);
    try writeRangeModules(allocator, out_dir, "variation_bases", variation_bases.items, 1);
    try writeRangeModules(allocator, out_dir, "basic_emoji", basic.items, 1);
    try writeSequenceModules(allocator, out_dir, sequences.items);
    try writeManifest(allocator, out_dir);
}

fn cleanGeneratedOutput(allocator: std.mem.Allocator, out_dir: []const u8) !void {
    var dir = try std.fs.cwd().openDir(out_dir, .{ .iterate = true });
    defer dir.close();
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    for (names.items) |name| try dir.deleteFile(name);
}

fn verifySources(allocator: std.mem.Allocator) !void {
    for (sources) |source| {
        const path = try std.fs.path.join(allocator, &.{ vendor_dir, source.name });
        defer allocator.free(path);
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
        defer allocator.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &actual, source.sha256)) {
            std.debug.print("{s}: SHA-256 mismatch; expected {s}, got {s}\n", .{ path, source.sha256, actual });
            return error.SourceChecksumMismatch;
        }
    }
}

fn parsePropertyFile(
    allocator: std.mem.Allocator,
    name: []const u8,
    out: *std.ArrayList(Range),
    valueFn: *const fn ([]const u8) ?u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ vendor_dir, name });
    defer allocator.free(path);
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const hash = std.mem.indexOfScalarPos(u8, line, semi + 1, '#') orelse line.len;
        const field = std.mem.trim(u8, line[semi + 1 .. hash], " \t");
        const value = valueFn(field) orelse continue;
        const range = try parseRange(std.mem.trim(u8, line[0..semi], " \t"));
        try out.append(allocator, .{ .first = range.first, .last = range.last, .value = value });
    }
}

fn parseVariationBases(allocator: std.mem.Allocator, out: *std.ArrayList(Range)) !void {
    const path = vendor_dir ++ "/emoji-variation-sequences.txt";
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(bytes);
    var previous: ?u21 = null;
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        var points = std.mem.tokenizeAny(u8, line[0..semi], " \t");
        const cp = try parseHex(points.next() orelse continue);
        if (previous != null and previous.? == cp) continue;
        try out.append(allocator, .{ .first = cp, .last = cp, .value = 1 });
        previous = cp;
    }
}

fn parseEmojiSequences(
    allocator: std.mem.Allocator,
    name: []const u8,
    basic: *std.ArrayList(Range),
    sequences: *std.ArrayList([]const u21),
) !void {
    const path = try std.fs.path.join(allocator, &.{ vendor_dir, name });
    defer allocator.free(path);
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024);
    defer allocator.free(bytes);
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const second = std.mem.indexOfScalarPos(u8, line, semi + 1, ';') orelse continue;
        const kind = std.mem.trim(u8, line[semi + 1 .. second], " \t");
        const points_field = std.mem.trim(u8, line[0..semi], " \t");
        if (std.mem.eql(u8, kind, "Basic_Emoji")) {
            if (std.mem.indexOf(u8, points_field, "..") != null or std.mem.indexOfScalar(u8, points_field, ' ') == null) {
                const range = try parseRange(points_field);
                try basic.append(allocator, .{ .first = range.first, .last = range.last, .value = 1 });
                continue;
            }
        }
        if (!(std.mem.eql(u8, kind, "Basic_Emoji") or
            std.mem.eql(u8, kind, "Emoji_Keycap_Sequence") or
            std.mem.eql(u8, kind, "RGI_Emoji_Flag_Sequence") or
            std.mem.eql(u8, kind, "RGI_Emoji_Tag_Sequence") or
            std.mem.eql(u8, kind, "RGI_Emoji_Modifier_Sequence") or
            std.mem.eql(u8, kind, "RGI_Emoji_ZWJ_Sequence"))) continue;

        var seq: std.ArrayList(u21) = .empty;
        errdefer seq.deinit(allocator);
        var points = std.mem.tokenizeAny(u8, points_field, " \t");
        while (points.next()) |point| try seq.append(allocator, try parseHex(point));
        try sequences.append(allocator, try seq.toOwnedSlice(allocator));
    }
}

fn gcbValue(field: []const u8) ?u8 {
    const names = [_][]const u8{ "CR", "LF", "Control", "Extend", "ZWJ", "Regional_Indicator", "Prepend", "SpacingMark", "L", "V", "T", "LV", "LVT" };
    for (names, 1..) |name, value| if (std.mem.eql(u8, field, name)) return @intCast(value);
    return null;
}

fn incbValue(field: []const u8) ?u8 {
    if (std.mem.eql(u8, field, "InCB; Linker")) return 1;
    if (std.mem.eql(u8, field, "InCB; Consonant")) return 2;
    if (std.mem.eql(u8, field, "InCB; Extend")) return 3;
    return null;
}

fn wideValue(field: []const u8) ?u8 {
    if (std.mem.eql(u8, field, "W") or std.mem.eql(u8, field, "F")) return 1;
    return null;
}

fn emojiPresentationValue(field: []const u8) ?u8 {
    if (std.mem.eql(u8, field, "Emoji_Presentation")) return 1;
    return null;
}

fn extendedPictographicValue(field: []const u8) ?u8 {
    return if (std.mem.eql(u8, field, "Extended_Pictographic")) 1 else null;
}

fn emojiModifierValue(field: []const u8) ?u8 {
    return if (std.mem.eql(u8, field, "Emoji_Modifier")) 1 else null;
}

fn emojiComponentValue(field: []const u8) ?u8 {
    return if (std.mem.eql(u8, field, "Emoji_Component")) 1 else null;
}

fn defaultIgnorableValue(field: []const u8) ?u8 {
    return if (std.mem.eql(u8, field, "Default_Ignorable_Code_Point")) 1 else null;
}

fn parseRange(field: []const u8) !struct { first: u21, last: u21 } {
    if (std.mem.indexOf(u8, field, "..")) |dots| {
        return .{ .first = try parseHex(field[0..dots]), .last = try parseHex(field[dots + 2 ..]) };
    }
    const cp = try parseHex(field);
    return .{ .first = cp, .last = cp };
}

fn parseHex(text: []const u8) !u21 {
    const cp = try std.fmt.parseInt(u32, text, 16);
    if (cp > 0x10ffff) return error.InvalidCodepoint;
    return @intCast(cp);
}

fn writeRangeModules(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    base: []const u8,
    ranges: []const Range,
    value_count: u8,
) !void {
    const chunk_size = 420;
    const count = (ranges.len + chunk_size - 1) / chunk_size;
    for (0..count) |index| {
        const start = index * chunk_size;
        const end = @min(start + chunk_size, ranges.len);
        const name = try std.fmt.allocPrint(allocator, "{s}_{d}.zig", .{ base, index });
        defer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ out_dir, name });
        defer allocator.free(path);
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("// Generated by tools/unicode/generate.zig; do not edit.\n");
        try file.writeAll("pub const ranges = [_][3]u32{\n");
        var line_buf: [96]u8 = undefined;
        for (ranges[start..end]) |range| {
            const line = try std.fmt.bufPrint(&line_buf, "    .{{ 0x{X}, 0x{X}, {d} }},\n", .{ range.first, range.last, range.value });
            try file.writeAll(line);
        }
        try file.writeAll("};\n");
    }

    const index_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ out_dir, base });
    defer allocator.free(index_path);
    var index_file = try std.fs.cwd().createFile(index_path, .{ .truncate = true });
    defer index_file.close();
    try index_file.writeAll("// Generated by tools/unicode/generate.zig; do not edit.\n");
    var line_buf: [160]u8 = undefined;
    for (0..count) |index| {
        const line = try std.fmt.bufPrint(&line_buf, "const p{d} = @import(\"{s}_{d}.zig\").ranges;\n", .{ index, base, index });
        try index_file.writeAll(line);
    }
    const signature = if (value_count == 1) "pub fn contains(cp: u21) bool {\n" else "pub fn lookup(cp: u21) u8 {\n";
    try index_file.writeAll(signature);
    for (0..count) |index| {
        const line = if (value_count == 1)
            try std.fmt.bufPrint(&line_buf, "    if (find(&p{d}, cp) != 0) return true;\n", .{index})
        else
            try std.fmt.bufPrint(&line_buf, "    if (find(&p{d}, cp)) |value| return value;\n", .{index});
        try index_file.writeAll(line);
    }
    if (value_count == 1) try index_file.writeAll("    return false;\n}\n\n") else try index_file.writeAll("    return 0;\n}\n\n");
    if (value_count == 1) {
        try index_file.writeAll(
            \\fn find(ranges: []const [3]u32, cp: u21) u8 {
            \\    var low: usize = 0;
            \\    var high = ranges.len;
            \\    while (low < high) {
            \\        const mid = low + (high - low) / 2;
            \\        if (cp < ranges[mid][0]) high = mid else if (cp > ranges[mid][1]) low = mid + 1 else return 1;
            \\    }
            \\    return 0;
            \\}
            \\
        );
    } else {
        try index_file.writeAll(
            \\fn find(ranges: []const [3]u32, cp: u21) ?u8 {
            \\    var low: usize = 0;
            \\    var high = ranges.len;
            \\    while (low < high) {
            \\        const mid = low + (high - low) / 2;
            \\        if (cp < ranges[mid][0]) high = mid else if (cp > ranges[mid][1]) low = mid + 1 else return @intCast(ranges[mid][2]);
            \\    }
            \\    return null;
            \\}
            \\
        );
    }
}

fn writeSequenceModules(allocator: std.mem.Allocator, out_dir: []const u8, sequences: [][]const u21) !void {
    std.mem.sort([]const u21, sequences, {}, lessSequence);
    const chunk_size = 360;
    const count = (sequences.len + chunk_size - 1) / chunk_size;
    for (0..count) |index| {
        const start = index * chunk_size;
        const end = @min(start + chunk_size, sequences.len);
        const path = try std.fmt.allocPrint(allocator, "{s}/rgi_{d}.zig", .{ out_dir, index });
        defer allocator.free(path);
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("// Generated by tools/unicode/generate.zig; do not edit.\n");
        try file.writeAll("pub const sequences = [_][]const u21{\n");
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        for (sequences[start..end]) |seq| {
            line.clearRetainingCapacity();
            try line.appendSlice(allocator, "    &.{ ");
            for (seq, 0..) |cp, cp_index| {
                if (cp_index != 0) try line.appendSlice(allocator, ", ");
                try line.writer(allocator).print("0x{X}", .{cp});
            }
            try line.appendSlice(allocator, " },\n");
            try file.writeAll(line.items);
        }
        try file.writeAll("};\n");
    }

    const path = try std.fs.path.join(allocator, &.{ out_dir, "rgi.zig" });
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("// Generated by tools/unicode/generate.zig; do not edit.\n");
    var buf: [128]u8 = undefined;
    for (0..count) |index| {
        const line = try std.fmt.bufPrint(&buf, "const p{d} = @import(\"rgi_{d}.zig\").sequences;\n", .{ index, index });
        try file.writeAll(line);
    }
    var max_sequence_len: usize = 0;
    for (sequences) |sequence| max_sequence_len = @max(max_sequence_len, sequence.len);
    const max_line = try std.fmt.bufPrint(&buf, "pub const max_sequence_len = {d};\n", .{max_sequence_len});
    try file.writeAll(max_line);
    try file.writeAll("pub fn contains(cps: []const u21) bool {\n");
    for (0..count) |index| {
        const line = try std.fmt.bufPrint(&buf, "    if (find(&p{d}, cps)) return true;\n", .{index});
        try file.writeAll(line);
    }
    try file.writeAll(
        \\    return false;
        \\}
        \\
        \\fn find(sequences: []const []const u21, cps: []const u21) bool {
        \\    var low: usize = 0;
        \\    var high = sequences.len;
        \\    while (low < high) {
        \\        const mid = low + (high - low) / 2;
        \\        switch (compare(sequences[mid], cps)) {
        \\            .lt => low = mid + 1,
        \\            .gt => high = mid,
        \\            .eq => return true,
        \\        }
        \\    }
        \\    return false;
        \\}
        \\
        \\fn compare(a: []const u21, b: []const u21) std.math.Order {
        \\    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        \\        if (x < y) return .lt;
        \\        if (x > y) return .gt;
        \\    }
        \\    return std.math.order(a.len, b.len);
        \\}
        \\
        \\const std = @import("std");
        \\
    );
}

fn lessSequence(_: void, a: []const u21, b: []const u21) bool {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        if (x != y) return x < y;
    }
    return a.len < b.len;
}

fn lessRange(_: void, a: Range, b: Range) bool {
    return a.first < b.first;
}

fn writeManifest(allocator: std.mem.Allocator, out_dir: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ out_dir, "manifest.zig" });
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("// Generated by tools/unicode/generate.zig; do not edit.\n");
    var buf: [512]u8 = undefined;
    const version_line = try std.fmt.bufPrint(&buf, "pub const unicode_version = \"{s}\";\n", .{unicode_version});
    try file.writeAll(version_line);
    try file.writeAll("pub const license = \"Unicode License v3\";\n");
    try file.writeAll("pub const sources = [_]Source{\n");
    for (sources) |source| {
        const line = try std.fmt.bufPrint(&buf, "    .{{ .name = \"{s}\", .url = \"{s}\", .sha256 = \"{s}\" }},\n", .{ source.name, source.url, source.sha256 });
        try file.writeAll(line);
    }
    try file.writeAll("};\npub const Source = struct { name: []const u8, url: []const u8, sha256: []const u8 };\n");
}
