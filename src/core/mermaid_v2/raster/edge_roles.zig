//! Edge-role plumbing for `raster/edges.zig`: trunk-cell role-merge
//! precedence and the post-walk pass that upgrades fan rails into fan
//! trunks. Split out to keep `edges.zig` under the 500-line cap.
//!
//! `sketch.EdgeRole` and `lattice.EdgeRole` are the same type
//! (`prim.EdgeRole`), so no cross-layer mapping is needed here.
//!
//! Allowed imports: `std`, `lattice.zig`
//! (enforced by `tools/lint_imports.zig`).

const std = @import("std");
const lattice = @import("../lattice.zig");

/// Choose the surviving role when a cell already has a role and a new
/// writer arrives. Precedence (highest first):
///   fan_out_trunk, fan_in_trunk  > fan_out_rail, fan_in_rail
///   > back_edge, self_loop, cluster_internal  > forward.
/// Ties: prefer the existing role (first-writer-wins for same tier).
pub fn mergeRole(existing: lattice.EdgeRole, incoming: lattice.EdgeRole) lattice.EdgeRole {
    if (priority(incoming) > priority(existing)) return incoming;
    return existing;
}

fn priority(r: lattice.EdgeRole) u8 {
    return switch (r) {
        .fan_out_trunk, .fan_in_trunk => 3,
        .fan_out_rail, .fan_in_rail => 2,
        .back_edge, .self_loop, .cluster_internal => 1,
        .forward => 0,
    };
}

/// After all polylines are written, locate fan-OUT / fan-IN trunk cells
/// and stamp them with the higher-priority trunk role. Layout placed
/// these cells deliberately (per-child polylines all pass through
/// `(source.mid_x, rail_y)` for fan-OUT or `(target.mid_x, rail_y)` for
/// fan-IN); we recognise them as the unique cells whose existing role
/// is fan_out_rail / fan_in_rail AND whose neighbour mask contains both
/// vertical and horizontal bits (the OR-merge of a "straight vertical"
/// segment and a "corner" segment from a sibling).
///
/// SCOPE: single-row fan-OUT no longer reaches
/// this pass — it is painted as a first-class bus-bar with explicit
/// junction bits (`raster/busbars.zig`; trunk cells arrive already
/// role-stamped `fan_out_trunk`, which this scan skips). The remaining
/// producers of `fan_out_rail` merges are GRID-wrapped fan-OUT (rows > 1)
/// and declined fans (mixed stroke kind / source-side arrows); fan-IN is
/// unchanged. Delete the fan-OUT branch here once those follow-ups move
/// to bus-bars too.
///
/// For fan-OUT trunks we additionally strip the "spurious" vertical bit
/// contributed by the center child's straight descent: the source side
/// always keeps its bit; the opposite vertical bit (which would force
/// `┼`) is dropped so the painter resolves to `┴`/`┬`. Fan-IN trunks
/// keep all four bits so the painter renders `┼`.
pub fn stampFanTrunks(lat: *lattice.Lattice) void {
    if (lat.width == 0 or lat.height == 0) return;
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.at(x, y);
            const seg = switch (cell.occupant) {
                .edge_segment => |s| s,
                else => continue,
            };
            const has_v = cell.neighbours.n or cell.neighbours.s;
            const has_h = cell.neighbours.e or cell.neighbours.w;
            if (!has_v or !has_h) continue;
            const new_role: lattice.EdgeRole = switch (seg.role) {
                .fan_out_rail => .fan_out_trunk,
                .fan_in_rail => .fan_in_trunk,
                else => continue,
            };
            cell.occupant = .{ .edge_segment = .{
                .edge = seg.edge,
                .kind = seg.kind,
                .role = new_role,
            } };
            if (new_role == .fan_out_trunk and cell.neighbours.n and cell.neighbours.s and
                !railJunctionAdjacent(lat, x, y, .north) and !railJunctionAdjacent(lat, x, y, .south))
            {
                // Guard (before the strip): a GRID-wrapped fan-OUT (rows > 1)
                // threads its trunk THROUGH a second rail row — the vertical
                // arm joining rail-row K to rail-row K+1 is a real trunk
                // continuation, not a spurious center-child descent. When a
                // vertical neighbour is itself a fan rail junction (carries a
                // horizontal bit on this column), the `┼` is correct and must
                // survive; only single-row/declined fans fall through to the
                // ┴/┬ strip below. // guarded-by: edge_roles_test.zig "grid trunk keeps the rail-to-rail vertical (┼ over ┼)"
                //
                // A rail END has exactly one horizontal arm (it is the
                // left/right terminus of the fan rail). Only at a rail
                // end does a child terminal (▼) directly below mean this
                // cell owns the dropper, so its south arm is real and
                // must survive (└ → ├ / ┘ → ┤). At an INTERIOR junction
                // (both E and W present) an aligned arrowhead belongs to
                // an offset target column, not this stub, so it must not
                // suppress the ┴/┬ strip.
                const rail_end = cell.neighbours.e != cell.neighbours.w;
                const above = sourceReachable(lat, x, y, -1, 3, rail_end);
                const below = sourceReachable(lat, x, y, 1, 3, rail_end);
                var nb = cell.neighbours;
                if (above and !below) nb.s = false;
                if (below and !above) nb.n = false;
                cell.neighbours = nb;
            }
        }
    }
}

/// Walk vertically from `(x, y)` in `step_dy` (±1) up to `max_steps`,
/// passing through pure-vertical edge_segment cells, and report whether
/// we reach a node_border. Used to locate the source side of a fan-OUT
/// trunk cell.
fn sourceReachable(lat: *const lattice.Lattice, x: u32, y: u32, comptime step_dy: i32, max_steps: u32, count_arrowhead: bool) bool {
    if (x >= lat.width) return false;
    var steps: u32 = 0;
    var yi: i64 = @as(i64, y) + step_dy;
    while (yi >= 0 and yi < @as(i64, @intCast(lat.height)) and steps < max_steps) : (yi += step_dy) {
        const c = lat.atConst(x, @intCast(yi));
        switch (c.occupant) {
            .node_border => return true,
            .arrowhead => |a| {
                // A child terminal: an arrowhead whose flow direction
                // matches the probe direction (▼ when walking down, ▲
                // when walking up) is a reachable child — but only the
                // caller (a rail end) trusts it; interior junctions pass
                // `count_arrowhead = false` so an offset target's ▼ does
                // not look like this stub's dropper.
                if (!count_arrowhead) return false;
                const want: lattice.Dir4 = if (step_dy > 0) .south else .north;
                return a.dir == want;
            },
            .edge_segment => {
                const n = c.neighbours;
                if (!(n.n and n.s and !n.e and !n.w)) return false;
            },
            else => return false,
        }
        steps += 1;
    }
    // The run continued as an unbroken pure-vertical edge up to the step
    // limit without resolving: the trunk/dropper plainly keeps going in
    // this direction, so treat it as reachable (the node is just beyond
    // `max_steps`). Returning false here would make a long straight arm
    // look spurious and get stripped.
    return steps >= max_steps;
}

/// Report whether the immediate vertical neighbour of `(x, y)` in
/// direction `d` (`.north`/`.south`) is a SECOND fan rail row on this
/// column: an `.edge_segment` carrying a fan rail/trunk role whose
/// neighbour mask includes a horizontal bit. That signature is unique to
/// grid-wrapped (rows > 1) fan-OUT — a single-row/declined fan's trunk
/// cell has only pure-vertical vertical neighbours (the pivot stem above,
/// the dropper/arrowhead below), never a horizontal-bearing rail — so the
/// grid guard cannot fire on those paths.
/// // guarded-by: edge_roles_test.zig "single-rail interior junction still strips to ┴"
fn railJunctionAdjacent(lat: *const lattice.Lattice, x: u32, y: u32, comptime d: lattice.Dir4) bool {
    const yi: i64 = @as(i64, y) + (if (d == .north) @as(i64, -1) else @as(i64, 1));
    if (yi < 0 or yi >= @as(i64, @intCast(lat.height))) return false;
    const c = lat.atConst(x, @intCast(yi));
    const seg = switch (c.occupant) {
        .edge_segment => |s| s,
        else => return false,
    };
    switch (seg.role) {
        .fan_out_rail, .fan_out_trunk, .fan_in_rail, .fan_in_trunk => {},
        else => return false,
    }
    return c.neighbours.e or c.neighbours.w;
}

test {
    _ = @import("edge_roles_test.zig");
}
