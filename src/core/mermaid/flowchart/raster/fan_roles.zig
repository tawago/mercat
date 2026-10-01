const ledger = @import("../base/ledger.zig");
const rail_star = @import("../base/rail_star.zig");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const geo = @import("geometry.zig");

/// The shared-run role a fan stroke of `role` belongs to, or null outside a fan.
fn railRole(role: lattice.EdgeRole) ?lattice.EdgeRole {
    return switch (role) {
        .fan_out_rail, .fan_out_dropper => .fan_out_rail,
        .fan_in_rail, .fan_in_dropper => .fan_in_rail,
        else => null,
    };
}

pub fn markShared(cell: *lattice.Cell, edge_id: u32, role: lattice.EdgeRole) void {
    const rail = railRole(role) orelse return;
    const seg = switch (cell.occupant) {
        .edge_segment => |s| s,
        else => return,
    };
    if (seg.edge == edge_id or railRole(seg.role) != rail) return;
    cell.occupant = .{ .edge_segment = .{ .edge = seg.edge, .kind = seg.kind, .role = rail } };
}

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
            const rect = pivotRect(s, s.rail_claims, seg.edge) orelse continue;
            const drop = armAwayFromPivot(rect, y) orelse continue;
            if (armIsAnswered(lat, x, y, drop)) continue;
            cell.neighbours = lattice.Neighbours.fromMask(nb.toMask() & ~geo.bitMask(drop).toMask());
        }
    }
}

fn armAwayFromPivot(rect: sketch.Rect, y: u32) ?lattice.Dir4 {
    const row: i32 = @intCast(y);
    if (rect.bottom() <= row) return .south;
    if (rect.y > row) return .north;
    return null;
}

fn continuesColumn(lat: *const lattice.Lattice, x: u32, y: u32) bool {
    for ([_]i32{ -1, 1 }) |dy| {
        const c = geo.cellAt(lat, @intCast(x), @as(i32, @intCast(y)) + dy) orelse continue;
        const seg = switch (c.occupant) {
            .edge_segment => |q| q,
            else => continue,
        };
        if (railRole(seg.role) == null) continue;
        if (!(c.neighbours.e or c.neighbours.w)) continue;
        return true;
    }
    return false;
}

fn armIsAnswered(lat: *const lattice.Lattice, x: u32, y: u32, d: lattice.Dir4) bool {
    const dy: i32 = switch (d) {
        .north => -1,
        .south => 1,
        .east, .west => return false,
    };
    const c = geo.cellAt(lat, @intCast(x), @as(i32, @intCast(y)) + dy) orelse return false;
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

fn pivotRect(s: sketch.Sketch, claims: []const rail_star.RailClaim, edge_id: u32) ?sketch.Rect {
    const pivot = pivotOf(claims, edge_id) orelse return null;
    for (s.nodes) |np| {
        if (np.id == pivot) return np.rect;
    }
    return null;
}

fn pivotOf(claims: []const rail_star.RailClaim, edge_id: u32) ?ledger.NodeId {
    var found: ?ledger.NodeId = null;
    for (claims) |claim| {
        if (claim.polarity != .out or !claimHasEdge(claim, edge_id)) continue;
        const checked = rail_star.check(claim);
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

fn claimHasEdge(claim: rail_star.RailClaim, edge_id: u32) bool {
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
            if (geo.onSegment(rail.stem[i], rail.stem[i + 1], px, py)) return true;
        }
    }
    return false;
}

test {
    _ = @import("fan_roles_test.zig");
}
