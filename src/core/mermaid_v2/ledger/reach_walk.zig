//! reach_walk.zig — admissible-walk reachability for the vector-half
//! D-REACH oracle. Split sibling of `reach_vector.zig` for the 500-line
//! cap, mirroring reach_geometry/reach_report.
//!
//! Implements the trace model's two traversal axioms over one connectivity
//! component: a trace follows connected ink (4-adjacent cells of one
//! channel), and direction consistency — one traced path asserts one
//! orientation, so a walk that runs WITH one directional end and AGAINST
//! another is inadmissible. Junction traversal falls out of the geometry:
//! stepping onto a member's drop or stem walks that member's oriented
//! path, so the member's decoration binds the trace wherever its glyph
//! physically sits. Box termination needs no rule here — a node box is no
//! unit's cell, so no walk enters one.
//!
//! The rule the walk replaces (every source terminal reaches every target
//! terminal of its component) coincides with this one for a single-pivot
//! star and for a complete two-sided fusion, and diverges exactly when two
//! rails meet through an edge that is a member at both ends — where the
//! old rule fabricated the leaf-to-leaf pairs the members' heads block.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, base/ledger,
//! sketch, reach_geometry.

const std = @import("std");
const sk = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const geom = @import("reach_geometry.zig");

pub const Error = error{OutOfMemory};

/// A typed terminal of the component: the node it belongs to and the
/// cell where its edge's ink meets the node.
pub const Terminal = struct { node: sk.NodeId, cell: geom.Cell };

/// Orientation a walk has committed to so far. `both` is the dead state:
/// the permitted sets of two decorations it passed are disjoint.
const Committed = enum(u2) { open = 0, with = 1, against = 2, both = 3 };

fn commit(state: Committed, head: geom.Head) Committed {
    return switch (head) {
        .none => state,
        .with => if (state == .against) .both else .with,
        .against => if (state == .with) .both else .against,
    };
}

const Step = struct { from: geom.Cell, to: geom.Cell };

/// Bit set of the heads a directed step may assert: a step lying on
/// several units' paths offers every reading, and the walk branches.
const Offers = struct {
    none: bool = false,
    with: bool = false,
    against: bool = false,

    fn add(self: *Offers, head: geom.Head) void {
        switch (head) {
            .none => self.none = true,
            .with => self.with = true,
            .against => self.against = true,
        }
    }
};

fn flip(head: geom.Head) geom.Head {
    return switch (head) {
        .none => .none,
        .with => .against,
        .against => .with,
    };
}

const StepMap = std.AutoArrayHashMapUnmanaged(Step, Offers);

fn offer(alloc: std.mem.Allocator, steps: *StepMap, from: geom.Cell, to: geom.Cell, head: geom.Head) Error!void {
    const gop = try steps.getOrPut(alloc, .{ .from = from, .to = to });
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.add(head);
}

/// Every directed step along the channel's oriented paths, both ways: the
/// stated direction asserts the path's head, the reverse asserts its flip.
fn stepMap(alloc: std.mem.Allocator, units: []const geom.Unit) Error!StepMap {
    var steps: StepMap = .empty;
    for (units) |u| for (u.paths) |path| {
        if (path.cells.len < 2) continue;
        for (path.cells[1..], 0..) |b, i| {
            const a = path.cells[i];
            try offer(alloc, &steps, a, b, path.head);
            try offer(alloc, &steps, b, a, flip(path.head));
        }
    };
    return steps;
}

const Visit = struct { cell: usize, state: Committed };

/// Pairs (source node, target node) joined by an admissible walk inside
/// one component. `units` are the component's channel units; `cells` its
/// cells (deduplicated). A step between two adjacent component cells that
/// lies on no path is a junction contact and asserts nothing.
pub fn reachablePairs(
    alloc: std.mem.Allocator,
    units: []const geom.Unit,
    cells: []const geom.Cell,
    sources: []const Terminal,
    targets: []const Terminal,
) Error![]const pb.NodePair {
    var index: std.AutoArrayHashMapUnmanaged(geom.Cell, usize) = .empty;
    defer index.deinit(alloc);
    for (cells, 0..) |c, i| try index.put(alloc, c, i);
    var steps = try stepMap(alloc, units);
    defer steps.deinit(alloc);

    const seen = try alloc.alloc([3]bool, cells.len);
    defer alloc.free(seen);
    var stack: std.ArrayListUnmanaged(Visit) = .empty;
    defer stack.deinit(alloc);
    var pairs: std.ArrayListUnmanaged(pb.NodePair) = .empty;

    for (sources) |src| {
        const start = index.get(src.cell) orelse continue;
        @memset(seen, .{ false, false, false });
        stack.clearRetainingCapacity();
        seen[start][0] = true;
        try stack.append(alloc, .{ .cell = start, .state = .open });
        while (stack.pop()) |v| {
            const c = cells[v.cell];
            const neighbours = [4]geom.Cell{
                .{ .x = c.x + 1, .y = c.y }, .{ .x = c.x - 1, .y = c.y },
                .{ .x = c.x, .y = c.y + 1 }, .{ .x = c.x, .y = c.y - 1 },
            };
            for (neighbours) |n| {
                const ni = index.get(n) orelse continue;
                const offers = steps.get(.{ .from = c, .to = n }) orelse Offers{ .none = true };
                const heads = [3]?geom.Head{
                    if (offers.none) .none else null,
                    if (offers.with) .with else null,
                    if (offers.against) .against else null,
                };
                for (heads) |maybe| {
                    const head = maybe orelse continue;
                    const next = commit(v.state, head);
                    if (next == .both) continue;
                    const slot = @intFromEnum(next);
                    if (seen[ni][slot]) continue;
                    seen[ni][slot] = true;
                    try stack.append(alloc, .{ .cell = ni, .state = next });
                }
            }
        }
        for (targets) |tgt| {
            const ti = index.get(tgt.cell) orelse continue;
            if (!(seen[ti][0] or seen[ti][1] or seen[ti][2])) continue;
            try appendPair(alloc, &pairs, .{ .source = src.node, .target = tgt.node });
        }
    }
    return pairs.toOwnedSlice(alloc);
}

fn appendPair(alloc: std.mem.Allocator, pairs: *std.ArrayListUnmanaged(pb.NodePair), p: pb.NodePair) Error!void {
    for (pairs.items) |q| if (q.source == p.source and q.target == p.target) return;
    try pairs.append(alloc, p);
}

test "a walk that runs with one head and against another is dead" {
    try std.testing.expectEqual(Committed.both, commit(commit(.open, .with), .against));
    try std.testing.expectEqual(Committed.with, commit(commit(.open, .with), .none));
    try std.testing.expectEqual(Committed.against, commit(.open, .against));
}

test {
    std.testing.refAllDecls(@This());
}
