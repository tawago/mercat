const ledger = @import("../base/ledger.zig");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ew = @import("edges_write.zig");
const aux = @import("aux.zig");

fn railRole(p: lattice.RailPolarity) lattice.EdgeRole {
    return switch (p) {
        .out => .fan_out_rail,
        .in => .fan_in_rail,
    };
}

/// @guarded-by: fan_roles_test.zig "a second rider stamps the family rail role; a lone rider leaves the dropper"
pub fn markShared(
    rec: aux.Recorder,
    cell: *lattice.Cell,
    x: u32,
    y: u32,
    edge_id: u32,
    role: lattice.EdgeRole,
) void {
    const polarity = ew.railPolarity(role) orelse return;
    const named: u32 = switch (cell.occupant) {
        .edge_segment => |seg| seg.edge,
        .arrowhead => |head| head.edge,
        else => return,
    };
    if (named == edge_id) return;
    ew.recordRailMember(rec, x, y, edge_id, polarity);
    const seg = switch (cell.occupant) {
        .edge_segment => |s| s,
        else => return,
    };
    if (ew.railPolarity(seg.role) != polarity) return;
    cell.occupant = .{ .edge_segment = .{
        .edge = seg.edge,
        .kind = seg.kind,
        .role = railRole(polarity),
    } };
}

/// @guarded-by: fan_roles_test.zig "a shared run below its pivot keeps N and drops the child's descent"
/// @guarded-by: fan_roles_test.zig "the arm an arrowhead stands on is never the spurious one"
/// @guarded-by: fan_roles_test.zig "an arm a stroke answers back is left for nobody to strip"
/// @guarded-by: fan_roles_test.zig "under LR/RL the vertical is the rail itself, so nothing is stripped"
pub fn resolveMasks(lat: *lattice.Lattice, s: sketch.Sketch) void {
    if (lat.width == 0 or lat.height == 0) return;
    switch (s.direction) {
        .TD, .BT => {},
        .LR, .RL => return,
    }
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.at(x, y);
            const seg = switch (cell.occupant) {
                .edge_segment => |q| q,
                else => continue,
            };
            if (seg.role != .fan_out_rail) continue;
            const nb = cell.neighbours;
            if (!(nb.n and nb.s)) continue;
            if (!(nb.e or nb.w)) continue;
            if (onRail(s, x, y)) continue;
            if (continuesColumn(lat, x, y)) continue;
            const rect = pivotRect(s, lat.rail_claims, seg.edge, .out) orelse continue;
            const side = pivotSide(rect, y) orelse continue;
            const drop: lattice.Dir4 = switch (side) {
                .north => .south,
                .south => .north,
            };
            if (armIsAnswered(lat, x, y, drop)) continue;
            var m = nb;
            switch (drop) {
                .south => m.s = false,
                .north => m.n = false,
                else => unreachable,
            }
            cell.neighbours = m;
        }
    }
}

fn pivotSide(rect: sketch.Rect, y: u32) ?enum { north, south } {
    const row: i32 = @intCast(y);
    if (rect.bottom() <= row) return .north;
    if (rect.y > row) return .south;
    return null;
}

/// @guarded-by: fan_roles_test.zig "a grid rail keeps the rail-to-rail vertical (┼ over ┼)"
/// @guarded-by: fan_roles_test.zig "a fan-IN rail row one cell away reprieves the fan-OUT junction too"
fn continuesColumn(lat: *const lattice.Lattice, x: u32, y: u32) bool {
    for ([_]i64{ -1, 1 }) |dy| {
        const yi: i64 = @as(i64, y) + dy;
        if (yi < 0 or yi >= @as(i64, @intCast(lat.height))) continue;
        const c = lat.atConst(x, @intCast(yi));
        const seg = switch (c.occupant) {
            .edge_segment => |q| q,
            else => continue,
        };
        if (ew.railPolarity(seg.role) == null) continue;
        if (!(c.neighbours.e or c.neighbours.w)) continue;
        return true;
    }
    return false;
}

/// @guarded-by: fan_roles_test.zig "the arm an arrowhead stands on is never the spurious one"
/// @guarded-by: fan_roles_test.zig "an arm a stroke answers back is left for nobody to strip"
fn armIsAnswered(lat: *const lattice.Lattice, x: u32, y: u32, d: lattice.Dir4) bool {
    const dy: i64 = switch (d) {
        .north => -1,
        .south => 1,
        .east, .west => return false,
    };
    const yi: i64 = @as(i64, y) + dy;
    if (yi < 0 or yi >= @as(i64, @intCast(lat.height))) return false;
    const c = lat.atConst(x, @intCast(yi));
    return switch (c.occupant) {
        .arrowhead => |head| head.dir == d,
        .edge_segment => switch (d) {
            .north => c.neighbours.s,
            .south => c.neighbours.n,
            .east, .west => false,
        },
        else => false,
    };
}

fn pivotRect(s: sketch.Sketch, claims: []const ledger.RailClaim, edge_id: u32, p: lattice.RailPolarity) ?sketch.Rect {
    const pivot = pivotOf(claims, edge_id, p) orelse return null;
    for (s.nodes) |np| {
        if (np.id == pivot) return np.rect;
    }
    return null;
}

fn pivotOf(claims: []const ledger.RailClaim, edge_id: u32, p: lattice.RailPolarity) ?ledger.NodeId {
    var found: ?ledger.NodeId = null;
    for (claims) |claim| {
        const same_polarity = switch (p) {
            .out => claim.polarity == .out,
            .in => claim.polarity == .in,
        };
        if (!same_polarity or !claimHasEdge(claim, edge_id)) continue;
        const checked = ledger.checkRailClaim(claim);
        if (checked.star_law.wrong_polarity_end) return null;
        const pivot = checked.derived_pivot orelse return null;
        if (found) |prior| {
            if (prior != pivot) return null;
        } else {
            found = pivot;
        }
    }
    return found;
}

fn claimHasEdge(claim: ledger.RailClaim, edge_id: u32) bool {
    for (claim.members) |member| if (member.edge == edge_id) return true;
    return false;
}

fn onRail(s: sketch.Sketch, x: u32, y: u32) bool {
    const px: i32 = @intCast(x);
    const py: i32 = @intCast(y);
    for (s.rails) |rail| {
        if (py == rail.crossbar[0].y and px >= rail.crossbar[0].x and px <= rail.crossbar[1].x) return true;
        var i: usize = 0;
        while (i + 1 < rail.stem.len) : (i += 1) {
            if (onSegment(rail.stem[i], rail.stem[i + 1], px, py)) return true;
        }
    }
    return false;
}

fn onSegment(a: sketch.Point, b: sketch.Point, x: i32, y: i32) bool {
    if (a.x == b.x and a.x == x) return y >= @min(a.y, b.y) and y <= @max(a.y, b.y);
    if (a.y == b.y and a.y == y) return x >= @min(a.x, b.x) and x <= @max(a.x, b.x);
    return false;
}

test {
    _ = @import("fan_roles_test.zig");
}
