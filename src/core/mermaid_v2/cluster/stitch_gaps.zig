//! cluster/stitch_gaps.zig — the gap row records a stitch carries up:
//! each piece's records translated into the merged frame and id space,
//! and the bridge bands a piece reserved without knowing the bridge filed
//! under the bridges that landed on them.
//!
//! Imports: std + sem_graph + sketch + base/ledger.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");

/// `bridges` maps a placement edge of the piece to the merged ids of the
/// bridges that stand for it (empty for a child piece): a bridge claim's
/// edges become the ink the stitch actually paints for them.
pub fn translateGap(arena: std.mem.Allocator, g: ledger.GapRows, gmap: []const sketch.NodeId, dx: i32, dy: i32, id_base: sketch.EdgeId, dir: sketch.Direction, bridges_of: []const []const sketch.EdgeId) error{OutOfMemory}!ledger.GapRows {
    const along: i32 = if (dir == .LR or dir == .RL) dx else dy;
    var out = g;
    out.near = g.near + along;
    out.far = g.far + along;
    const claims = try arena.alloc(ledger.GapClaim, g.claims.len);
    for (g.claims, claims) |c, *oc| {
        var mapped: std.ArrayListUnmanaged(ledger.EdgeId) = .empty;
        for (c.edges) |e| {
            if (c.bridge and e < bridges_of.len) {
                try mapped.appendSlice(arena, bridges_of[e]);
            } else try mapped.append(arena, e + id_base);
        }
        const edges = try mapped.toOwnedSlice(arena);
        const rails = try arena.alloc(ledger.RailKey, c.rails.len);
        for (c.rails, rails) |r, *key| key.* = .{ .pivot = if (r.pivot < gmap.len) gmap[r.pivot] else sg.SENTINEL, .out = r.out };
        oc.* = .{ .row = c.row, .height = c.height, .edges = edges, .rails = rails, .bridge = c.bridge };
    }
    out.claims = claims;
    return out;
}

/// A piece reserved a bridge band without knowing the bridge's id (a
/// departure band, `gap_rows.departureClaims`): every bridge run that
/// lands on such a band's rows is filed under it, so the painted-ink
/// invariant can trace the ink to the claim that reserved its row.
pub fn adoptBridgeInk(arena: std.mem.Allocator, records: []ledger.GapRows, paths: []const sketch.EdgePath, dir: sketch.Direction) error{OutOfMemory}!void {
    const vertical = dir == .TD or dir == .BT;
    for (records) |*g| {
        var changed = false;
        const claims = try arena.dupe(ledger.GapClaim, g.claims);
        for (claims) |*c| {
            if (!c.bridge or c.edges.len != 0) continue;
            var ids: std.ArrayListUnmanaged(ledger.EdgeId) = .empty;
            for (paths) |b| {
                var i: usize = 1;
                while (i < b.polyline.len) : (i += 1) {
                    const p = b.polyline[i - 1];
                    const q = b.polyline[i];
                    const along = if (vertical) p.y == q.y else p.x == q.x;
                    const moves = if (vertical) p.x != q.x else p.y != q.y;
                    if (!along or !moves) continue;
                    const at = if (vertical) p.y else p.x;
                    if (at < @min(g.near, g.far) or at > @max(g.near, g.far)) continue;
                    const toward_far: i32 = if (g.far >= g.near) 1 else -1;
                    const row = (at - g.near) * toward_far - 2;
                    if (row < c.row or row >= c.row + @as(i32, @intCast(c.height))) continue;
                    if (std.mem.indexOfScalar(ledger.EdgeId, ids.items, b.id) == null) try ids.append(arena, b.id);
                }
            }
            if (ids.items.len == 0) continue;
            c.edges = try ids.toOwnedSlice(arena);
            changed = true;
        }
        if (changed) g.claims = claims;
    }
}

