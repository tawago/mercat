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
//! The two laws, stated over the records:
//!   * no border cell carries crossings from two DIFFERENT corridors —
//!     several edges converging on one port are one corridor and legally
//!     share their cell, which is why the check is "share a port", not
//!     "share a record";
//!   * no crossing sits on a frame CORNER cell.

const std = @import("std");
const lattice = @import("lattice.zig");
const sketch = @import("sketch.zig");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");

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
};

const widths = [_]u32{ 40, 60, 80, 120 };

/// Every `.intrusion` record, decorated with what the grid says about the
/// cell it names.
const Crossing = struct {
    cell: u32,
    edge: u32,
    corner: bool,
};

fn isCorner(role: lattice.BorderRole) bool {
    return switch (role) {
        .corner_nw, .corner_ne, .corner_se, .corner_sw => true,
        .edge_n, .edge_e, .edge_s, .edge_w => false,
    };
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
        const flat = !built.report.join_permits_skipped_clustered;
        const winner = try select.choose(a, graph, &plan, flat, width, false, false);
        const report = try raster.rasterize(a, winner.sketch, .bridge, .{ .collect_aux = true });
        const lat = report.lattice;

        var seen: std.ArrayListUnmanaged(Crossing) = .empty;
        for (lat.aux) |rec| {
            if (rec.kind != .intrusion) continue;
            const cell = lat.at(rec.cell % lat.width, rec.cell / lat.width);
            const corner = switch (cell.occupant) {
                .cluster_border => |cb| isCorner(cb.role),
                // A crossing whose cell is no longer a border cell was
                // rewritten by a later pass; the corner law is about the
                // frame's own geometry, so only real border cells count.
                else => false,
            };
            try seen.append(a, .{ .cell = rec.cell, .edge = rec.value, .corner = corner });
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

        for (seen.items, 0..) |c, i| {
            for (seen.items[i + 1 ..]) |d| {
                if (c.cell != d.cell or c.edge == d.edge) continue;
                if (sharePort(winner.sketch.edges, c.edge, d.edge)) continue;
                std.debug.print(
                    "corpus[{d}] w{d}: edges {d} and {d} share border cell ({d},{d}) with no shared port\n",
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
