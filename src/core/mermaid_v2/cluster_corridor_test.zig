//! Cross-instrument pin for the per-column crossing discipline
//! (`cluster/corridors.zig`), run against REAL renders: parse -> permits ->
//! select -> rasterize -> read the side table.
//!
//! WHY THIS EXISTS. The discipline is decided at LAYOUT time, over rects and
//! ports; what it is ABOUT is a painted fact — which border cell an edge
//! meets — that only the raster knows, and files as an `.intrusion` record
//! because the frame-solid ruling leaves the cell itself pristine. The
//! cluster zone cannot import the raster (it is two stages downstream), so
//! the two can only be held against each other here at the root, the same
//! arrangement and the same lint-row grant as `tiling_records_test.zig`.
//!
//! The laws, stated over the records, in priority order:
//!
//!   * a port the discipline SLID keeps a clear approach run. Separating two
//!     crossings by shifting one behind an intervening node box swallows the
//!     stroke for that box's whole height and re-emerges as a second foot on
//!     its far border — the reader sees an edge leaving a node that has
//!     none. This outranks the next law: a merged pair of crossings LOSES an
//!     edge, a pierced box INVENTS one, and invention is worse;
//!
//!   * no border cell carries crossings from two DIFFERENT corridors —
//!     several edges converging on one port are one corridor and legally
//!     share their cell, which is why the check is "share a port", not
//!     "share a record". The exemption is a merge the geometry FORCED: when
//!     no assignment of distinct cells keeps both approach runs out of the
//!     node boxes, the merge stands. Targets stacked in one column are the
//!     standing case — every column of the far one's face lies behind the
//!     near one's box, so nothing can be separated there by sliding ports;
//!
//!   * no crossing sits on a frame CORNER cell.
//!
//! NOT pinned here, because the discipline's lever is a PORT slide and
//! neither is reachable by one:
//!   * that a MERGED corridor's own descent misses the boxes between it and
//!     its port. It does not — a stacked pair's second stroke runs down
//!     through the first target — and only an obstacle-aware reroute could
//!     fix it;
//!   * that two corridors RE-ROUTED by `bridges.verticalCorridor` meet a
//!     border at different cells. Those meet it at their descent columns,
//!     which no port slide chooses; `bridges.route` therefore withholds
//!     their demands rather than de-centring arrow feet for nothing, and the
//!     corpus's four-members-leaving-one-frame scene pins that it does.

const std = @import("std");
const lattice = @import("lattice.zig");
const sketch = @import("sketch.zig");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");
const corridors = @import("cluster/corridors.zig");

const testing = std.testing;

/// Cluster scenes built to crowd one frame side: several edges entering a
/// subgraph from the same direction, edges aimed near a frame corner, and
/// crossings through a title row whose text spans the crossing column.
const corpus = [_][]const u8{
    // Two producers into one stage — two crossings through one top border,
    // through the title's own characters.
    "flowchart TD\n  P[Producer]\n  Q[Queue]\n  subgraph S[\"Processing Stage\"]\n    X[Worker A] --> Y[Worker B]\n    Z[Worker C]\n  end\n  P --> X\n  Q --> Z\n  Y --> R[Result]\n",
    // Three top-level sources into three stacked members.
    "flowchart TD\n  A[Alpha]\n  B[Beta]\n  C[Gamma]\n  subgraph S[\"Core\"]\n    X1[One]\n    X2[Two]\n    X3[Three]\n  end\n  A --> X1\n  B --> X2\n  C --> X3\n",
    // Sideways entry through a long title that spans the whole top row.
    "flowchart LR\n  A[Src1]\n  B[Src2]\n  subgraph S[\"A very long subgraph title spanning wide\"]\n    M[Mid1]\n    N[Mid2]\n  end\n  A --> M\n  B --> N\n  M --> O[Out]\n",
    // Two frames side by side with an edge into each and one between them:
    // the corridor that used to run down a frame's own wall, through both
    // of its corners.
    "flowchart TD\n  A[In]\n  subgraph S1[\"Left\"]\n    L1[L1] --> L2[L2]\n  end\n  subgraph S2[\"Right\"]\n    R1[R1] --> R2[R2]\n  end\n  A --> L1\n  A --> R1\n  L2 --> R2\n  R2 --> Z[End]\n",
    // Mutually crossing frames: one crossing leaves a frame where another
    // enters it, both on the same border row.
    "flowchart TD\n  subgraph S1\n    A --> B\n  end\n  subgraph S2\n    C --> D\n  end\n  A --> D\n  C --> B\n",
    // A wide fan into one frame: four crossings on a single top border.
    "flowchart TD\n  H[Hub]\n  subgraph S[\"Bank\"]\n    N1[N1]\n    N2[N2]\n    N3[N3]\n    N4[N4]\n  end\n  H --> N1\n  H --> N2\n  H --> N3\n  H --> N4\n",
    // Two edges into ONE member: they converge before the border and are
    // one corridor — the case the law must NOT split.
    "flowchart TD\n  A[A]\n  B[B]\n  subgraph S[\"Target\"]\n    T[T]\n  end\n  A --> T\n  B --> T\n",
    // Nested frames, crossing the inner and the outer border in one run.
    "flowchart TD\n  E[Entry]\n  subgraph OUT[\"Outer\"]\n    subgraph IN[\"Inner\"]\n      I1[I1] --> I2[I2]\n    end\n    P1[P1]\n  end\n  E --> I1\n  E --> P1\n  I2 --> F[Fin]\n",
    // Members pushed hard against the frame's own corners.
    "flowchart LR\n  S1[S1]\n  S2[S2]\n  subgraph G[\"G\"]\n    G1[G1]\n    G2[G2]\n  end\n  S1 --> G1\n  S2 --> G2\n  G1 --> G2\n",
    // Labelled crossings, which move the geometry around again.
    "flowchart TD\n  A[A]\n  subgraph S[\"Stage\"]\n    B[B] --> C[C]\n  end\n  A -->|start| B\n  A -->|skip| C\n  C -->|done| D[D]\n",
    // Four members leaving one frame's bottom border. Narrow widths stack
    // them, which pushes every corridor onto the obstacle-aware re-route:
    // the crossings then land at descent columns the port slide never
    // chose, so no port here may be de-centred.
    "flowchart TD\n  subgraph S\n    M1\n    M2\n    M3\n    M4\n  end\n  M1 --> T1\n  M2 --> T2\n  M3 --> T3\n  M4 --> T4\n",
};

const widths = [_]u32{ 24, 30, 40, 60, 80, 120 };

/// Every `.intrusion` record, decorated with what the grid says about the
/// cell it names.
const Crossing = struct {
    cell: u32,
    edge: u32,
    corner: bool,
    /// Which frame side the cell sits on, or null when the cell is no longer
    /// a plain border cell.
    side: ?sketch.Dir4,
    x: i32,
    y: i32,
};

fn isCorner(role: lattice.BorderRole) bool {
    return switch (role) {
        .corner_nw, .corner_ne, .corner_se, .corner_sw => true,
        .edge_n, .edge_e, .edge_s, .edge_w => false,
    };
}

fn sideOf(role: lattice.BorderRole) ?sketch.Dir4 {
    return switch (role) {
        .edge_n => .north,
        .edge_s => .south,
        .edge_e => .east,
        .edge_w => .west,
        else => null,
    };
}

/// The drawn frame whose `side` border owns cell (x, y). Synthetic frames
/// paint nothing, so a border cell is never theirs.
fn frameOn(clusters: []const sketch.ClusterFrame, side: sketch.Dir4, x: i32, y: i32) ?sketch.Rect {
    for (clusters) |c| {
        if (c.synthetic) continue;
        const r = c.rect;
        const hit = switch (side) {
            .north => r.y == y and x >= r.x and x < r.right(),
            .south => r.bottom() - 1 == y and x >= r.x and x < r.right(),
            .west => r.x == x and y >= r.y and y < r.bottom(),
            .east => r.right() - 1 == x and y >= r.y and y < r.bottom(),
        };
        if (hit) return r;
    }
    return null;
}

/// The port `edge` presents to a frame side: the end whose node face is on
/// `side` and whose box sits inside `frame`.
const Approach = struct { rect: sketch.Rect, node: sketch.NodeId, peer: sketch.NodeId };

fn approachOf(s: sketch.Sketch, edge_id: u32, side: sketch.Dir4, frame: sketch.Rect) ?Approach {
    const e = pathById(s.edges, edge_id) orelse return null;
    for ([2]sketch.Port{ e.port_to, e.port_from }) |p| {
        if (p.side != side) continue;
        for (s.nodes) |n| {
            if (n.id != p.node) continue;
            if (n.rect.x < frame.x or n.rect.right() > frame.right()) continue;
            if (n.rect.y < frame.y or n.rect.bottom() > frame.bottom()) continue;
            const peer = if (p.node == e.to) e.from else e.to;
            return .{ .rect = n.rect, .node = n.id, .peer = peer };
        }
    }
    return null;
}

/// Every coordinate on `c`'s own node face that this crossing could legally
/// meet its frame at: off the frame's corners, and with an approach run
/// (border cell to port) that clears every other node box. Written into
/// `buf`; a face longer than the buffer is truncated, which can only make
/// the caller more permissive, never falsely strict.
fn clearColumns(s: sketch.Sketch, c: Crossing, buf: []i32) []i32 {
    const side = c.side orelse return buf[0..0];
    const frame = frameOn(s.clusters, side, c.x, c.y) orelse return buf[0..0];
    const ap = approachOf(s, c.edge, side, frame) orelse return buf[0..0];
    const rng = corridors.faceRange(ap.rect, side);
    const run = corridors.approachRun(frame, ap.rect, side);
    const horizontal = (side == .east or side == .west);

    var n: usize = 0;
    var coord = rng.lo;
    while (coord <= rng.hi and n < buf.len) : (coord += 1) {
        if (corridors.onCorner(frame, side, coord)) continue;
        if (sketch.lineTouchesAny(horizontal, coord, run.lo, run.hi, s.nodes, ap.node, ap.peer)) continue;
        buf[n] = coord;
        n += 1;
    }
    return buf[0..n];
}

/// True iff the two crossings could have been given DIFFERENT border cells
/// without either stroke being driven through a node box.
///
/// The question is about the pair, not about one end: freeing a cell by
/// moving `c` only helps if `d` has somewhere clear to be. Stacked targets
/// are the standing counter-example — every column of the far one's face
/// lies behind the near one's box, so no assignment separates them and the
/// merge is forced.
fn pairSeparable(s: sketch.Sketch, c: Crossing, d: Crossing) bool {
    var bc: [64]i32 = undefined;
    var bd: [64]i32 = undefined;
    const cc = clearColumns(s, c, &bc);
    const dd = clearColumns(s, d, &bd);
    if (cc.len == 0 or dd.len == 0) return false;
    // Two distinct coordinates have to exist across the two sets.
    return !(cc.len == 1 and dd.len == 1 and cc[0] == dd[0]);
}

/// True iff `c`'s port was SLID off its centred offset by the discipline.
fn wasSlid(s: sketch.Sketch, c: Crossing) bool {
    const side = c.side orelse return false;
    const e = pathById(s.edges, c.edge) orelse return false;
    for ([2]sketch.Port{ e.port_to, e.port_from }) |p| {
        if (p.side != side) continue;
        for (s.nodes) |n| {
            if (n.id != p.node) continue;
            return p.offset != corridors.sideOffset(n.rect, side);
        }
    }
    return false;
}

/// True iff the two edges meet at a common port — the same node face at the
/// same offset. That is exactly what "one corridor, several riders" means
/// geometrically: the strokes are already fused before they reach the frame.
fn sharePort(edges: []const sketch.EdgePath, a: u32, b: u32) bool {
    const ea = pathById(edges, a) orelse return false;
    const eb = pathById(edges, b) orelse return false;
    for ([2]sketch.Port{ ea.port_from, ea.port_to }) |pa| {
        for ([2]sketch.Port{ eb.port_from, eb.port_to }) |pb| {
            if (pa.node == pb.node and pa.side == pb.side and pa.offset == pb.offset) return true;
        }
    }
    return false;
}

fn pathById(edges: []const sketch.EdgePath, id: u32) ?sketch.EdgePath {
    for (edges) |e| {
        if (e.id == id) return e;
    }
    return null;
}

test "one crossing corridor per cluster-border cell, and never on a corner" {
    var crossings_seen: u32 = 0;
    for (corpus, 0..) |source, si| for (widths) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const graph = try parse(a, source);
        const built = try permits.build(a, graph, .joined);
        const plan = built.plan;
        const winner = try select.choose(a, graph, &plan, width, false, false);
        const report = try raster.rasterize(a, winner.sketch, .bridge);
        const lat = report.lattice;

        var seen: std.ArrayListUnmanaged(Crossing) = .empty;
        for (lat.aux) |rec| {
            if (rec.kind != .intrusion) continue;
            const cx = rec.cell % lat.width;
            const cy = rec.cell / lat.width;
            const cell = lat.at(cx, cy);
            // A crossing whose cell is no longer a border cell was rewritten
            // by a later pass; the corner law is about the frame's own
            // geometry, so only real border cells count.
            const corner = switch (cell.occupant) {
                .cluster_border => |cb| isCorner(cb.role),
                else => false,
            };
            const side: ?sketch.Dir4 = switch (cell.occupant) {
                .cluster_border => |cb| sideOf(cb.role),
                else => null,
            };
            try seen.append(a, .{
                .cell = rec.cell,
                .edge = rec.value,
                .corner = corner,
                .side = side,
                .x = @intCast(cx),
                .y = @intCast(cy),
            });
        }
        crossings_seen += @intCast(seen.items.len);

        for (seen.items) |c| {
            if (!c.corner) continue;
            std.debug.print(
                "corpus[{d}] w{d}: edge {d} crosses a FRAME CORNER at ({d},{d})\n",
                .{ si, width, c.edge, c.cell % lat.width, c.cell / lat.width },
            );
            return error.CorridorOnFrameCorner;
        }

        // A port the discipline SLID must have kept a clear approach run:
        // that is the whole content of the node-clearance term, stated over
        // a real render. A slide through a box swallows the stroke and puts
        // a second foot on the box's far border.
        for (seen.items) |c| {
            if (!wasSlid(winner.sketch, c)) continue;
            var buf: [64]i32 = undefined;
            const clear = clearColumns(winner.sketch, c, &buf);
            const side = c.side.?;
            const here = if (side == .east or side == .west) c.y else c.x;
            for (clear) |k| {
                if (k == here) break;
            } else {
                std.debug.print(
                    "corpus[{d}] w{d}: edge {d} was slid onto ({d},{d}), whose approach run pierces a node box\n",
                    .{ si, width, c.edge, c.x, c.y },
                );
                return error.SlidCorridorPiercesNodeBox;
            }
        }

        for (seen.items, 0..) |c, i| {
            for (seen.items[i + 1 ..]) |d| {
                if (c.cell != d.cell or c.edge == d.edge) continue;
                if (sharePort(winner.sketch.edges, c.edge, d.edge)) continue;
                // Forced merge: no assignment of distinct cells exists that
                // keeps both approach runs out of the node boxes.
                if (!pairSeparable(winner.sketch, c, d)) continue;
                std.debug.print(
                    "corpus[{d}] w{d}: edges {d} and {d} share border cell ({d},{d}) with no shared port, and a clear pair of columns existed\n",
                    .{ si, width, c.edge, d.edge, c.cell % lat.width, c.cell / lat.width },
                );
                return error.TwoCorridorsOneBorderCell;
            }
        }
    };
    // Agreement at zero would be no evidence: the corpus has to actually
    // drive edges through subgraph frames.
    try testing.expect(crossings_seen > 0);
}
