//! Traces between box borders over the scanned ink.
//!
//! Each declared edge is attributed to the unique ink path between two
//! terminals whose boxes, end markers and stroke match it; that path is the
//! edge's member ink. A trace between two terminals is admissible when it can
//! be carried by members from end to end, changing member only at a junction
//! both members pass, with every one-way member run in the same sense.
//!
//! A rail is a straight run holding two or more junctions. Its interior
//! belongs to every member whose path touches it and is a conduit: a trace
//! may change member anywhere on it, and no direction is read along it.

const std = @import("std");
const grid = @import("grid.zig");

pub const Endpoint = struct { label: []const u8, frame: bool = false };

/// `.any` is a path drawn only with corners, junctions and end markers.
pub const Stroke = enum { any, solid, dotted, thick, mixed };

pub const Relation = struct {
    a: Endpoint,
    end_a: grid.End,
    b: Endpoint,
    end_b: grid.End,
    stroke: Stroke,
};

const Member = struct {
    ends: [2]usize,
    /// Position of each node on the member's path, from its `a` end.
    at: std.AutoHashMapUnmanaged(usize, usize),
    /// Which way along the path the member's one head points, if it has exactly one.
    one_way: ?bool,
    rails: std.AutoHashMapUnmanaged(usize, void),
};

const none = std.math.maxInt(usize);

const Tracer = struct {
    arena: std.mem.Allocator,
    scan: *grid.Scan,
    ends: []const Endpoint,
    edges: []const Relation,
    attributed: []bool,
    start: []usize,
    adjacent: []usize,
    seen: []bool,
    parent: []usize,
    depth: []usize,
    /// Per cell: its horizontal and vertical rail, if it lies on one.
    rail: [2][]usize,
    relations: std.ArrayList(Relation) = .empty,

    fn onRail(self: *const Tracer, v: usize) bool {
        return v < self.scan.cells and (self.rail[0][v] != none or self.rail[1][v] != none);
    }

    fn conduit(self: *const Tracer, u: usize, v: usize) bool {
        if (u >= self.scan.cells or v >= self.scan.cells) return false;
        for (self.rail) |r| if (r[u] != none and r[u] == r[v]) return true;
        return false;
    }

    fn owns(self: *const Tracer, m: *const Member, v: usize) bool {
        if (m.at.contains(v)) return true;
        if (v >= self.scan.cells) return false;
        for (self.rail) |r| if (r[v] != none and m.rails.contains(r[v])) return true;
        return false;
    }

    fn neighbours(self: *const Tracer, v: usize) []const usize {
        return self.adjacent[self.start[v]..self.start[v + 1]];
    }

    fn note(self: *Tracer, kind: grid.Finding.Kind, v: usize) !void {
        const cell = if (v >= self.scan.cells) self.scan.terminals[v - self.scan.cells].cell else v;
        try self.scan.findings.append(self.arena, .{ .kind = kind, .row = cell / self.scan.width, .col = cell % self.scan.width });
    }

    fn walk(self: *Tracer, root: usize) ![]usize {
        var order: std.ArrayList(usize) = .empty;
        try order.append(self.arena, root);
        self.seen[root] = true;
        self.parent[root] = none;
        self.depth[root] = 0;
        var i: usize = 0;
        while (i < order.items.len) : (i += 1) {
            const v = order.items[i];
            for (self.neighbours(v)) |w| {
                if (self.seen[w]) continue;
                self.seen[w] = true;
                self.parent[w] = v;
                self.depth[w] = self.depth[v] + 1;
                try order.append(self.arena, w);
            }
        }
        return order.items;
    }

    fn between(self: *const Tracer, p: usize, q: usize) ![]usize {
        var head: std.ArrayList(usize) = .empty;
        var tail: std.ArrayList(usize) = .empty;
        var a = p;
        var b = q;
        while (self.depth[a] > self.depth[b]) : (a = self.parent[a]) try head.append(self.arena, a);
        while (self.depth[b] > self.depth[a]) : (b = self.parent[b]) try tail.append(self.arena, b);
        while (a != b) : ({
            a = self.parent[a];
            b = self.parent[b];
        }) {
            try head.append(self.arena, a);
            try tail.append(self.arena, b);
        }
        try head.append(self.arena, a);
        std.mem.reverse(usize, tail.items);
        try head.appendSlice(self.arena, tail.items);
        return head.items;
    }

    fn stroke(self: *const Tracer, route: []const usize) Stroke {
        var out: Stroke = .any;
        for (route) |v| {
            if (v >= self.scan.cells) continue;
            const style: Stroke = switch (self.scan.styles[v]) {
                .neutral => continue,
                .solid => .solid,
                .dotted => .dotted,
                .thick => .thick,
            };
            out = if (out == .any or out == style) style else .mixed;
        }
        return out;
    }

    fn fits(self: *const Tracer, t: usize, e: Endpoint, end: grid.End) bool {
        const term = self.scan.terminals[t - self.scan.cells];
        const here = self.ends[t - self.scan.cells];
        return term.end == end and here.frame == e.frame and std.mem.eql(u8, here.label, e.label);
    }

    // Gives each declared edge the first ink path that can carry it: first
    // only paths no other edge holds, so parallel edges find their own ink,
    // then any path, so edges drawn as one line still count as drawn. Last,
    // a terminal still unclaimed carries any declared edge it fits, since a
    // second port drawn for the same edge asserts nothing new.
    fn attribute(self: *Tracer, parts: []Part) !void {
        for ([_]bool{ true, false }) |alone| {
            for (self.edges, 0..) |e, i| {
                if (self.attributed[i]) continue;
                for (parts) |*p| {
                    const m = try self.carrier(p, e, alone, null) orelse continue;
                    try p.members.append(self.arena, m);
                    self.attributed[i] = true;
                    break;
                }
            }
        }
        for (parts) |*p| for (p.terminals) |t| {
            for (p.members.items) |m| {
                if (m.ends[0] == t or m.ends[1] == t) break;
            } else for (self.edges) |e| {
                const m = try self.carrier(p, e, false, t) orelse continue;
                try p.members.append(self.arena, m);
                break;
            }
        };
    }

    // The shortest path for `e` between two fitting terminals, among equals
    // the one covering most ink no member covers yet. While `alone`, only
    // pairs no member holds.
    fn carrier(self: *Tracer, p: *const Part, e: Relation, alone: bool, through: ?usize) !?Member {
        var best: ?[]usize = null;
        var best_fresh: usize = 0;
        for (p.terminals) |x| for (p.terminals) |y| {
            if (x == y or !self.fits(x, e.a, e.end_a) or !self.fits(y, e.b, e.end_b)) continue;
            if (alone and held(p, x, y)) continue;
            if (through) |t| if (x != t and y != t) continue;
            const route = try self.between(x, y);
            const drawn = self.stroke(route);
            if (drawn != .any and drawn != e.stroke) continue;
            var fresh: usize = 0;
            for (route) |v| {
                for (p.members.items) |*m| {
                    if (self.owns(m, v)) break;
                } else fresh += 1;
            }
            const better = if (best) |b| route.len < b.len or (route.len == b.len and fresh > best_fresh) else true;
            if (better) {
                best = route;
                best_fresh = fresh;
            }
        };
        const route = best orelse return null;
        var m: Member = .{ .ends = .{ route[0], route[route.len - 1] }, .at = .empty, .one_way = null, .rails = .empty };
        for (route, 0..) |v, pos| {
            try m.at.put(self.arena, v, pos);
            if (v < self.scan.cells) for (self.rail) |r| if (r[v] != none) try m.rails.put(self.arena, r[v], {});
        }
        if (directional(e.end_a) != directional(e.end_b)) m.one_way = directional(e.end_b);
        return m;
    }

    // Whether members can carry a trace along `route` read in one sense.
    fn carried(self: *const Tracer, members: []const Member, route: []const usize, sense: bool) !bool {
        var live = try self.arena.alloc(bool, members.len);
        var next = try self.arena.alloc(bool, members.len);
        for (members, live) |m, *l| l.* = m.at.contains(route[0]);
        for (0..route.len - 1) |i| {
            const u = route[i];
            const v = route[i + 1];
            const junction = self.neighbours(u).len >= 3 or self.onRail(u);
            var any_live = false;
            for (live) |l| any_live = any_live or l;
            for (members, live, next) |*m, l, *n| {
                n.* = false;
                if (!l and !(junction and any_live and self.owns(m, u))) continue;
                if (!self.owns(m, v)) continue;
                if (!self.conduit(u, v)) if (m.one_way) |head_ahead| {
                    const pu = m.at.get(u) orelse continue;
                    const pv = m.at.get(v) orelse continue;
                    if ((pv > pu) != (head_ahead == sense)) continue;
                };
                n.* = true;
            }
            std.mem.swap([]bool, &live, &next);
        }
        for (live) |l| if (l) return true;
        return false;
    }

    fn piece(self: *Tracer, root: usize) !?Part {
        const order = try self.walk(root);
        var terminals: std.ArrayList(usize) = .empty;
        var links: usize = 0;
        for (order) |v| {
            links += self.neighbours(v).len;
            if (v >= self.scan.cells) try terminals.append(self.arena, v);
        }
        if (links / 2 >= order.len) {
            try self.note(.ink_cycle, root);
            return null;
        }
        if (terminals.items.len < 2) {
            try self.note(.loose_ink, root);
            return null;
        }
        return .{ .order = order, .terminals = terminals.items };
    }

    // Reads the relations one part asserts; one piece of ink asserts each
    // relation once, however many of a box's ports reach it.
    fn read(self: *Tracer, p: *const Part) !void {
        const members = p.members.items;
        const first = self.relations.items.len;
        for (p.order) |v| {
            if (v >= self.scan.cells) continue;
            for (members) |*m| {
                if (self.owns(m, v)) break;
            } else {
                try self.note(.unowned_ink, v);
                break;
            }
        }
        for (p.terminals, 0..) |x, i| for (p.terminals[i + 1 ..]) |y| {
            const route = try self.between(x, y);
            if (members.len > 0 and !try self.carried(members, route, true) and
                !try self.carried(members, route, false)) continue;
            const tx = self.scan.terminals[x - self.scan.cells];
            const ty = self.scan.terminals[y - self.scan.cells];
            const r: Relation = .{
                .a = self.ends[x - self.scan.cells],
                .end_a = tx.end,
                .b = self.ends[y - self.scan.cells],
                .end_b = ty.end,
                .stroke = self.stroke(route),
            };
            for (self.relations.items[first..]) |seen| {
                if (sameRelation(seen, r)) break;
            } else try self.relations.append(self.arena, r);
        };
    }
};

// One connected, loop-free piece of ink and the edges attributed to it.
const Part = struct {
    order: []const usize,
    terminals: []const usize,
    members: std.ArrayList(Member) = .empty,
};

fn sameRelation(a: Relation, b: Relation) bool {
    const same = struct {
        fn f(x: Endpoint, y: Endpoint) bool {
            return x.frame == y.frame and std.mem.eql(u8, x.label, y.label);
        }
    }.f;
    if (a.stroke != b.stroke) return false;
    return (same(a.a, b.a) and a.end_a == b.end_a and same(a.b, b.b) and a.end_b == b.end_b) or
        (same(a.a, b.b) and a.end_a == b.end_b and same(a.b, b.a) and a.end_b == b.end_a);
}

fn held(p: *const Part, x: usize, y: usize) bool {
    for (p.members.items) |m| {
        if ((m.ends[0] == x and m.ends[1] == y) or (m.ends[0] == y and m.ends[1] == x)) return true;
    }
    return false;
}

fn directional(end: grid.End) bool {
    return end == .filled or end == .open;
}

/// Traces every ink component. `ends` names each terminal's box or frame;
/// `edges` are the declared edges, named the same way.
pub fn trace(arena: std.mem.Allocator, scan: *grid.Scan, ends: []const Endpoint, edges: []const Relation) ![]const Relation {
    const n = scan.cells + scan.terminals.len;
    const degree = try arena.alloc(usize, n + 1);
    @memset(degree, 0);
    for (scan.links) |l| {
        degree[l[0]] += 1;
        degree[l[1]] += 1;
    }
    for (scan.terminals, 0..) |t, i| {
        degree[t.cell] += 1;
        degree[scan.cells + i] += 1;
    }
    const start = try arena.alloc(usize, n + 1);
    var sum: usize = 0;
    for (start, degree) |*s, d| {
        s.* = sum;
        sum += d;
    }
    const adjacent = try arena.alloc(usize, sum);
    @memset(degree, 0);
    var pairs: std.ArrayList([2]usize) = .empty;
    try pairs.appendSlice(arena, scan.links);
    for (scan.terminals, 0..) |t, i| try pairs.append(arena, .{ t.cell, scan.cells + i });
    for (pairs.items) |l| {
        adjacent[start[l[0]] + degree[l[0]]] = l[1];
        degree[l[0]] += 1;
        adjacent[start[l[1]] + degree[l[1]]] = l[0];
        degree[l[1]] += 1;
    }
    var t: Tracer = .{
        .arena = arena,
        .scan = scan,
        .ends = ends,
        .edges = edges,
        .attributed = try arena.alloc(bool, edges.len),
        .start = start,
        .adjacent = adjacent,
        .seen = try arena.alloc(bool, n),
        .parent = try arena.alloc(usize, n),
        .depth = try arena.alloc(usize, n),
        .rail = undefined,
    };
    @memset(t.attributed, false);
    @memset(t.seen, false);
    for (0..2) |axis| t.rail[axis] = try rails(arena, scan, start, axis == 1);
    var parts: std.ArrayList(Part) = .empty;
    for (0..scan.terminals.len) |i| {
        if (t.seen[scan.cells + i]) continue;
        if (try t.piece(scan.cells + i)) |p| try parts.append(arena, p);
    }
    try t.attribute(parts.items);
    for (parts.items) |*p| try t.read(p);
    for (scan.links) |l| {
        if (t.seen[l[0]]) continue;
        _ = try t.walk(l[0]);
        try t.note(.loose_ink, l[0]);
    }
    return t.relations.items;
}

// Labels each cell with the straight run it lies on along one axis, keeping
// only runs that hold two or more junctions.
fn rails(arena: std.mem.Allocator, scan: *const grid.Scan, start: []const usize, vertical: bool) ![]usize {
    const root = try arena.alloc(usize, scan.cells);
    for (root, 0..) |*r, i| r.* = i;
    const find = struct {
        fn f(r: []usize, x: usize) usize {
            var y = x;
            while (r[y] != y) y = r[y];
            return y;
        }
    }.f;
    for (scan.links) |l| {
        const same_row = l[0] / scan.width == l[1] / scan.width;
        const same_col = l[0] % scan.width == l[1] % scan.width;
        if (if (vertical) !same_col else !same_row) continue;
        root[find(root, l[1])] = find(root, l[0]);
    }
    const junctions = try arena.alloc(usize, scan.cells);
    @memset(junctions, 0);
    for (0..scan.cells) |v| {
        if (start[v + 1] - start[v] >= 3) junctions[find(root, v)] += 1;
    }
    const out = try arena.alloc(usize, scan.cells);
    for (out, 0..) |*o, v| {
        const r = find(root, v);
        o.* = if (junctions[r] >= 2) r else none;
    }
    return out;
}
