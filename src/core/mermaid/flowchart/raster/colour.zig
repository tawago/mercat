//! The grid's colours: a node wears its outline, an edge its stroke, read off the sketch where
//! the raster writes each cell. Ink several edges share keeps a colour only when all agree.

const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");

const Rgb = prim.Rgb;

const MAX_COLOURS = std.math.maxInt(u8);

/// Every distinct outline and edge colour of the sketch, first seen first; past 255 the rest
/// wear none.
pub fn palette(a: std.mem.Allocator, s: sketch.Sketch) error{OutOfMemory}![]const Rgb {
    var out: std.ArrayList(Rgb) = .empty;
    for (s.nodes) |np| if (np.outline) |c| try add(a, &out, c);
    for (s.edge_colours) |maybe| if (maybe) |c| try add(a, &out, c);
    return out.toOwnedSlice(a);
}

/// Each declared edge's colour in `pal`, as a `Cell.colour`.
pub fn edgeColours(a: std.mem.Allocator, pal: []const Rgb, s: sketch.Sketch) error{OutOfMemory}![]const u8 {
    const out = try a.alloc(u8, s.edge_colours.len);
    for (s.edge_colours, out) |c, *o| o.* = indexIn(pal, c);
    return out;
}

fn add(a: std.mem.Allocator, out: *std.ArrayList(Rgb), c: Rgb) error{OutOfMemory}!void {
    if (out.items.len == MAX_COLOURS) return;
    for (out.items) |have| if (std.meta.eql(have, c)) return;
    try out.append(a, c);
}

pub fn index(lat: *const lattice.Lattice, c: ?Rgb) u8 {
    return indexIn(lat.palette, c);
}

fn indexIn(pal: []const Rgb, c: ?Rgb) u8 {
    const want = c orelse return 0;
    for (pal, 1..) |have, i| if (std.meta.eql(have, want)) return @intCast(i);
    return 0;
}

pub fn ofNode(lat: *const lattice.Lattice, np: sketch.NodePlacement) u8 {
    return index(lat, np.outline);
}

pub fn ofOrigin(lat: *const lattice.Lattice, origin: prim.EdgeId) u8 {
    return if (origin < lat.edge_colours.len) lat.edge_colours[origin] else 0;
}

/// The colour of a rail's shared cells: its taps' colour when every tap agrees.
pub fn ofRail(lat: *const lattice.Lattice, rail: sketch.Rail) u8 {
    if (rail.taps.len == 0) return 0;
    var c = ofOrigin(lat, rail.taps[0].origin);
    for (rail.taps[1..]) |t| c = merge(c, ofOrigin(lat, t.origin));
    return c;
}

/// The colour of one crossbar cell: the merge of the taps whose arm runs through it, the
/// junction and any cell no arm reaches taking the whole rail's.
pub fn ofCrossbarCell(lat: *const lattice.Lattice, rail: sketch.Rail, x: i32) u8 {
    const jx = rail.stem[rail.stem.len - 1].x;
    var c: ?u8 = null;
    for (rail.taps) |t| {
        if (x < @min(jx, t.at.x) or x > @max(jx, t.at.x)) continue;
        const own = ofOrigin(lat, t.origin);
        c = if (c) |have| merge(have, own) else own;
    }
    return c orelse ofRail(lat, rail);
}

/// Two owners of one cell: an uncoloured owner is a colour of its own.
pub fn merge(a: u8, b: u8) u8 {
    return if (a == b) a else 0;
}

test {
    _ = @import("colour_test.zig");
}
