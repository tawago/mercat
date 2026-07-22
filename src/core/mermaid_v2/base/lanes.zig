//! Pure interval "lane" packer shared by the layout zone (back-edge rails,
//! chain_wrap gutter negotiation) and the cluster zone (cross-border bridge
//! track discipline). `Demand` is a flow-axis interval `[lo, hi]` plus a
//! natural (unstacked) cross-axis `base`; `assign` greedily packs demands
//! into the innermost compatible lane and resolves each lane's physical
//! cross position; `gutter` reports the resulting shape without committing
//! placements. No geometry/placement/sketch types: pure integers in/out.
//! Importable from every zone; may itself import only std (and prim) —
//! enforced by tools/lint_imports.zig.

const std = @import("std");

/// One request for gutter space: a run that occupies the flow-axis interval
/// `[lo, hi]` (inclusive, e.g. a back-edge's spanned layer range) and would
/// naturally sit at cross position `base` (no stacking applied yet).
pub const Demand = struct {
    lo: u32,
    hi: u32,
    base: i32,
};

/// Result of `assign`: which lane each demand landed in, and where each lane
/// physically sits on the cross axis.
pub const Assignment = struct {
    /// Parallel to the input demands: `lane_of[i]` is the lane index that
    /// `demands[i]` was packed into (0 = innermost).
    lane_of: []u32,
    /// Resolved cross position per lane, innermost first.
    lane_pos: []i32,

    /// Resolved cross position for the `i`-th input demand.
    pub fn posOf(self: Assignment, i: usize) i32 {
        return self.lane_pos[self.lane_of[i]];
    }

    pub fn deinit(self: *Assignment, a: std.mem.Allocator) void {
        a.free(self.lane_of);
        a.free(self.lane_pos);
    }
};

/// True iff demand `d` overlaps any lane member's flow interval. Overlapping
/// intervals cannot share a lane (their runs would coexist on shared flow
/// rows/columns and merge into one line).
fn overlapsAny(demands: []const Demand, members: []const u32, d: Demand) bool {
    for (members) |mi| {
        const m = demands[mi];
        if (!(d.hi < m.lo or d.lo > m.hi)) return true;
    }
    return false;
}

/// Greedy lane assignment over `demands` IN THE GIVEN ORDER (callers that
/// want span-ascending packing must pre-sort; the order is part of the
/// packing's tie-break contract).
///
/// A "lane" is a shared cross position occupied by one or more demands whose
/// flow intervals are mutually disjoint — their runs never coexist on the
/// same flow row/column, so they can safely share without merging. Each
/// demand picks the innermost (smallest-index) lane it fits in; if it
/// overlaps a member of every existing lane, a new outer lane is created.
///
/// A lane's physical position is the max of its members' `base`s, floored to
/// sit at least `stack_gap` outside the previous (inner) lane so adjacent
/// lanes' runs stay visually distinct.
pub fn assign(
    a: std.mem.Allocator,
    demands: []const Demand,
    stack_gap: i32,
) error{OutOfMemory}!Assignment {
    const lane_of = try a.alloc(u32, demands.len);
    errdefer a.free(lane_of);

    const Lane = struct {
        members: std.ArrayListUnmanaged(u32),
        max_base: i32,
    };
    var lanes_buf: std.ArrayListUnmanaged(Lane) = .empty;
    defer {
        for (lanes_buf.items) |*ln| ln.members.deinit(a);
        lanes_buf.deinit(a);
    }

    for (demands, 0..) |d, i| {
        var chosen: ?usize = null;
        for (lanes_buf.items, 0..) |ln, li| {
            if (!overlapsAny(demands, ln.members.items, d)) {
                chosen = li;
                break;
            }
        }
        const li = chosen orelse blk: {
            // minInt sentinel: the first member's base always takes (bases
            // may legitimately be negative, e.g. bridge outward units).
            try lanes_buf.append(a, .{ .members = .empty, .max_base = std.math.minInt(i32) });
            break :blk lanes_buf.items.len - 1;
        };
        var ln = &lanes_buf.items[li];
        try ln.members.append(a, @intCast(i));
        if (d.base > ln.max_base) ln.max_base = d.base;
        lane_of[i] = @intCast(li);
    }

    const lane_pos = try a.alloc(i32, lanes_buf.items.len);
    errdefer a.free(lane_pos);
    var prev_pos: i32 = std.math.minInt(i32);
    for (lanes_buf.items, 0..) |ln, li| {
        var pos = ln.max_base;
        if (prev_pos != std.math.minInt(i32) and pos <= prev_pos) {
            pos = prev_pos + stack_gap;
        }
        prev_pos = pos;
        lane_pos[li] = pos;
    }

    return .{ .lane_of = lane_of, .lane_pos = lane_pos };
}

/// Shape of the gutter that a set of demands would produce.
pub const Gutter = struct {
    /// Number of parallel lanes required.
    lanes: u32,
    /// Resolved cross position of the outermost lane (0 when no demands).
    outermost: i32,
};

/// Pure query: pack `demands` and report the resulting gutter shape WITHOUT
/// committing any placements ("given these back-edge spans crossing a band
/// boundary, what gutter width results?").
pub fn gutter(
    a: std.mem.Allocator,
    demands: []const Demand,
    stack_gap: i32,
) error{OutOfMemory}!Gutter {
    var asg = try assign(a, demands, stack_gap);
    defer asg.deinit(a);
    return .{
        .lanes = @intCast(asg.lane_pos.len),
        .outermost = if (asg.lane_pos.len == 0) 0 else asg.lane_pos[asg.lane_pos.len - 1],
    };
}
