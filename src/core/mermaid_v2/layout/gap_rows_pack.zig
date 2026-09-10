//! gap_rows_pack.zig — the claim shapes of the gap row ledger and the
//! packer that gives every claim its row.
//!
//! A claim is one horizontal run's demand on a gap: its ink span on the
//! cross axis and the rows it stands on. Packing is first-fit by left
//! endpoint over an interval graph, under two orders: an arrival rail
//! sits nearer the target than a departure rail it conflicts with, and a
//! rail whose stem column is a foreign tap's column sits where that tap
//! ends before reaching its junction. Two claims share a row only when a
//! blank cell separates their ink. A claim with no decorated end in the
//! gap and no column shared with any other claim keeps the base row.
//!
//! Imports (layout zone): std + sem_graph + base/ledger + fan.zig + gap_rows_grid.zig.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const pb = @import("../base/ledger.zig");
const fan_mod = @import("fan.zig");
const grid = @import("gap_rows_grid.zig");

/// `detour_target` / `detour_source`: the two bands of a gap's duplicate
/// detours — the inward turns under the base cell, the outward turns
/// under the departure cells — the first nearest the target, the second
/// above every run it conflicts with.
/// `bridge_jog`: the jogs the cluster bridges of one arrival group paint
/// into a node from above — on the base row into a plain node, on the
/// arrival row into a cluster frame — stacking outward one track per
/// overlapping request. `bridge_return`: the head and turn a bridge lands
/// under an outer node's departure cells when it climbs back to it —
/// anchored like a detour's source band.
/// `grid_comb`: a gridded fan's run to a stacked sub-row, on the comb row
/// the grid reserved (a sub-gap's base row). `grid_dodge`: the jog a fan
/// takes under its pivot to a corridor beside an earlier sub-row's box.
pub const Kind = enum {
    fan_in,
    fan_out,
    fan_mixed,
    run,
    corridor_entry,
    corridor_exit,
    stroke_entry,
    stroke_exit,
    detour_target,
    detour_source,
    bridge_jog,
    bridge_return,
    grid_comb,
    grid_dodge,

    /// The band sits under the source wall, above every run it conflicts with.
    pub fn topAnchored(self: Kind) bool {
        return self == .detour_source or self == .bridge_return;
    }

    /// The ink is a cluster bridge's: painted by the stitch, not this piece.
    pub fn bridge(self: Kind) bool {
        return self == .bridge_jog or self == .bridge_return;
    }
};
pub const End = enum { entry, exit };
pub const FanKey = struct { pivot_idx: u32, direction: fan_mod.Direction };

/// One horizontal run's demand on a gap: its ink span on the cross axis,
/// the rows it stands on (a labeled band is `1 + LABEL_RUN_EXTRA_ROWS`),
/// and the identities its producers look it up by.
pub const Claim = struct {
    gap: u32,
    lo: i32,
    hi: i32,
    height: u32 = 1,
    kind: Kind,
    /// Row -1 admissible: no decorated end in this gap.
    base_ok: bool = false,
    end: End = .exit,
    edges: []const sg.EdgeId = &.{},
    fans: []const FanKey = &.{},
    /// The columns the run's ink comes down from its source side (a
    /// fan-OUT's pivot stem, a fan-IN's source taps, a jog's source port,
    /// a corridor exit's corridor) and goes on from toward the target
    /// side (a fan-OUT's peer taps, a fan-IN's pivot stem, a jog's target
    /// port, a corridor entry's corridor).
    stems: []const i32 = &.{},
    taps: []const i32 = &.{},
    /// Fusion key: claims of one gap with equal keys and a shared column are one run.
    fuse: ?u32 = null,
    /// The row the band starts on whatever else the gap holds: -1 the
    /// base row, -2 the arrival row (a bridge into a frame).
    pin: ?i32 = null,
    row: i32 = 0,

    fn departures(self: Claim) []const i32 {
        return if (self.kind == .fan_in) self.taps else self.stems;
    }

    fn arrivals(self: Claim) []const i32 {
        return if (self.kind == .fan_in) self.stems else self.taps;
    }
};

/// A decorated vertical with no run of its own: it keeps the base row.
pub const Post = struct { gap: u32, x: i32 };

pub const GapAccount = struct { base: u32, free: u32, rows_used: u32, claimed: u64, base_used: bool };

pub const Ledger = struct {
    claims: []const Claim = &.{},
    /// One account per inter-layer gap, then one per grid sub-gap.
    gaps: []const GapAccount = &.{},
    /// The grid sub-gaps, numbered after the inter-layer gaps; the layout
    /// grows a sub-gap's rows by what the packed claims need beyond the
    /// grid's, moving its wall.
    sub_gaps: []grid.SubGap = &.{},
    /// The placement edges whose ink the cluster bridges paint: this
    /// piece routes them without contest and the stitch drops their paths.
    proxies: []const sg.EdgeId = &.{},

    /// Rows this gap needs beyond its base spacing (`pb.gapSpacingNeeded`).
    pub fn extraRows(self: Ledger, gap: usize) u32 {
        if (gap >= self.gaps.len) return 0;
        const g = self.gaps[gap];
        return pb.gapSpacingNeeded(g.rows_used, g.base_used) -| g.base;
    }

    pub fn rowsUsed(self: Ledger, gap: usize) u32 {
        return if (gap < self.gaps.len) self.gaps[gap].rows_used else 0;
    }

    /// The rail row of a fan (null when the fan draws no run).
    pub fn rowOfFan(self: Ledger, pivot_idx: u32, direction: fan_mod.Direction) ?i32 {
        for (self.claims) |c| for (c.fans) |k| {
            if (k.pivot_idx == pivot_idx and k.direction == direction) return c.row;
        };
        return null;
    }

    /// The claim of an edge's run at `end`; a fan member drawn by its rail
    /// answers with the rail's claim for its exit run (the rail lists no
    /// member whose run lies in another gap).
    pub fn claimOfEdge(self: Ledger, edge: sg.EdgeId, end: End) ?Claim {
        for (self.claims) |c| {
            if (c.fans.len != 0 or c.end != end) continue;
            if (std.mem.indexOfScalar(sg.EdgeId, c.edges, edge) != null) return c;
        }
        if (end != .exit) return null;
        for (self.claims) |c| {
            if (c.fans.len == 0 or c.end != .exit) continue;
            if (std.mem.indexOfScalar(sg.EdgeId, c.edges, edge) != null) return c;
        }
        return null;
    }

    /// The row of an edge's run at `end`.
    pub fn rowOfEdge(self: Ledger, edge: sg.EdgeId, end: End) ?i32 {
        const c = self.claimOfEdge(edge, end) orelse return null;
        return c.row;
    }

    /// True iff the bridges paint this edge's ink.
    pub fn isProxy(self: Ledger, edge: sg.EdgeId) bool {
        return std.mem.indexOfScalar(sg.EdgeId, self.proxies, edge) != null;
    }

    /// The polyline lane of an edge's run: lane 0 is the base row (a
    /// bridge band pinned on the arrival row answers lane 0 too — its
    /// proxy is routed uncontested and its path dropped).
    pub fn laneOfEdge(self: Ledger, edge: sg.EdgeId, end: End) u32 {
        const row = self.rowOfEdge(edge, end) orelse -1;
        return @intCast(@max(row + 1, 0));
    }

    /// The report record per gap; `reserved[g]` is the spacing assignY
    /// used (a sub-gap's is its fixed base), `walls[g]` the gap's cells
    /// beside its two layers, and `node_of[i]` the node id of
    /// layered-graph index i (a virtual's is `sg.SENTINEL`).
    pub fn records(self: Ledger, a: std.mem.Allocator, reserved: []const u32, walls: []const GapWalls, node_of: []const u32) error{OutOfMemory}![]const pb.GapRows {
        const out = try a.alloc(pb.GapRows, self.gaps.len);
        for (self.gaps, out, 0..) |g, *r, gi| {
            var claims: std.ArrayListUnmanaged(pb.GapClaim) = .empty;
            for (self.claims) |c| {
                if (c.gap != gi) continue;
                const rails = try a.alloc(pb.RailKey, c.fans.len);
                for (c.fans, rails) |k, *key| key.* = .{ .pivot = node_of[k.pivot_idx], .out = k.direction == .out };
                try claims.append(a, .{ .row = c.row, .height = c.height, .edges = c.edges, .rails = rails, .bridge = c.kind.bridge() });
            }
            r.* = .{
                .gap = @intCast(gi),
                .base = g.base,
                .reserved = if (gi < reserved.len) reserved[gi] else g.base + self.extraRows(gi),
                .free = g.free,
                .rows_used = g.rows_used,
                .claimed = g.claimed,
                .base_used = g.base_used,
                .near = if (gi < walls.len) walls[gi].near else 0,
                .far = if (gi < walls.len) walls[gi].far else 0,
                .claims = try claims.toOwnedSlice(a),
            };
        }
        return out;
    }
};

/// A gap's first cell beside its target layer (`near`, the arrival cell)
/// and beside its source layer (`far`), on the layer axis.
pub const GapWalls = struct { far: i32, near: i32 };

/// Two spans conflict unless a blank cell separates them.
fn conflicts(x: Claim, y: Claim) bool {
    return !(x.hi + 1 < y.lo or y.hi + 1 < x.lo);
}

fn sharesColumn(x: Claim, y: Claim) bool {
    return !(x.hi < y.lo or y.hi < x.lo);
}

fn find(parent: []u32, x: u32) u32 {
    var r = x;
    while (parent[r] != r) r = parent[r];
    return r;
}

/// Merge every fusion class into one claim (union span, max height, concatenated identities).
fn fuse(a: std.mem.Allocator, claims: []const Claim) error{OutOfMemory}![]Claim {
    const parent = try a.alloc(u32, claims.len);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    for (claims, 0..) |x, i| {
        const kx = x.fuse orelse continue;
        for (claims[i + 1 ..], i + 1..) |y, j| {
            const ky = y.fuse orelse continue;
            if (x.gap != y.gap or kx != ky or !sharesColumn(x, y)) continue;
            const ri = find(parent, @intCast(i));
            const rj = find(parent, @intCast(j));
            if (ri != rj) parent[rj] = ri;
        }
    }
    var out: std.ArrayListUnmanaged(Claim) = .empty;
    for (claims, 0..) |c, i| {
        if (find(parent, @intCast(i)) != i) continue;
        var merged = c;
        var edges: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
        var fans: std.ArrayListUnmanaged(FanKey) = .empty;
        var stems: std.ArrayListUnmanaged(i32) = .empty;
        var taps: std.ArrayListUnmanaged(i32) = .empty;
        var members: usize = 0;
        for (claims, 0..) |m, j| {
            if (find(parent, @intCast(j)) != i) continue;
            members += 1;
            merged.lo = @min(merged.lo, m.lo);
            merged.hi = @max(merged.hi, m.hi);
                merged.height = @max(merged.height, m.height);
            merged.base_ok = merged.base_ok and m.base_ok;
            if (m.kind != c.kind) merged.kind = .fan_mixed;
            try edges.appendSlice(a, m.edges);
            try fans.appendSlice(a, m.fans);
            try stems.appendSlice(a, m.stems);
            try taps.appendSlice(a, m.taps);
        }
        if (members > 1) {
            merged.edges = try edges.toOwnedSlice(a);
            merged.fans = try fans.toOwnedSlice(a);
            merged.stems = try stems.toOwnedSlice(a);
            merged.taps = try taps.toOwnedSlice(a);
        }
        try out.append(a, merged);
    }
    return out.toOwnedSlice(a);
}

fn containsCol(xs: []const i32, v: i32) bool {
    return std.mem.indexOfScalar(i32, xs, v) != null;
}

fn anyStemInTaps(stems: []const i32, taps: []const i32) bool {
    for (stems) |s| if (containsCol(taps, s)) return true;
    return false;
}

fn anyStrictlyInside(cols: []const i32, lo: i32, hi: i32) bool {
    for (cols) |v| if (lo < v and v < hi) return true;
    return false;
}

/// True iff `upper` sitting nearer the source than `lower` puts a
/// vertical through the other's run: an arrival of `upper` goes on
/// toward the target through `lower`'s row inside its span, or a
/// departure of `lower` comes down from the source through `upper`'s
/// row inside its span.
/// @guarded-by: gap_rows_test2.zig "a fan-OUT run whose span holds another fan-OUT's taps sits nearer the source"
fn crossesAbove(upper: Claim, lower: Claim) bool {
    return anyStrictlyInside(upper.arrivals(), lower.lo, lower.hi) or anyStrictlyInside(lower.departures(), upper.lo, upper.hi);
}

/// `before[i][j]`: claim i's rows lie nearer the target than claim j's.
/// A pinned band precedes and a top-anchored band follows every
/// conflicting claim; an arrival rail sits nearer the target than a
/// departure rail; and, unless `stem_taps` is off, a run whose ink goes
/// on toward the target down a column another run's ink comes down from
/// its source sits nearer the target — the two verticals would otherwise
/// share that column between the rows — and a run that would cross the
/// other's run from above, when the other would not cross it from
/// above, sits nearer the target: a wider fan-OUT holds the narrower
/// one's taps inside its span, so the narrower sits under it. A pair
/// that crosses either way stays unordered.
fn precedence(before: []bool, claims: []const Claim, idx: []const usize, stem_taps: bool) void {
    const n = idx.len;
    @memset(before, false);
    for (idx, 0..) |ci, i| for (idx, 0..) |cj, j| {
        if (i == j) continue;
        const x = claims[ci];
        const y = claims[cj];
        if (!conflicts(x, y)) continue;
        // Two top-anchored bands stay unordered: first-fit stacks them.
        if ((x.pin != null or y.kind.topAnchored()) and !x.kind.topAnchored()) before[i * n + j] = true;
        if (x.kind == .fan_in and y.kind == .fan_out) before[i * n + j] = true;
        if (stem_taps and anyStemInTaps(y.departures(), x.arrivals())) before[i * n + j] = true;
        if (stem_taps and crossesAbove(x, y) and !crossesAbove(y, x)) before[i * n + j] = true;
    };
}

/// Rows `[r, r+h)` are free of every placed conflicting claim (a band
/// that starts on the base row still covers the rows above it).
fn fits(claims: []const Claim, idx: []const usize, placed: []const bool, c: Claim, r: i32) bool {
    for (idx, 0..) |cj, j| {
        if (!placed[j]) continue;
        const p = claims[cj];
        if (!conflicts(c, p)) continue;
        const p_hi = p.row + @as(i32, @intCast(p.height));
        const c_hi = r + @as(i32, @intCast(c.height));
        if (r < p_hi and p.row < c_hi) return false;
    }
    return true;
}

/// Pack one gap. Returns false when the precedence cannot be ordered.
fn packGap(a: std.mem.Allocator, claims: []Claim, posts: []const Post, gap: u32, stem_taps: bool) error{OutOfMemory}!bool {
    var idx: std.ArrayListUnmanaged(usize) = .empty;
    defer idx.deinit(a);
    for (claims, 0..) |c, i| if (c.gap == gap) try idx.append(a, i);
    const n = idx.items.len;
    if (n == 0) return true;
    const before = try a.alloc(bool, n * n);
    defer a.free(before);
    precedence(before, claims, idx.items, stem_taps);
    const placed = try a.alloc(bool, n);
    defer a.free(placed);
    @memset(placed, false);

    // A pinned band takes its row first. Then the base row: a run with no
    // decorated end in this gap, sharing no column with any other claim or
    // post, keeps its base-cell row.
    for (idx.items, 0..) |ci, i| {
        const c = claims[ci];
        if (c.pin) |r| {
            claims[ci].row = r;
            placed[i] = true;
            continue;
        }
        if (!c.base_ok) continue;
        var clear = true;
        for (idx.items, 0..) |cj, j| if (i != j and conflicts(c, claims[cj])) {
            clear = false;
        };
        for (posts) |p| if (p.gap == gap and c.lo - 1 <= p.x and p.x <= c.hi + 1) {
            clear = false;
        };
        if (!clear) continue;
        claims[ci].row = -1;
        placed[i] = true;
    }

    var remaining: usize = 0;
    for (placed) |p| if (!p) {
        remaining += 1;
    };
    while (remaining > 0) {
        var pick: ?usize = null;
        for (idx.items, 0..) |ci, i| {
            if (placed[i]) continue;
            var ready = true;
            for (0..n) |j| if (before[j * n + i] and !placed[j]) {
                ready = false;
            };
            if (!ready) continue;
            if (pick == null or claims[ci].lo < claims[idx.items[pick.?]].lo) pick = i;
        }
        const i = pick orelse return false;
        const ci = idx.items[i];
        var r: i32 = 0;
        for (0..n) |j| if (before[j * n + i]) {
            r = @max(r, claims[idx.items[j]].row + 1);
        };
        while (!fits(claims, idx.items, placed, claims[ci], r)) r += 1;
        claims[ci].row = r;
        placed[i] = true;
        remaining -= 1;
    }
    return true;
}

/// Pack `claims` into rows, gap by gap. `bases[g]` is gap g's base spacing;
/// the rows it holds beyond the two arrival rows are free.
pub fn pack(a: std.mem.Allocator, raw: []const Claim, posts: []const Post, bases: []const u32) error{OutOfMemory}!Ledger {
    return packSub(a, raw, posts, bases, &.{});
}

/// `pack` where sub-gaps follow the inter-layer gaps in `bases`,
/// `sub_gaps` naming them.
pub fn packSub(a: std.mem.Allocator, raw: []const Claim, posts: []const Post, bases: []const u32, sub_gaps: []grid.SubGap) error{OutOfMemory}!Ledger {
    const claims = try fuse(a, raw);
    const gaps = try a.alloc(GapAccount, bases.len);
    for (gaps, bases, 0..) |*g, base, gi| {
        const gap: u32 = @intCast(gi);
        if (!try packGap(a, claims, posts, gap, true)) {
            if (!try packGap(a, claims, posts, gap, false)) unreachable;
        }
        var rows_used: u32 = 0;
        var claimed: u64 = 0;
        var base_used = false;
        for (claims) |c| {
            if (c.gap != gap) continue;
            const top_i = c.row + @as(i32, @intCast(c.height));
            // The base row is `wall-2`; a band pinned on the arrival row
            // (`wall-1`) alone leaves it free, and a one-cell gap holds it.
            if (c.row <= -1 and top_i >= 0) base_used = true;
            if (top_i <= 0) continue;
            const top: u32 = @intCast(top_i);
            rows_used = @max(rows_used, top);
            var r: u32 = @intCast(@max(c.row, 0));
            while (r < top) : (r += 1) {
                if (r < 64) claimed |= @as(u64, 1) << @intCast(r);
            }
        }
        g.* = .{ .base = base, .free = base -| 2, .rows_used = rows_used, .claimed = claimed, .base_used = base_used };
    }
    return .{ .claims = claims, .gaps = gaps, .sub_gaps = sub_gaps };
}
