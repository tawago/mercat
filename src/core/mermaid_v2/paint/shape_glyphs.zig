//! Per-shape glyph selection for node-border cells. Rect boxes use the
//! base `junction_table` (`┌─┐│└┘` + tee/cross); non-rect shapes
//! (round, stadium, subroutine, cylinder, circle, asymmetric, rhombus,
//! hexagon, parallelogram, trapezoid) override a handful of perimeter
//! cells with shape-specific glyphs.
//!
//! Dispatch uses `BorderRole` (corner/edge) + `Neighbours` mask, since
//! same-mask cells can need distinct glyphs (e.g. stadium `(` vs `)`);
//! unoverridden roles fall through to `jt.glyphFor`. Imports only
//! `std`, `lattice.zig`, `junction_glyphs.zig`.

const std = @import("std");
const lattice = @import("../lattice.zig");
const jt = @import("junction_glyphs.zig");

/// Pick the glyph for a node-border cell with the given shape, role,
/// and neighbour mask. Falls back to `jt.glyphFor` when the shape
/// doesn't override that particular role.
pub fn glyphFor(
    shape: lattice.Shape,
    role: lattice.BorderRole,
    neighbours: lattice.Neighbours,
) u21 {
    return switch (shape) {
        .rect => jt.glyphFor(neighbours),
        .round => roundGlyph(role, neighbours),
        .stadium => stadiumGlyph(role, neighbours),
        .subroutine => subroutineGlyph(role, neighbours),
        .cylinder => cylinderGlyph(role, neighbours),
        .circle => circleGlyph(role, neighbours),
        .asymmetric_left => asymLeftGlyph(role, neighbours),
        .asymmetric_right => asymRightGlyph(role, neighbours),
        .rhombus => rhombusGlyph(role, neighbours),
        .hexagon => hexagonGlyph(role, neighbours),
        .parallelogram => parallelogramGlyph(role, neighbours),
        .trapezoid => trapezoidGlyph(role, neighbours),
    };
}

fn roundGlyph(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    return switch (role) {
        .corner_nw => '╭',
        .corner_ne => '╮',
        .corner_se => '╯',
        .corner_sw => '╰',
        else => jt.glyphFor(n),
    };
}

fn stadiumGlyph(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    return switch (role) {
        .corner_nw => '╭',
        .corner_ne => '╮',
        .corner_se => '╯',
        .corner_sw => '╰',
        .edge_w => '(',
        .edge_e => ')',
        else => jt.glyphFor(n),
    };
}

// The inner "double wall" cells are emitted by the rasterizer as
// separate node_border cells with synthesized neighbour masks; from
// the painter's perspective they're standard junction cells, so the
// outer perimeter here can stay rect-like.

fn subroutineGlyph(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    _ = role;
    return jt.glyphFor(n);
}

fn cylinderGlyph(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    return switch (role) {
        .corner_nw => '╭',
        .corner_ne => '╮',
        .corner_se => '╯',
        .corner_sw => '╰',
        // Top/bottom rail is double-line `═`; edges attaching N/S get
        // the hybrid tee. guarded-by: shape_glyphs.zig "cylinder: top/bottom edges use double rail; tees use ╤/╧"
        .edge_n => if (n.s) '╤' else '═',
        .edge_s => if (n.n) '╧' else '═',
        else => jt.glyphFor(n),
    };
}

fn circleGlyph(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    return switch (role) {
        .corner_nw => '╱',
        .corner_ne => '╲',
        .corner_se => '╱',
        .corner_sw => '╲',
        else => jt.glyphFor(n),
    };
}

// Mermaid distinguishes `>` and `<` asymmetric variants. We map
// `asymmetric_right` to the `> ... >` form (east side is open) and
// `asymmetric_left` to the mirrored `< ... <` form.

fn asymRightGlyph(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    return switch (role) {
        .corner_ne => '>',
        .corner_se => '>',
        .edge_e => '>',
        else => jt.glyphFor(n),
    };
}

fn asymLeftGlyph(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    return switch (role) {
        .corner_nw => '<',
        .corner_sw => '<',
        .edge_w => '<',
        else => jt.glyphFor(n),
    };
}

fn rhombusGlyph(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    return switch (role) {
        // `◇` is intentional: slash corners visually conflict with circle,
        // hexagon, and other slanted-corner shapes.
        .corner_nw, .corner_ne, .corner_se, .corner_sw => '◇',
        else => jt.glyphFor(n),
    };
}

fn hexagonGlyph(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    return switch (role) {
        .corner_nw => '╱',
        .corner_ne => '╲',
        .corner_se => '╱',
        .corner_sw => '╲',
        .edge_w => '<',
        .edge_e => '>',
        else => jt.glyphFor(n),
    };
}

fn parallelogramGlyph(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    return switch (role) {
        .corner_nw, .corner_ne, .corner_se, .corner_sw => '╱',
        else => jt.glyphFor(n),
    };
}

fn trapezoidGlyph(role: lattice.BorderRole, n: lattice.Neighbours) u21 {
    return switch (role) {
        .corner_nw => '/',
        .corner_ne => '\\',
        .corner_se => '\\',
        .corner_sw => '/',
        else => jt.glyphFor(n),
    };
}

const testing = std.testing;

test "round: corners override, edges fall through" {
    const es = lattice.Neighbours{ .e = true, .s = true };
    const ns = lattice.Neighbours{ .n = true, .s = true };
    try testing.expectEqual(@as(u21, '╭'), glyphFor(.round, .corner_nw, es));
    try testing.expectEqual(@as(u21, '╮'), glyphFor(.round, .corner_ne, .{ .w = true, .s = true }));
    try testing.expectEqual(@as(u21, '╰'), glyphFor(.round, .corner_sw, .{ .e = true, .n = true }));
    try testing.expectEqual(@as(u21, '╯'), glyphFor(.round, .corner_se, .{ .w = true, .n = true }));
    try testing.expectEqual(@as(u21, '│'), glyphFor(.round, .edge_w, ns));
}

test "stadium: west edge is ( and east edge is )" {
    const ns = lattice.Neighbours{ .n = true, .s = true };
    try testing.expectEqual(@as(u21, '('), glyphFor(.stadium, .edge_w, ns));
    try testing.expectEqual(@as(u21, ')'), glyphFor(.stadium, .edge_e, ns));
    try testing.expectEqual(@as(u21, '╭'), glyphFor(.stadium, .corner_nw, .{ .e = true, .s = true }));
}

test "cylinder: top/bottom edges use double rail; tees use ╤/╧" {
    const ew = lattice.Neighbours{ .e = true, .w = true };
    const ews = lattice.Neighbours{ .e = true, .w = true, .s = true };
    const ewn = lattice.Neighbours{ .e = true, .w = true, .n = true };
    try testing.expectEqual(@as(u21, '═'), glyphFor(.cylinder, .edge_n, ew));
    try testing.expectEqual(@as(u21, '╤'), glyphFor(.cylinder, .edge_n, ews));
    try testing.expectEqual(@as(u21, '═'), glyphFor(.cylinder, .edge_s, ew));
    try testing.expectEqual(@as(u21, '╧'), glyphFor(.cylinder, .edge_s, ewn));
}

test "circle: diagonal slash corners" {
    try testing.expectEqual(@as(u21, '╱'), glyphFor(.circle, .corner_nw, .{ .e = true, .s = true }));
    try testing.expectEqual(@as(u21, '╲'), glyphFor(.circle, .corner_ne, .{ .w = true, .s = true }));
}

test "rhombus: diamond glyph corners" {
    try testing.expectEqual(@as(u21, '◇'), glyphFor(.rhombus, .corner_nw, .{ .e = true, .s = true }));
    try testing.expectEqual(@as(u21, '◇'), glyphFor(.rhombus, .corner_ne, .{ .w = true, .s = true }));
    try testing.expectEqual(@as(u21, '◇'), glyphFor(.rhombus, .corner_se, .{ .w = true, .n = true }));
    try testing.expectEqual(@as(u21, '◇'), glyphFor(.rhombus, .corner_sw, .{ .e = true, .n = true }));
}

test "hexagon: slash corners + < > end caps" {
    try testing.expectEqual(@as(u21, '╱'), glyphFor(.hexagon, .corner_nw, .{ .e = true, .s = true }));
    try testing.expectEqual(@as(u21, '<'), glyphFor(.hexagon, .edge_w, .{ .n = true, .s = true }));
    try testing.expectEqual(@as(u21, '>'), glyphFor(.hexagon, .edge_e, .{ .n = true, .s = true }));
}

test "parallelogram: forward slash everywhere on corners" {
    try testing.expectEqual(@as(u21, '╱'), glyphFor(.parallelogram, .corner_nw, .{ .e = true, .s = true }));
    try testing.expectEqual(@as(u21, '╱'), glyphFor(.parallelogram, .corner_ne, .{ .w = true, .s = true }));
}

test "trapezoid: / and \\ corners" {
    try testing.expectEqual(@as(u21, '/'), glyphFor(.trapezoid, .corner_nw, .{ .e = true, .s = true }));
    try testing.expectEqual(@as(u21, '\\'), glyphFor(.trapezoid, .corner_ne, .{ .w = true, .s = true }));
    try testing.expectEqual(@as(u21, '/'), glyphFor(.trapezoid, .corner_sw, .{ .e = true, .n = true }));
    try testing.expectEqual(@as(u21, '\\'), glyphFor(.trapezoid, .corner_se, .{ .w = true, .n = true }));
}

test "rect: pass-through to junction table" {
    try testing.expectEqual(@as(u21, '┌'), glyphFor(.rect, .corner_nw, .{ .e = true, .s = true }));
    try testing.expectEqual(@as(u21, '─'), glyphFor(.rect, .edge_n, .{ .e = true, .w = true }));
}

test "asymmetric_right: > on east; left side stays rect" {
    try testing.expectEqual(@as(u21, '>'), glyphFor(.asymmetric_right, .corner_ne, .{ .w = true, .s = true }));
    try testing.expectEqual(@as(u21, '>'), glyphFor(.asymmetric_right, .edge_e, .{ .n = true, .s = true }));
    try testing.expectEqual(@as(u21, '┌'), glyphFor(.asymmetric_right, .corner_nw, .{ .e = true, .s = true }));
}
