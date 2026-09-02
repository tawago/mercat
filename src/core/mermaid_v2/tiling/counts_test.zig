//! Unit tests for `tiling/counts.zig`: the prefix contract, the defect
//! total, and the reflection-driven line writer.

const std = @import("std");
const counts = @import("counts.zig");

const testing = std.testing;
const fields = @typeInfo(counts.Counts).@"struct".fields;

test "counts: every field carries an n_/m_/c_/d_/u_ prefix" {
    inline for (fields) |f| {
        var matched: usize = 0;
        for (counts.prefixes) |p| {
            if (std.mem.startsWith(u8, f.name, p)) matched += 1;
        }
        if (matched != 1) {
            std.debug.print("field '{s}' matches {d} prefixes, want exactly 1\n", .{ f.name, matched });
            return error.PrefixContractViolated;
        }
        try testing.expectEqual(u32, f.type);
        try testing.expect(f.default_value_ptr != null);
    }
}

test "counts: defectTotal sums exactly the d_ fields" {
    var c: counts.Counts = .{};
    var expected: u32 = 0;
    var next: u32 = 1;
    inline for (fields) |f| {
        @field(c, f.name) = next;
        if (comptime std.mem.startsWith(u8, f.name, "d_")) expected += next;
        next += 1;
    }
    try testing.expectEqual(expected, c.defectTotal());

    const before = c.defectTotal();
    c.c_arrow_lat_frame += 1000;
    c.m_wide_label_cells += 1000;
    c.u_audit_oom += 1000;
    c.n_cells += 1000;
    try testing.expectEqual(before, c.defectTotal());

    c.d_arrow_lat_orphan += 7;
    try testing.expectEqual(before + 7, c.defectTotal());
}

test "counts: a zero record has zero defects" {
    const c: counts.Counts = .{};
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "counts: bundle audit counters add no defect claims" {
    var c: counts.Counts = .{};
    c.u_bundle_identity_disagreed = 3;
    c.u_bundle_detail_disagreed = 5;
    c.u_bundle_detail_invalid = 7;
    c.u_bundle_stamp_rail_invariant = 11;
    c.u_aux_collection_oom = 13;
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "writeLine: one token per field plus d_total, mercat-tiling prefix" {
    var c: counts.Counts = .{};
    var next: u32 = 3;
    inline for (fields) |f| {
        @field(c, f.name) = next;
        next += 2;
    }

    var buf: [counts.line_buf_len]u8 = undefined;
    const line = c.writeLine(&buf);

    try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    try testing.expectEqualStrings(counts.line_prefix, it.next() orelse return error.NoPrefix);

    inline for (fields) |f| {
        const tok = it.next() orelse return error.MissingToken;
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.MalformedToken;
        try testing.expectEqualStrings(f.name, tok[0..eq]);
        try testing.expectEqual(@field(c, f.name), try std.fmt.parseInt(u32, tok[eq + 1 ..], 10));
    }

    const tail = it.next() orelse return error.MissingTotal;
    const teq = std.mem.indexOfScalar(u8, tail, '=') orelse return error.MalformedToken;
    try testing.expectEqualStrings("d_total", tail[0..teq]);
    try testing.expectEqual(c.defectTotal(), try std.fmt.parseInt(u32, tail[teq + 1 ..], 10));

    try testing.expect(it.next() == null);
}

test "writeLine: the whole taxonomy fits the line buffer with room to grow" {
    const worst = comptime blk: {
        var n: usize = counts.line_prefix.len + " d_total=".len + 10;
        for (fields) |f| n += 1 + f.name.len + 1 + 10;
        break :blk n;
    };
    try testing.expect(worst < counts.line_buf_len);
    try testing.expect(worst + 1024 < counts.line_buf_len);
}

test "writeLine: a buffer too small truncates instead of failing" {
    const c: counts.Counts = .{};
    var tiny: [8]u8 = undefined;
    const line = c.writeLine(&tiny);
    try testing.expect(line.len <= tiny.len);
}
