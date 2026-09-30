const std = @import("std");
const prim = @import("prim");
const lattice = @import("../lattice.zig");

/// Indexed by the neighbour mask: n = 1, e = 2, s = 4, w = 8.
const light = [16]u21{ ' ', '╵', '╶', '└', '╷', '│', '┌', '├', '╴', '┘', '─', '┴', '┐', '┤', '┬', '┼' };
const dotted = [16]u21{ ' ', '┊', '╌', '└', '┊', '┊', '┌', '├', '╌', '┘', '╌', '┴', '┐', '┤', '┬', '┼' };
const thick = [16]u21{ ' ', '║', '═', '╚', '║', '║', '╔', '╠', '═', '╝', '═', '╩', '╗', '╣', '╦', '╬' };
/// A border a thick edge ends on: light corners, double where the edge meets it.
const thick_border = [16]u21{ ' ', '╨', '╞', '└', '╥', '║', '┌', '╞', '╡', '┘', '═', '╨', '┐', '╡', '╥', '┼' };

/// Indexed by Dir4: north, east, south, west.
const filled_arrow = [4]u21{ '▲', '▶', '▼', '◀' };
const open_arrow = [4]u21{ '△', '▷', '▽', '◁' };

/// What a shape draws on its border in place of the light line; null leaves the light glyph.
const Outline = struct {
    /// nw, ne, se, sw: the order of the corner roles.
    corners: [4]?u21 = .{null} ** 4,
    west: ?u21 = null,
    east: ?u21 = null,
    /// The top and bottom are double lines; an arm meeting one turns it into a tee.
    lids: bool = false,
};

const rounded = [4]?u21{ '╭', '╮', '╯', '╰' };
const slashed = [4]?u21{ '╱', '╲', '╱', '╲' };

const outlines = std.EnumArray(lattice.Shape, Outline).init(.{
    .rect = .{},
    .subroutine = .{},
    .round = .{ .corners = rounded },
    .stadium = .{ .corners = rounded, .west = '(', .east = ')' },
    .cylinder = .{ .corners = rounded, .lids = true },
    .circle = .{ .corners = slashed },
    .asymmetric_left = .{ .corners = .{ '<', null, null, '<' }, .west = '<' },
    .asymmetric_right = .{ .corners = .{ null, '>', '>', null }, .east = '>' },
    .rhombus = .{ .corners = .{'◇'} ** 4 },
    .hexagon = .{ .corners = slashed, .west = '<', .east = '>' },
    .parallelogram = .{ .corners = .{'╱'} ** 4 },
    .trapezoid = .{ .corners = .{ '/', '\\', '\\', '/' } },
});

comptime {
    const corner_roles = [_]lattice.BorderRole{ .corner_nw, .corner_ne, .corner_se, .corner_sw };
    for (corner_roles, 0..) |role, i| std.debug.assert(@intFromEnum(role) == i);
}

/// The glyph of an ink cell, or null where the cell is blank or carries text.
pub fn ink(cell: lattice.Cell) ?u21 {
    const mask = cell.neighbours.toMask();
    return switch (cell.occupant) {
        .edge_segment => |seg| switch (seg.kind) {
            .solid => light[mask],
            .dotted => dotted[mask],
            .thick => thick[mask],
            .invisible => ' ',
        },
        .arrowhead => |a| arrowhead(a.arrow, a.dir),
        .node_border => |b| switch (cell.stroke_kind) {
            .solid, .invisible => shaped(cell.shape, b.role, cell.neighbours),
            .dotted => light[mask],
            .thick => thick_border[mask],
        },
        .cluster_border => switch (cell.stroke_kind) {
            .solid, .dotted, .invisible => light[mask],
            .thick => thick_border[mask],
        },
        .empty, .node_interior, .label_char, .label_cont => null,
    };
}

fn arrowhead(kind: lattice.ArrowKind, dir: lattice.Dir4) u21 {
    const row: [4]u21 = switch (kind) {
        .none => unreachable,
        .filled => filled_arrow,
        .open => open_arrow,
        .circle => .{'○'} ** 4,
        .cross => .{'\u{2715}'} ** 4,
    };
    return row[@intFromEnum(dir)];
}

fn shaped(shape: lattice.Shape, role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    const outline = outlines.get(shape);
    const own: ?u21 = switch (role) {
        .corner_nw, .corner_ne, .corner_se, .corner_sw => outline.corners[@intFromEnum(role)],
        .edge_w => outline.west,
        .edge_e => outline.east,
        .edge_n, .edge_s => if (outline.lids) lid(role, n) else null,
    };
    return own orelse light[n.toMask()];
}

fn lid(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    return switch (role) {
        .edge_n => if (n.s) '╤' else if (n.n) '╧' else '═',
        else => if (n.n) '╧' else if (n.s) '╤' else '═',
    };
}

const testing = std.testing;

const ink_occupants = [_]lattice.Occupant{
    .{ .edge_segment = .{ .edge = 0, .kind = .solid } },
    .{ .edge_segment = .{ .edge = 0, .kind = .dotted } },
    .{ .edge_segment = .{ .edge = 0, .kind = .thick } },
    .{ .edge_segment = .{ .edge = 0, .kind = .invisible } },
    .{ .arrowhead = .{ .dir = .north, .edge = 0, .arrow = .filled } },
    .{ .arrowhead = .{ .dir = .east, .edge = 0, .arrow = .open } },
    .{ .arrowhead = .{ .dir = .south, .edge = 0, .arrow = .circle } },
    .{ .arrowhead = .{ .dir = .west, .edge = 0, .arrow = .cross } },
    .{ .node_border = .{ .node = 0, .role = .corner_nw } },
    .{ .node_border = .{ .node = 0, .role = .corner_ne } },
    .{ .node_border = .{ .node = 0, .role = .corner_se } },
    .{ .node_border = .{ .node = 0, .role = .corner_sw } },
    .{ .node_border = .{ .node = 0, .role = .edge_n } },
    .{ .node_border = .{ .node = 0, .role = .edge_e } },
    .{ .node_border = .{ .node = 0, .role = .edge_s } },
    .{ .node_border = .{ .node = 0, .role = .edge_w } },
    .{ .cluster_border = .{ .cluster = 0, .role = .corner_nw } },
    .{ .cluster_border = .{ .cluster = 0, .role = .edge_n } },
};

fn cellOf(occupant: lattice.Occupant, mask: u4, stroke: lattice.EdgeKind, shape: lattice.Shape) lattice.Cell {
    return .{ .occupant = occupant, .neighbours = lattice.Neighbours.fromMask(mask), .stroke_kind = stroke, .shape = shape };
}

fn borderOf(shape: lattice.Shape, role: lattice.BorderRole, mask: u4, stroke: lattice.EdgeKind) u21 {
    return ink(cellOf(.{ .node_border = .{ .node = 0, .role = role } }, mask, stroke, shape)).?;
}

fn lineOf(kind: lattice.EdgeKind, mask: u4) u21 {
    return ink(cellOf(.{ .edge_segment = .{ .edge = 0, .kind = kind } }, mask, .solid, .rect)).?;
}

fn nb(n: lattice.Neighbours) u4 {
    return n.toMask();
}

test "every ink glyph is one column wide and none is a tofu cross" {
    for (ink_occupants) |occupant| for (std.enums.values(lattice.Shape)) |shape| for (std.enums.values(lattice.EdgeKind)) |stroke| {
        var mask: u5 = 0;
        while (mask < 16) : (mask += 1) {
            const g = ink(cellOf(occupant, @intCast(mask), stroke, shape)).?;
            var buf: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(g, &buf);
            try testing.expectEqual(@as(usize, 1), prim.displayWidth(buf[0..len]));
            try testing.expect(g != 0x2716 and g != 0x2A2F);
        }
    };
}

test "blank and text cells have no ink" {
    const occupants = [_]lattice.Occupant{ .empty, .{ .node_interior = 3 }, .{ .label_char = 'a' }, .label_cont };
    for (occupants) |occupant| {
        try testing.expectEqual(@as(?u21, null), ink(cellOf(occupant, 15, .thick, .circle)));
    }
}

test "an edge stroke spells every arm mask by its kind" {
    const solid = [16]u21{ ' ', '╵', '╶', '└', '╷', '│', '┌', '├', '╴', '┘', '─', '┴', '┐', '┤', '┬', '┼' };
    for (solid, 0..) |want, mask| try testing.expectEqual(want, lineOf(.solid, @intCast(mask)));
    try testing.expectEqual(@as(u21, '┊'), lineOf(.dotted, nb(.{ .n = true, .s = true })));
    try testing.expectEqual(@as(u21, '╌'), lineOf(.dotted, nb(.{ .e = true, .w = true })));
    try testing.expectEqual(@as(u21, '┌'), lineOf(.dotted, nb(.{ .e = true, .s = true })));
    try testing.expectEqual(@as(u21, ' '), lineOf(.dotted, 0));
    try testing.expectEqual(@as(u21, '║'), lineOf(.thick, nb(.{ .n = true, .s = true })));
    try testing.expectEqual(@as(u21, '═'), lineOf(.thick, nb(.{ .e = true, .w = true })));
    try testing.expectEqual(@as(u21, '╔'), lineOf(.thick, nb(.{ .e = true, .s = true })));
    try testing.expectEqual(@as(u21, '╬'), lineOf(.thick, 15));
}

test "an invisible edge segment is blank whatever its arms" {
    var mask: u5 = 0;
    while (mask < 16) : (mask += 1) try testing.expectEqual(@as(u21, ' '), lineOf(.invisible, @intCast(mask)));
}

test "an edge segment follows its own kind, not the cell's stroke" {
    const cell = cellOf(.{ .edge_segment = .{ .edge = 0, .kind = .solid } }, nb(.{ .n = true, .s = true }), .thick, .rect);
    try testing.expectEqual(@as(?u21, '│'), ink(cell));
}

test "arrowheads: every drawable kind in every direction" {
    const cases = [_]struct { kind: lattice.ArrowKind, want: [4]u21 }{
        .{ .kind = .filled, .want = .{ '▲', '▶', '▼', '◀' } },
        .{ .kind = .open, .want = .{ '△', '▷', '▽', '◁' } },
        .{ .kind = .circle, .want = .{ '○', '○', '○', '○' } },
        .{ .kind = .cross, .want = .{ '\u{2715}', '\u{2715}', '\u{2715}', '\u{2715}' } },
    };
    for (cases) |c| for (std.enums.values(lattice.Dir4), 0..) |dir, i| {
        const cell = cellOf(.{ .arrowhead = .{ .dir = dir, .edge = 0, .arrow = c.kind } }, 0, .solid, .rect);
        try testing.expectEqual(@as(?u21, c.want[i]), ink(cell));
    };
}

test "a thick or dotted stroke on a border replaces the shape glyph" {
    const corner = nb(.{ .e = true, .s = true });
    try testing.expectEqual(@as(u21, '┌'), borderOf(.round, .corner_nw, corner, .thick));
    try testing.expectEqual(@as(u21, '┌'), borderOf(.rhombus, .corner_nw, corner, .dotted));
    try testing.expectEqual(@as(u21, '┬'), borderOf(.cylinder, .edge_n, nb(.{ .e = true, .w = true, .s = true }), .dotted));
    try testing.expectEqual(@as(u21, '╥'), borderOf(.rect, .edge_s, nb(.{ .e = true, .w = true, .s = true }), .thick));
    try testing.expectEqual(@as(u21, '╨'), borderOf(.rect, .edge_n, nb(.{ .e = true, .w = true, .n = true }), .thick));
    try testing.expectEqual(@as(u21, '╞'), borderOf(.rect, .edge_w, nb(.{ .e = true }), .thick));
    try testing.expectEqual(@as(u21, '│'), borderOf(.round, .edge_w, nb(.{ .n = true, .s = true }), .dotted));
}

test "an invisible stroke on a node border keeps the shape glyph" {
    try testing.expectEqual(@as(u21, '╭'), borderOf(.round, .corner_nw, nb(.{ .e = true, .s = true }), .invisible));
}

test "a cluster border is the light line, or the thick border tees when thick" {
    const ews = nb(.{ .e = true, .w = true, .s = true });
    for ([_]lattice.EdgeKind{ .solid, .dotted, .invisible }) |stroke| {
        const cell = cellOf(.{ .cluster_border = .{ .cluster = 0, .role = .edge_n } }, ews, stroke, .circle);
        try testing.expectEqual(@as(?u21, '┬'), ink(cell));
    }
    const thick_cell = cellOf(.{ .cluster_border = .{ .cluster = 0, .role = .edge_n } }, ews, .thick, .circle);
    try testing.expectEqual(@as(?u21, '╥'), ink(thick_cell));
}

test "shape outlines: rect, subroutine and plain edges stay light" {
    const es = nb(.{ .e = true, .s = true });
    const ns = nb(.{ .n = true, .s = true });
    const ew = nb(.{ .e = true, .w = true });
    try testing.expectEqual(@as(u21, '┌'), borderOf(.rect, .corner_nw, es, .solid));
    try testing.expectEqual(@as(u21, '─'), borderOf(.rect, .edge_n, ew, .solid));
    try testing.expectEqual(@as(u21, '┌'), borderOf(.subroutine, .corner_nw, es, .solid));
    try testing.expectEqual(@as(u21, '│'), borderOf(.round, .edge_w, ns, .solid));
    try testing.expectEqual(@as(u21, '─'), borderOf(.circle, .edge_n, ew, .solid));
}

test "shape outlines: rounded, stadium, circle, rhombus, parallelogram, trapezoid corners" {
    const roles = [_]lattice.BorderRole{ .corner_nw, .corner_ne, .corner_se, .corner_sw };
    const cases = [_]struct { shape: lattice.Shape, want: [4]u21 }{
        .{ .shape = .round, .want = .{ '╭', '╮', '╯', '╰' } },
        .{ .shape = .stadium, .want = .{ '╭', '╮', '╯', '╰' } },
        .{ .shape = .cylinder, .want = .{ '╭', '╮', '╯', '╰' } },
        .{ .shape = .circle, .want = .{ '╱', '╲', '╱', '╲' } },
        .{ .shape = .hexagon, .want = .{ '╱', '╲', '╱', '╲' } },
        .{ .shape = .rhombus, .want = .{ '◇', '◇', '◇', '◇' } },
        .{ .shape = .parallelogram, .want = .{ '╱', '╱', '╱', '╱' } },
        .{ .shape = .trapezoid, .want = .{ '/', '\\', '\\', '/' } },
        .{ .shape = .asymmetric_left, .want = .{ '<', '┐', '┘', '<' } },
        .{ .shape = .asymmetric_right, .want = .{ '┌', '>', '>', '└' } },
    };
    const arms = [4]u4{ nb(.{ .e = true, .s = true }), nb(.{ .w = true, .s = true }), nb(.{ .w = true, .n = true }), nb(.{ .e = true, .n = true }) };
    for (cases) |c| for (roles, 0..) |role, i| {
        try testing.expectEqual(c.want[i], borderOf(c.shape, role, arms[i], .solid));
    };
}

test "shape outlines: side caps" {
    const ns = nb(.{ .n = true, .s = true });
    try testing.expectEqual(@as(u21, '('), borderOf(.stadium, .edge_w, ns, .solid));
    try testing.expectEqual(@as(u21, ')'), borderOf(.stadium, .edge_e, ns, .solid));
    try testing.expectEqual(@as(u21, '<'), borderOf(.hexagon, .edge_w, ns, .solid));
    try testing.expectEqual(@as(u21, '>'), borderOf(.hexagon, .edge_e, ns, .solid));
    try testing.expectEqual(@as(u21, '<'), borderOf(.asymmetric_left, .edge_w, ns, .solid));
    try testing.expectEqual(@as(u21, '│'), borderOf(.asymmetric_left, .edge_e, ns, .solid));
    try testing.expectEqual(@as(u21, '>'), borderOf(.asymmetric_right, .edge_e, ns, .solid));
    try testing.expectEqual(@as(u21, '│'), borderOf(.asymmetric_right, .edge_w, ns, .solid));
}

test "a cylinder's lid and base are double lines that tee where an arm meets them" {
    const ew = nb(.{ .e = true, .w = true });
    const ews = nb(.{ .e = true, .w = true, .s = true });
    const ewn = nb(.{ .e = true, .w = true, .n = true });
    const all = nb(.{ .n = true, .e = true, .s = true, .w = true });
    try testing.expectEqual(@as(u21, '═'), borderOf(.cylinder, .edge_n, ew, .solid));
    try testing.expectEqual(@as(u21, '═'), borderOf(.cylinder, .edge_s, ew, .solid));
    try testing.expectEqual(@as(u21, '╤'), borderOf(.cylinder, .edge_n, ews, .solid));
    try testing.expectEqual(@as(u21, '╧'), borderOf(.cylinder, .edge_n, ewn, .solid));
    try testing.expectEqual(@as(u21, '╧'), borderOf(.cylinder, .edge_s, ewn, .solid));
    try testing.expectEqual(@as(u21, '╤'), borderOf(.cylinder, .edge_s, ews, .solid));
    try testing.expectEqual(@as(u21, '╤'), borderOf(.cylinder, .edge_n, all, .solid));
    try testing.expectEqual(@as(u21, '╧'), borderOf(.cylinder, .edge_s, all, .solid));
}
