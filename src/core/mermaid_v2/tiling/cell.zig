//! Lattice cell vocabulary for the report-only structural audit.
//!
//! `classify` is a TOTAL pure function from a `lattice.Cell` to a `Typed`
//! view of it, and `View` wraps a `*const Lattice`: there is no
//! materialized parallel grid, no allocation, and no second source of
//! truth about what a cell is.
//!
//! `Typed.ink` is the ONE place the invisible-edge exclusion lives: an
//! `edge_segment` of kind `.invisible` occupies its cell and paints a
//! blank, so it is `ghost` with `ink == 0` and enters no ink law.
//! NOTE: `classify` deliberately does NOT mirror `paint.rowHasContentFrom`
//! — that predicate answers "is this row worth a clip marker", and an
//! invisible-stroked node_border still paints a glyph. Ring cells are
//! always ink.
//!
//! Mirrored predicates (`isReal`, `gapReprieve`, `ringAxes`,
//! `intoArrowBit`) are duplicated here because the lint zone denies
//! `raster/`; drift is pinned from `tiling_crosscheck_test.zig`, which
//! has raster-zone privileges.
//!
//! Imports: `std`, `prim`, `lattice.zig`, tiling siblings.

const std = @import("std");
const prim = @import("prim");
const lattice = @import("../lattice.zig");

/// Cardinal direction, shared with the lattice.
pub const Dir4 = prim.Dir4;

/// What a cell IS, for the purposes of an ink law. One variant per
/// structural role; `classify` maps every `Occupant` onto exactly one.
pub const Kind = enum {
    /// `.empty` — background.
    blank,
    /// `.node_interior` — paints a space; real per reconcile, not ink.
    fill,
    /// `.label_char` — opaque text; conducts nothing.
    glyph,
    /// `.edge_segment` with a visible stroke kind.
    stroke,
    /// `.edge_segment` of kind `.invisible`: occupies, paints blank,
    /// carries zero ink.
    ghost,
    /// `.arrowhead` — the glyph comes from the tip direction; the mask is
    /// metadata the painter ignores.
    arrow,
    /// `.node_border` — ink regardless of `stroke_kind` (the painter
    /// draws a glyph either way).
    ring_node,
    /// `.cluster_border` — the subgraph frame.
    ring_frame,
};

/// A read-only typed copy of one cell. Copies only: no `*Cell` ever
/// escapes the audit, which is what makes mutation unreachable in
/// practice (`Lattice.at` takes `self` by value, so a `*const Lattice`
/// alone would NOT make a write a compile error).
pub const Typed = struct {
    kind: Kind,
    /// Committed neighbour bits, verbatim.
    mask: u4 = 0,
    /// `mask` for stroke/arrow/ring_*; 0 for blank/fill/glyph/ghost.
    ink: u4 = 0,
    edge: ?prim.EdgeId = null,
    node: ?prim.NodeId = null,
    cluster: ?prim.ClusterId = null,
    role: ?lattice.BorderRole = null,
    edge_role: ?prim.EdgeRole = null,
    tip: ?Dir4 = null,
};

/// Total classification of a lattice cell.
/// guarded-by: cell_test.zig "classify: invisible edge_segment is ghost with zero ink"
pub fn classify(c: lattice.Cell) Typed {
    const mask = c.neighbours.toMask();
    return switch (c.occupant) {
        .empty => .{ .kind = .blank, .mask = mask },
        .node_interior => |id| .{ .kind = .fill, .mask = mask, .node = id },
        .label_char => .{ .kind = .glyph, .mask = mask },
        .edge_segment => |seg| if (seg.kind == .invisible) .{
            .kind = .ghost,
            .mask = mask,
            .edge = seg.edge,
            .edge_role = seg.role,
        } else .{
            .kind = .stroke,
            .mask = mask,
            .ink = mask,
            .edge = seg.edge,
            .edge_role = seg.role,
        },
        .arrowhead => |a| .{ .kind = .arrow, .mask = mask, .ink = mask, .edge = a.edge, .tip = a.dir },
        .node_border => |b| .{ .kind = .ring_node, .mask = mask, .ink = mask, .node = b.node, .role = b.role },
        .cluster_border => |b| .{ .kind = .ring_frame, .mask = mask, .ink = mask, .cluster = b.cluster, .role = b.role },
    };
}

/// Mirror of `raster/reconcile.isRealConnection`: everything except
/// background is a real connection — no reciprocity required, which is
/// the frame-solid convention. The against-the-original mirror pin waits
/// on that function's `pub` promotion; until then this is pinned by the
/// classification table.
/// guarded-by: cell_test.zig "classify: every occupant maps to one kind and only ink kinds carry ink"
pub fn isReal(t: Typed) bool {
    return t.kind != .blank;
}

/// The single neighbour bit for `d` (N=0, E=1, S=2, W=3).
pub fn bit(d: Dir4) u4 {
    return switch (d) {
        .north => 0b0001,
        .east => 0b0010,
        .south => 0b0100,
        .west => 0b1000,
    };
}

/// Opposite direction.
pub fn reverse(d: Dir4) Dir4 {
    return switch (d) {
        .north => .south,
        .east => .west,
        .south => .north,
        .west => .east,
    };
}

/// Mirror of `raster/arrow_base.intoArrowBit`: the bit a base cell must
/// carry to feed an arrowhead whose tip points `tip` — the arm points
/// TOWARD the arrowhead, i.e. in the tip direction itself.
/// guarded-by: cell_test.zig "intoArrowBit is the tip-direction bit for all four tips"
pub fn intoArrowBit(tip: Dir4) u4 {
    return bit(tip);
}

/// The two directions perpendicular to `axis` — for an arrowhead, the
/// arms that are NOT part of its run.
pub fn perpendicular(axis: Dir4) [2]Dir4 {
    return switch (axis) {
        .north, .south => .{ .east, .west },
        .east, .west => .{ .north, .south },
    };
}

/// One step from `(x,y)` in direction `d`, or null when that leaves the
/// `w` x `h` grid.
pub fn step(x: u32, y: u32, d: Dir4, w: u32, h: u32) ?struct { x: u32, y: u32 } {
    return switch (d) {
        .north => if (y >= 1) .{ .x = x, .y = y - 1 } else null,
        .south => if (y + 1 < h) .{ .x = x, .y = y + 1 } else null,
        .west => if (x >= 1) .{ .x = x - 1, .y = y } else null,
        .east => if (x + 1 < w) .{ .x = x + 1, .y = y } else null,
    };
}

/// The ring arms a rasterizer writes for `role`. Mirror of
/// `raster/nodes.zig`'s `rasterizeRect` / `writeThinRect` tables.
///
/// `thin` selects the degenerate 1xN / Nx1 forms. Those write a SUBSET of
/// the full-rect arms (thin `corner_nw` is one of `{}`, `{e}`, `{s}`
/// depending on the run's axis), so the thin answer is the SUPERSET of
/// the possible shapes: masks only ever gain bits, so a superset is the
/// safe denominator when computing a ring cell's "extra" arms.
/// guarded-by: cell_test.zig "ringAxes matches the nodes.zig full-rect table and contains every thin form"
pub fn ringAxes(role: lattice.BorderRole, thin: bool) u4 {
    const e = bit(.east);
    const w = bit(.west);
    const n = bit(.north);
    const s = bit(.south);
    if (thin) {
        return switch (role) {
            // Thin runs collapse the corners: a horizontal run writes
            // `{e}` / `{w}`, a vertical one `{s}` / `{n}`, a 1x1 none.
            .corner_nw => e | s,
            .corner_ne => w,
            .corner_sw => n,
            .corner_se => w | n,
            .edge_n, .edge_s => e | w,
            .edge_w, .edge_e => n | s,
        };
    }
    return switch (role) {
        .corner_nw => e | s,
        .corner_ne => w | s,
        .corner_se => w | n,
        .corner_sw => e | n,
        .edge_n, .edge_s => e | w,
        .edge_w, .edge_e => n | s,
    };
}

/// Read-only window onto the SHIPPED lattice. Hands out `Typed` copies
/// and never a `*Cell`, so no check can write through it.
/// guarded-by: scan_test.zig "scan: run() leaves the lattice byte-identical"
pub const View = struct {
    lat: *const lattice.Lattice,

    pub fn init(lat: *const lattice.Lattice) View {
        return .{ .lat = lat };
    }

    pub fn width(self: View) u32 {
        return self.lat.width;
    }

    pub fn height(self: View) u32 {
        return self.lat.height;
    }

    /// Typed copy of `(x,y)`, or null when out of bounds.
    pub fn at(self: View, x: u32, y: u32) ?Typed {
        if (x >= self.lat.width or y >= self.lat.height) return null;
        return classify(self.lat.atConst(x, y).*);
    }

    /// Display COLUMNS this cell contributes when painted. Mirror of
    /// `paint.cellWidth`: every glyph the painter emits is width 1 except
    /// a label codepoint, which is sized by East-Asian Width. The gap
    /// between this and the one cell the label writer advanced is the
    /// item-4 defect `m_row_col_overflow` measures.
    /// guarded-by: cell_test.zig "columns mirrors paint.cellWidth: wide label glyph is two columns"
    pub fn columns(self: View, x: u32, y: u32) u32 {
        if (x >= self.lat.width or y >= self.lat.height) return 0;
        return switch (self.lat.atConst(x, y).occupant) {
            .label_char => |cp| prim.codepointWidth(cp),
            else => 1,
        };
    }

    /// True when `(x,y)` holds a label codepoint of East-Asian-Wide width.
    pub fn isWideGlyph(self: View, x: u32, y: u32) bool {
        if (x >= self.lat.width or y >= self.lat.height) return false;
        return switch (self.lat.atConst(x, y).occupant) {
            .label_char => |cp| prim.codepointWidth(cp) == 2,
            else => false,
        };
    }

    /// Typed copy of the neighbour one step in direction `d`.
    pub fn arm(self: View, x: u32, y: u32, d: Dir4) ?Typed {
        const p = step(x, y, d, self.lat.width, self.lat.height) orelse return null;
        return self.at(p.x, p.y);
    }

    /// True when the neighbour in direction `d` carries the arm pointing
    /// back at `(x,y)`. Judged on `mask` (the committed neighbour bits),
    /// exactly as the raster reconcile pass judges it — an invisible
    /// stroke that carries the bit still reciprocates.
    pub fn reciprocates(self: View, x: u32, y: u32, d: Dir4) bool {
        const n = self.arm(x, y, d) orelse return false;
        return n.mask & bit(reverse(d)) != 0;
    }

    /// Mirror of `raster/reconcile.bitIsPhantom`'s second step: the arm
    /// in direction `d` points at an EMPTY cell, but the cell one further
    /// along the same axis genuinely continues the run — it reciprocates
    /// (`reverse(d)` set) or is a terminal arrowhead.
    /// Callers apply this only after finding the adjacent cell blank or
    /// out of bounds; an out-of-bounds walk is never reprieved.
    /// guarded-by: cell_test.zig "gapReprieve honours reciprocation and refuses a non-reciprocating collinear cell"
    pub fn gapReprieve(self: View, x: u32, y: u32, d: Dir4) bool {
        const w = self.lat.width;
        const h = self.lat.height;
        const one = step(x, y, d, w, h) orelse return false;
        const two = step(one.x, one.y, d, w, h) orelse return false;
        const t = self.at(two.x, two.y) orelse return false;
        return switch (t.kind) {
            .blank => false,
            .arrow => true,
            else => t.mask & bit(reverse(d)) != 0,
        };
    }
};
