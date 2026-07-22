//! Shape-aware post-processing for node rasterization.
//!
//! `raster/nodes.zig` lays down a rectangular perimeter + interior
//! fill; this pass stamps the shape tag onto every node-owned cell
//! (so the painter picks shape-specific glyphs: rounded corners,
//! parenthesis caps, slash diagonals, …) and renders overlays that
//! can't be expressed via glyph swaps alone (subroutine inner walls).
//!
//! Allowed imports: `std`, sketch types, lattice types — same boundary as `raster/nodes.zig`.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");

// Shape stamping copies the tag straight from sketch into lattice cells with no
// translation table — sound ONLY because sketch.Shape and lattice.Shape are the
// SAME type. If they ever diverge, this stamp needs a remap.
// guarded-by: node_shapes.zig "shape identity: sketch.Shape and lattice.Shape are the same type"

/// Stamp the shape tag on every node_border / node_interior cell
/// inside this node's bounding rect. Cells whose occupant doesn't
/// belong to this node (e.g. clusters, prior edges) are left alone.
pub fn tagShape(lat: *lattice.Lattice, np: sketch.NodePlacement) void {
    if (np.shape == .rect) return; // default is already .rect
    if (!rectFitsLattice(np.rect, lat.*)) return;
    const shape = np.shape; // sketch.Shape == lattice.Shape == prim.Shape
    const x0: u32 = @intCast(np.rect.x);
    const y0: u32 = @intCast(np.rect.y);
    const x_end: u32 = x0 + np.rect.w;
    const y_end: u32 = y0 + np.rect.h;
    var y: u32 = y0;
    while (y < y_end) : (y += 1) {
        var x: u32 = x0;
        while (x < x_end) : (x += 1) {
            const cell = lat.at(x, y);
            switch (cell.occupant) {
                .node_border => |b| if (b.node == np.id) {
                    cell.shape = shape;
                },
                .node_interior => |id| if (id == np.id) {
                    cell.shape = shape;
                },
                else => {},
            }
        }
    }
}

/// Subroutine overlay: render the pair of inner vertical walls
/// `│ … │` two columns in from each side. Only applied when there's
/// enough horizontal slack (rect width ≥ 5) so we don't overwrite
/// the label area. // guarded-by: node_shapes_test.zig "rasterizeSubroutineInner: width 4 draws no inner wall, width 5 does"
/// The corner where the inner wall meets the top
/// or bottom edge becomes a `┬` / `┴` tee (the painter picks that
/// glyph from the standard junction table once we OR the extra
/// south/north bit into the existing edge cell's neighbours).
pub fn rasterizeSubroutineInner(lat: *lattice.Lattice, np: sketch.NodePlacement) void {
    if (np.shape != .subroutine) return;
    if (!rectFitsLattice(np.rect, lat.*)) return;
    if (np.rect.w < 5 or np.rect.h < 3) return;
    const x0: u32 = @intCast(np.rect.x);
    const y0: u32 = @intCast(np.rect.y);
    const x_last: u32 = x0 + np.rect.w - 1;
    const y_last: u32 = y0 + np.rect.h - 1;
    const left_x: u32 = x0 + 1;
    const right_x: u32 = x_last - 1;
    if (right_x <= left_x + 1) return; // no room between walls

    addNeighbourIfBorder(lat, left_x, y0, np.id, .{ .s = true });
    addNeighbourIfBorder(lat, right_x, y0, np.id, .{ .s = true });
    addNeighbourIfBorder(lat, left_x, y_last, np.id, .{ .n = true });
    addNeighbourIfBorder(lat, right_x, y_last, np.id, .{ .n = true });

    var y: u32 = y0 + 1;
    while (y < y_last) : (y += 1) {
        writeInnerWall(lat, left_x, y, np.id, .edge_w);
        writeInnerWall(lat, right_x, y, np.id, .edge_e);
    }
}

fn addNeighbourIfBorder(
    lat: *lattice.Lattice,
    x: u32,
    y: u32,
    node: lattice.NodeId,
    extra: lattice.Neighbours,
) void {
    const cell = lat.at(x, y);
    switch (cell.occupant) {
        .node_border => |b| if (b.node == node) {
            const merged: u4 = cell.neighbours.toMask() | extra.toMask();
            cell.neighbours = lattice.Neighbours.fromMask(merged);
        },
        else => {},
    }
}

fn writeInnerWall(
    lat: *lattice.Lattice,
    x: u32,
    y: u32,
    node: lattice.NodeId,
    role: lattice.BorderRole,
) void {
    const cell = lat.at(x, y);
    switch (cell.occupant) {
        .node_interior => |id| if (id == node) {
            cell.* = .{
                .occupant = .{ .node_border = .{ .node = node, .role = role } },
                .neighbours = .{ .n = true, .s = true },
                .shape = .subroutine,
            };
        },
        else => {},
    }
}

fn rectFitsLattice(r: sketch.Rect, lat: lattice.Lattice) bool {
    if (r.w == 0 or r.h == 0) return false;
    if (r.x < 0 or r.y < 0) return false;
    if (r.right() > @as(i32, @intCast(lat.width))) return false;
    if (r.bottom() > @as(i32, @intCast(lat.height))) return false;
    return true;
}

const testing = std.testing;

test "shape identity: sketch.Shape and lattice.Shape are the same type" {
    const s: sketch.Shape = .rhombus;
    const l: lattice.Shape = s;
    try testing.expectEqual(sketch.Shape.rhombus, l);
}

test {
    _ = @import("node_shapes_test.zig");
}
