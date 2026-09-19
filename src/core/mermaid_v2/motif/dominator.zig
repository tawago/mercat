const std = @import("std");

pub const ROOT: u32 = std.math.maxInt(u32);

pub const DomTree = struct {
    idom: []const u32,
    children: []const []const u32,
    roots: []const u32,
};

pub fn compute(
    a: std.mem.Allocator,
    n: usize,
    edges_in: []const [2]u32,
) error{OutOfMemory}!DomTree {
    if (n == 0) return .{ .idom = &.{}, .children = &.{}, .roots = &.{} };

    const edges = try a.dupe([2]u32, edges_in);
    try reverseBackEdges(a, n, edges);

    const r: u32 = @intCast(n);
    var succ = try a.alloc(std.ArrayListUnmanaged(u32), n + 1);
    var pred = try a.alloc(std.ArrayListUnmanaged(u32), n + 1);
    for (succ) |*l| l.* = .empty;
    for (pred) |*l| l.* = .empty;

    const indeg = try a.alloc(u32, n);
    @memset(indeg, 0);
    for (edges) |e| {
        try succ[e[0]].append(a, e[1]);
        try pred[e[1]].append(a, e[0]);
        indeg[e[1]] += 1;
    }
    for (0..n) |v| {
        if (indeg[v] == 0) {
            try succ[r].append(a, @intCast(v));
            try pred[v].append(a, r);
        }
    }
    {
        const seen = try a.alloc(bool, n + 1);
        var progress = true;
        while (progress) {
            progress = false;
            @memset(seen, false);
            try dfsMark(a, succ, r, seen);
            for (0..n) |v| {
                if (!seen[v]) {
                    try succ[r].append(a, @intCast(v));
                    try pred[v].append(a, r);
                    progress = true;
                    break;
                }
            }
        }
    }

    const rpo = try reversePostOrder(a, succ, n, r);
    const rpo_pos = try a.alloc(u32, n + 1);
    for (rpo, 0..) |v, i| rpo_pos[v] = @intCast(i);

    const UNSET: u32 = std.math.maxInt(u32) - 1;
    const idom = try a.alloc(u32, n + 1);
    @memset(idom, UNSET);
    idom[r] = r;

    var changed = true;
    while (changed) {
        changed = false;
        for (rpo) |v| {
            if (v == r) continue;
            var new_idom: u32 = UNSET;
            for (pred[v].items) |p| {
                if (idom[p] == UNSET) continue;
                new_idom = if (new_idom == UNSET)
                    p
                else
                    intersect(idom, rpo_pos, p, new_idom);
            }
            if (new_idom != UNSET and idom[v] != new_idom) {
                idom[v] = new_idom;
                changed = true;
            }
        }
    }

    const out_idom = try a.alloc(u32, n);
    for (0..n) |v| out_idom[v] = if (idom[v] == r) ROOT else idom[v];

    var kids = try a.alloc(std.ArrayListUnmanaged(u32), n);
    for (kids) |*l| l.* = .empty;
    var roots: std.ArrayListUnmanaged(u32) = .empty;
    for (0..n) |v| {
        if (out_idom[v] == ROOT) {
            try roots.append(a, @intCast(v));
        } else {
            try kids[out_idom[v]].append(a, @intCast(v));
        }
    }
    const children = try a.alloc([]const u32, n);
    for (0..n) |v| children[v] = try kids[v].toOwnedSlice(a);

    return .{
        .idom = out_idom,
        .children = children,
        .roots = try roots.toOwnedSlice(a),
    };
}

fn intersect(idom: []const u32, rpo_pos: []const u32, x: u32, y: u32) u32 {
    var f1 = x;
    var f2 = y;
    while (f1 != f2) {
        while (rpo_pos[f1] > rpo_pos[f2]) f1 = idom[f1];
        while (rpo_pos[f2] > rpo_pos[f1]) f2 = idom[f2];
    }
    return f1;
}

fn reverseBackEdges(
    a: std.mem.Allocator,
    n: usize,
    edges: [][2]u32,
) error{OutOfMemory}!void {
    const Color = enum(u2) { white, gray, black };
    const color = try a.alloc(Color, n);
    @memset(color, .white);

    var out = try a.alloc(std.ArrayListUnmanaged(u32), n);
    for (out) |*l| l.* = .empty;
    for (edges, 0..) |e, i| try out[e[0]].append(a, @intCast(i));

    const reversed = try a.alloc(bool, edges.len);
    @memset(reversed, false);

    var stack: std.ArrayListUnmanaged(struct { v: u32, cursor: u32 }) = .empty;
    for (0..n) |seed| {
        if (color[seed] != .white) continue;
        color[seed] = .gray;
        stack.clearRetainingCapacity();
        try stack.append(a, .{ .v = @intCast(seed), .cursor = 0 });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const outs = out[top.v].items;
            if (top.cursor >= outs.len) {
                color[top.v] = .black;
                _ = stack.pop();
                continue;
            }
            const ei = outs[top.cursor];
            top.cursor += 1;
            const target = edges[ei][1];
            switch (color[target]) {
                .gray => reversed[ei] = true,
                .white => {
                    color[target] = .gray;
                    try stack.append(a, .{ .v = target, .cursor = 0 });
                },
                .black => {},
            }
        }
    }
    for (edges, 0..) |*e, i| {
        if (reversed[i]) e.* = .{ e.*[1], e.*[0] };
    }
}

fn dfsMark(
    a: std.mem.Allocator,
    succ: []const std.ArrayListUnmanaged(u32),
    start: u32,
    seen: []bool,
) error{OutOfMemory}!void {
    var stack: std.ArrayListUnmanaged(u32) = .empty;
    try stack.append(a, start);
    seen[start] = true;
    while (stack.pop()) |v| {
        for (succ[v].items) |w| {
            if (!seen[w]) {
                seen[w] = true;
                try stack.append(a, w);
            }
        }
    }
}

fn reversePostOrder(
    a: std.mem.Allocator,
    succ: []const std.ArrayListUnmanaged(u32),
    n: usize,
    r: u32,
) error{OutOfMemory}![]u32 {
    var post: std.ArrayListUnmanaged(u32) = .empty;
    const seen = try a.alloc(bool, n + 1);
    @memset(seen, false);
    var stack: std.ArrayListUnmanaged(struct { v: u32, cursor: u32 }) = .empty;
    try stack.append(a, .{ .v = r, .cursor = 0 });
    seen[r] = true;
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        const outs = succ[top.v].items;
        if (top.cursor >= outs.len) {
            try post.append(a, top.v);
            _ = stack.pop();
            continue;
        }
        const w = outs[top.cursor];
        top.cursor += 1;
        if (!seen[w]) {
            seen[w] = true;
            try stack.append(a, .{ .v = w, .cursor = 0 });
        }
    }
    std.mem.reverse(u32, post.items);
    return try post.toOwnedSlice(a);
}
