const std = @import("std");
const testing = std.testing;
const prim = @import("prim");
const lattice = @import("lattice.zig");
const painter = @import("paint.zig");

const red: prim.Rgb = .{ .r = 0xff, .g = 0, .b = 0 };
const blue: prim.Rgb = .{ .r = 0, .g = 0, .b = 0xff };

fn ink(colour: u8) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid } }, .neighbours = .{ .e = true, .w = true }, .colour = colour };
}

fn label(cp: u21, colour: u8) lattice.Cell {
    return .{ .occupant = .{ .label_char = cp }, .neighbours = .{}, .colour = colour };
}

const space: lattice.Cell = .{ .occupant = .{ .node_interior = 0 }, .neighbours = .{}, .colour = 1 };

fn expectRuns(want: []const prim.ColourRun, got: []const prim.ColourRun) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualDeep(w, g);
}

test "coloured paint returns the plain paint's text and byte runs over multibyte glyphs" {
    const a = testing.allocator;
    var cells = [_]lattice.Cell{ ink(1), ink(1), space, label('x', 2), ink(0), ink(2), label(' ', 1), lattice.Cell.empty };
    const lat: lattice.Lattice = .{ .width = 8, .height = 1, .cells = &cells, .palette = &.{ red, blue } };
    const plain = try painter.paint(a, lat, 0);
    defer a.free(plain);
    const got = try painter.paintColoured(a, lat, 0);
    defer a.free(got.text);
    defer a.free(got.runs);
    try testing.expectEqualStrings(plain, got.text);
    try testing.expectEqualStrings("── x──\n", got.text);
    try expectRuns(&.{
        .{ .start = 0, .len = 6, .rgb = red },
        .{ .start = 7, .len = 1, .rgb = blue },
        .{ .start = 11, .len = 3, .rgb = blue },
    }, got.runs);
}

test "the clip and its marker cut the runs; the marker wears none" {
    const a = testing.allocator;
    var cells = [_]lattice.Cell{ ink(1), ink(1), ink(1), ink(1) };
    const lat: lattice.Lattice = .{ .width = 4, .height = 1, .cells = &cells, .palette = &.{red} };
    const got = try painter.paintColoured(a, lat, 2);
    defer a.free(got.text);
    defer a.free(got.runs);
    try testing.expectEqualStrings("─»\n", got.text);
    try expectRuns(&.{.{ .start = 0, .len = 3, .rgb = red }}, got.runs);
}

test "a lattice with no palette paints no runs" {
    const a = testing.allocator;
    var cells = [_]lattice.Cell{ink(1)};
    const lat: lattice.Lattice = .{ .width = 1, .height = 1, .cells = &cells };
    const got = try painter.paintColoured(a, lat, 0);
    defer a.free(got.text);
    defer a.free(got.runs);
    try testing.expectEqual(@as(usize, 0), got.runs.len);
}

test "rows after the first carry absolute offsets" {
    const a = testing.allocator;
    var cells = [_]lattice.Cell{ ink(0), lattice.Cell.empty, ink(1), lattice.Cell.empty };
    const lat: lattice.Lattice = .{ .width = 2, .height = 2, .cells = &cells, .palette = &.{red} };
    const got = try painter.paintColoured(a, lat, 0);
    defer a.free(got.text);
    defer a.free(got.runs);
    try testing.expectEqualStrings("─\n─\n", got.text);
    try expectRuns(&.{.{ .start = 4, .len = 3, .rgb = red }}, got.runs);
}
