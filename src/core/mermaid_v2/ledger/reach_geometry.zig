//! reach_geometry.zig — pure vector-geometry decomposition for
//! the pre-raster D-REACH reachability oracle (P2v Step 6;
//! D-REACH items 5/9). Split sibling of `reach_vector.zig` for the
//! 500-line cap, mirroring realized/invariants.
//!
//! Turns Sketch geometry into conductive UNITS: each edge-owned
//! `EdgePath` polyline, each realized whole-rail `Rail`, and — for a
//! Rail NOT realized by a selected bundle — one per-tap share (the
//! member's own stem/rail/drop path, whose collinear sharing with its
//! siblings is exactly the cross-owner event D-REACH clause 9 reports).
//! Every unit carries its cell set with straight-pass flags (for the
//! clause-7 strict-transversal test) and its typed terminal attachments
//! (derived border-cell locations, D-REACH clauses 2/5).
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, ledger,
//! sketch.

const std = @import("std");
const prim = @import("prim");
const sk = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");

pub const Error = error{OutOfMemory};

pub const Cell = struct { x: i32, y: i32 };

/// Per-cell conduction info within one unit. `straight_h`/`straight_v`
/// mark an interior straight pass along the axis; `bend` marks any
/// segment endpoint or corner at the cell. A strict orthogonal
/// transversal (D-REACH clause 7) requires a straight single-axis pass
/// with no bend on BOTH participants.
pub const PassInfo = struct {
    straight_h: bool = false,
    straight_v: bool = false,
    bend: bool = false,

    pub fn merge(self: *PassInfo, other: PassInfo) void {
        self.straight_h = self.straight_h or other.straight_h;
        self.straight_v = self.straight_v or other.straight_v;
        self.bend = self.bend or other.bend;
    }
};

/// One typed terminal attachment derived from the owning geometry at
/// consumption time (D-REACH clause 2: the recorded artifact names the
/// terminal; the Sketch names its border cell).
pub const Attachment = struct {
    edge: pb.EdgeId,
    node: sk.NodeId,
    endpoint_side: pb.EndpointSide,
    cell: Cell,
};

pub const CellMap = std.AutoArrayHashMapUnmanaged(Cell, PassInfo);

/// What walking one oriented path in its stated order does to a trace's
/// orientation (direction consistency). `with`: the path's one directional
/// end sits at its last cell, so the walk runs with the head. `against`:
/// the head sits at its first cell. `none`: the path constrains nothing
/// (no directional end, or one at both ends).
pub const Head = enum { none, with, against };

/// One contiguous cell path of a unit, in declared from→to order, with the
/// orientation walking it asserts. A rail unit carries several: its stem,
/// its crossbar (never oriented), and one drop per member.
pub const OrientedPath = struct {
    cells: []const Cell,
    head: Head,
};

/// Orientation a walk from `arrow_from`'s end to `arrow_to`'s end asserts.
pub fn headOf(arrow_from: prim.ArrowKind, arrow_to: prim.ArrowKind) Head {
    if (!prim.blocks(arrow_from, arrow_to)) return .none;
    return if (prim.directional(arrow_to)) .with else .against;
}

/// One conductive geometry unit.
pub const Unit = struct {
    /// Owning declared edge — set for edge-owned polylines and
    /// unrealized per-tap shares; null for realized whole-rail units.
    edge: ?pb.EdgeId,
    /// Realized bundle this unit IS the rail of (whole-rail units only).
    bundle: ?pb.SelectedBundleId,
    cells: CellMap,
    attachments: []const Attachment,
    /// The unit's ink as oriented paths (see `OrientedPath`); the walk
    /// reads these, the cell map serves the transversal test.
    paths: []const OrientedPath = &.{},
};

/// D-JOIN direction of a Rail read from its role (same mapping as
/// realized.zig, re-stated here because realized may not be imported
/// from this zone).
pub fn railDirection(rail: sk.Rail) pb.BundleDirection {
    return switch (rail.role) {
        .fan_in_dropper, .fan_in_rail => .in,
        else => .out,
    };
}

/// Append the inclusive unit-step cell path of one straight (or, defensively,
/// L-decomposed) segment from `a` to `b`, excluding `a` itself when
/// `skip_first` (chaining).
fn appendSegment(alloc: std.mem.Allocator, path: *std.ArrayListUnmanaged(Cell), a: sk.Point, b: sk.Point, skip_first: bool) Error!void {
    if (!skip_first) try path.append(alloc, .{ .x = a.x, .y = a.y });
    var cur = a;
    while (cur.x != b.x) {
        cur.x += if (b.x > cur.x) 1 else -1;
        try path.append(alloc, .{ .x = cur.x, .y = cur.y });
    }
    while (cur.y != b.y) {
        cur.y += if (b.y > cur.y) 1 else -1;
        try path.append(alloc, .{ .x = cur.x, .y = cur.y });
    }
}

/// Cell path of a full polyline (consecutive duplicate points tolerated).
fn cellPath(alloc: std.mem.Allocator, pts: []const sk.Point) Error![]const Cell {
    var path: std.ArrayListUnmanaged(Cell) = .empty;
    if (pts.len == 0) return path.toOwnedSlice(alloc);
    try path.append(alloc, .{ .x = pts[0].x, .y = pts[0].y });
    for (pts[1..], 0..) |p, i| try appendSegment(alloc, &path, pts[i], p, true);
    return path.toOwnedSlice(alloc);
}

/// Fold one contiguous cell path into a unit's cell map: interior cells
/// whose predecessor and successor lie on one axis get the straight-pass
/// flag; path endpoints and corners get `bend`.
fn foldPath(alloc: std.mem.Allocator, map: *CellMap, path: []const Cell) Error!void {
    for (path, 0..) |c, i| {
        var info: PassInfo = .{};
        if (i == 0 or i + 1 == path.len) {
            info.bend = true;
        } else {
            const p = path[i - 1];
            const n = path[i + 1];
            if (p.y == c.y and n.y == c.y) {
                info.straight_h = true;
            } else if (p.x == c.x and n.x == c.x) {
                info.straight_v = true;
            } else {
                info.bend = true;
            }
        }
        const gop = try map.getOrPut(alloc, c);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.merge(info);
    }
}

/// Unit for one edge-owned polyline (bundle class (a), D-REACH item 9).
pub fn edgeUnit(alloc: std.mem.Allocator, e: sk.EdgePath) Error!Unit {
    var cells: CellMap = .empty;
    const path = try cellPath(alloc, e.polyline);
    try foldPath(alloc, &cells, path);
    const paths = try alloc.alloc(OrientedPath, 1);
    paths[0] = .{ .cells = path, .head = headOf(e.arrow_from, e.arrow_to) };
    const att = try alloc.alloc(Attachment, 2);
    const first: Cell = if (path.len > 0) path[0] else .{ .x = 0, .y = 0 };
    const last: Cell = if (path.len > 0) path[path.len - 1] else .{ .x = 0, .y = 0 };
    att[0] = .{ .edge = e.id, .node = e.from, .endpoint_side = .source_exit, .cell = first };
    att[1] = .{ .edge = e.id, .node = e.to, .endpoint_side = .target_entry, .cell = last };
    return .{ .edge = e.id, .bundle = null, .cells = cells, .attachments = att, .paths = paths };
}

/// A member's end decorations in declared from→to order: the pivot end
/// is the rail's uniform `pivot_arrow`, the leaf end is the tap's own.
fn memberHead(rail: sk.Rail, tap: sk.Tap) Head {
    return if (railDirection(rail) == .out)
        headOf(rail.pivot_arrow, tap.arrow)
    else
        headOf(tap.arrow, rail.pivot_arrow);
}

/// The stem carries every member's pivot-side semantics. Under the star
/// licence all members share one head class, so the stem takes it; a rail
/// whose members disagree gets an unconstrained stem — the conservative
/// reading, since fewer blocked steps can only surface more pairs.
fn stemHead(rail: sk.Rail) Head {
    if (rail.taps.len == 0) return .none;
    const first = memberHead(rail, rail.taps[0]);
    for (rail.taps[1..]) |tap| if (memberHead(rail, tap) != first) return .none;
    return first;
}

/// A cell path in declared from→to order: a fan-OUT path is stated pivot
/// side first, so it stays; a fan-IN path is stated the same way and is
/// reversed so the declared source (the leaf) comes first.
fn declaredOrder(alloc: std.mem.Allocator, rail: sk.Rail, pivot_first: []const sk.Point) Error![]const Cell {
    const path = try alloc.dupe(Cell, try cellPath(alloc, pivot_first));
    if (railDirection(rail) == .in) std.mem.reverse(Cell, path);
    return path;
}

fn railPoint(rail: sk.Rail, x: i32) sk.Point {
    return .{ .x = x, .y = rail.crossbar[0].y };
}

fn tapAttachments(rail: sk.Rail, tap: sk.Tap, out: *std.ArrayListUnmanaged(Attachment), alloc: std.mem.Allocator) Error!void {
    const stem_start: Cell = if (rail.stem.len > 0)
        .{ .x = rail.stem[0].x, .y = rail.stem[0].y }
    else
        .{ .x = 0, .y = 0 };
    const landing: Cell = .{ .x = tap.landing.x, .y = tap.landing.y };
    const out_dir = railDirection(rail) == .out;
    try out.append(alloc, .{
        .edge = tap.edge,
        .node = rail.pivot,
        .endpoint_side = if (out_dir) .source_exit else .target_entry,
        .cell = stem_start,
    });
    try out.append(alloc, .{
        .edge = tap.edge,
        .node = tap.node,
        .endpoint_side = if (out_dir) .target_entry else .source_exit,
        .cell = landing,
    });
}

/// Whole-rail unit for a Rail realized by a selected bundle (bundle
/// class (b)): stem + full rail + every tap drop as ONE bundle whose
/// component must contain the pivot terminal and exactly its member
/// terminals (D-REACH clause 6).
pub fn railUnit(alloc: std.mem.Allocator, rail: sk.Rail, bundle: pb.SelectedBundleId) Error!Unit {
    var cells: CellMap = .empty;
    var paths: std.ArrayListUnmanaged(OrientedPath) = .empty;
    const stem = try cellPath(alloc, rail.stem);
    try foldPath(alloc, &cells, stem);
    try paths.append(alloc, .{ .cells = try declaredOrder(alloc, rail, rail.stem), .head = stemHead(rail) });
    const crossbar = try cellPath(alloc, &.{ rail.crossbar[0], rail.crossbar[1] });
    try foldPath(alloc, &cells, crossbar);
    try paths.append(alloc, .{ .cells = crossbar, .head = .none });
    var att: std.ArrayListUnmanaged(Attachment) = .empty;
    for (rail.taps) |tap| {
        const drop = [_]sk.Point{ tap.at, tap.landing };
        try foldPath(alloc, &cells, try cellPath(alloc, &drop));
        try paths.append(alloc, .{ .cells = try declaredOrder(alloc, rail, &drop), .head = memberHead(rail, tap) });
        try tapAttachments(rail, tap, &att, alloc);
    }
    return .{ .edge = null, .bundle = bundle, .cells = cells, .attachments = try att.toOwnedSlice(alloc), .paths = try paths.toOwnedSlice(alloc) };
}

/// Per-tap share unit for a Rail NOT realized by any selected bundle:
/// the member edge's own conductive path (stem, rail run from the stem
/// junction to its tap, drop). Sibling shares overlap collinearly on the
/// stem/rail — the cross-owner sharing D-REACH clause 9 reports, because
/// an unrealized fusion is a bundle of no class.
pub fn tapShareUnit(alloc: std.mem.Allocator, rail: sk.Rail, tap: sk.Tap) Error!Unit {
    var cells: CellMap = .empty;
    try foldPath(alloc, &cells, try cellPath(alloc, rail.stem));
    const junction_x: i32 = if (rail.stem.len > 0) rail.stem[rail.stem.len - 1].x else rail.crossbar[0].x;
    try foldPath(alloc, &cells, try cellPath(alloc, &.{ railPoint(rail, junction_x), railPoint(rail, tap.at.x) }));
    try foldPath(alloc, &cells, try cellPath(alloc, &.{ tap.at, tap.landing }));
    var att: std.ArrayListUnmanaged(Attachment) = .empty;
    try tapAttachments(rail, tap, &att, alloc);
    // The member's whole conductive path, pivot side first: stem, the
    // crossbar stretch to its tap, its drop — one oriented path.
    var pts: std.ArrayListUnmanaged(sk.Point) = .empty;
    try pts.appendSlice(alloc, rail.stem);
    try pts.append(alloc, railPoint(rail, junction_x));
    try pts.append(alloc, railPoint(rail, tap.at.x));
    try pts.append(alloc, tap.at);
    try pts.append(alloc, tap.landing);
    const paths = try alloc.alloc(OrientedPath, 1);
    paths[0] = .{ .cells = try declaredOrder(alloc, rail, pts.items), .head = memberHead(rail, tap) };
    return .{ .edge = tap.edge, .bundle = null, .cells = cells, .attachments = try att.toOwnedSlice(alloc), .paths = paths };
}

/// Label 4-adjacency connected sub-components over a deduplicated cell
/// list. Returns one label per input cell; labels are densely numbered in
/// first-visit order of the (deterministically ordered) input list.
pub fn componentLabels(alloc: std.mem.Allocator, cells: []const Cell) Error![]const u32 {
    var index: std.AutoArrayHashMapUnmanaged(Cell, usize) = .empty;
    defer index.deinit(alloc);
    for (cells, 0..) |c, i| try index.put(alloc, c, i);

    const labels = try alloc.alloc(u32, cells.len);
    @memset(labels, std.math.maxInt(u32));
    var next: u32 = 0;
    var stack: std.ArrayListUnmanaged(usize) = .empty;
    defer stack.deinit(alloc);
    for (cells, 0..) |_, start| {
        if (labels[start] != std.math.maxInt(u32)) continue;
        labels[start] = next;
        try stack.append(alloc, start);
        while (stack.pop()) |i| {
            const c = cells[i];
            const neighbours = [4]Cell{
                .{ .x = c.x + 1, .y = c.y }, .{ .x = c.x - 1, .y = c.y },
                .{ .x = c.x, .y = c.y + 1 }, .{ .x = c.x, .y = c.y - 1 },
            };
            for (neighbours) |n| {
                const j = index.get(n) orelse continue;
                if (labels[j] != std.math.maxInt(u32)) continue;
                labels[j] = next;
                try stack.append(alloc, j);
            }
        }
        next += 1;
    }
    return labels;
}

fn strictPass(p: PassInfo) ?bool {
    if (p.bend) return null;
    if (p.straight_h and !p.straight_v) return true;
    if (p.straight_v and !p.straight_h) return false;
    return null;
}

/// D-REACH clause 7/9 shape test for one shared cell between two units of
/// DIFFERENT bundles: legal iff it is a strict orthogonal transversal
/// (each side passes straight through on one axis, axes perpendicular).
/// Everything else — collinear overlap, non-transversal contact — is the
/// `reach_unknown_continuation` pairing event.
pub fn transversal(a: PassInfo, b: PassInfo) bool {
    const ah = strictPass(a) orelse return false;
    const bh = strictPass(b) orelse return false;
    return ah != bh;
}

pub fn cellLess(_: void, a: Cell, b: Cell) bool {
    if (a.y != b.y) return a.y < b.y;
    return a.x < b.x;
}
