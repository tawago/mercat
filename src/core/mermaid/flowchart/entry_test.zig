const std = @import("std");
const ledger = @import("base/ledger.zig");
const ladder = @import("budget.zig");
const entry = @import("entry.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");
const parse = @import("parse.zig").parse;

test "V-D-POLICY-02: production resolver originates joined for a flat graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\nA --> B\nA --> C\n");

    const result = try select.resolvePermits(a, graph);
    try std.testing.expectEqual(ledger.BundlePolicy.joined, result.plan.policy);
    try std.testing.expect(!result.report.bundle_permits_skipped_clustered);
    try std.testing.expectEqual(@as(usize, 1), result.plan.groups.len);
}

test "V-D-POLICY-03: policy has no config CLI or environment surface" {
    try std.testing.expect(!@hasField(entry.RenderOptions, "policy"));

    const source = "flowchart TD\nA --> B\n";
    const left = try entry.renderFlowchart(std.testing.allocator, source, .{});
    defer std.testing.allocator.free(left.output);
    const right = try entry.renderFlowchart(std.testing.allocator, source, .{});
    defer std.testing.allocator.free(right.output);
    try std.testing.expectEqualStrings(left.output, right.output);
}

test "V-D-IR-07: a clustered graph's bundles ride piece plans; the root plan stays skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\subgraph S
        \\  A --> B
        \\end
        \\B --> C
        \\
    );

    const result = try select.resolvePermits(a, graph);
    try std.testing.expectEqual(ledger.BundlePolicy.joined, result.plan.policy);
    try std.testing.expect(result.report.bundle_permits_skipped_clustered);
    const laid_out = try ladder.runForced(a, graph, &result.plan, 120, .natural);
    try std.testing.expectEqual(@as(usize, 0), laid_out.sketch.bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 2), laid_out.sketch.bundles.memberships.len);
    const bridge_row = laid_out.sketch.bundles.memberships[1];
    try std.testing.expect(bridge_row.source == null and bridge_row.target == null);
}

test "cluster unification: a subgraph-internal fan-in realizes a rail and ships it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\subgraph S
        \\  A --> C
        \\  B --> C
        \\end
        \\
    );

    const result = try select.resolvePermits(a, graph);
    const laid_out = try ladder.runForced(a, graph, &result.plan, 80, .natural);
    try std.testing.expectEqual(@as(usize, 1), laid_out.sketch.bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 2), laid_out.sketch.bundles.selected_bundles[0].members.len);

    const rendered = try entry.renderFlowchart(std.testing.allocator, "flowchart TD\nsubgraph S\n  A --> C\n  B --> C\nend\n", .{ .max_width = 80 });
    defer std.testing.allocator.free(rendered.output);
    try std.testing.expect(!rendered.is_fallback);
    const expected =
        \\┌─ S ────────────────┐
        \\│                    │
        \\│   ┌───┐    ┌───┐   │
        \\│   │ A │    │ B │   │
        \\│   └─┬─┘    └─┬─┘   │
        \\│     └───┬────┘     │
        \\│         │          │
        \\│         ▼          │
        \\│       ┌───┐        │
        \\│       │ C │        │
        \\│       └───┘        │
        \\│                    │
        \\└────────────────────┘
    ;
    try std.testing.expectEqualStrings(expected, std.mem.trimRight(u8, rendered.output, "\n"));
}

test "cluster unification: two subgraph rails keep their own members through nonzero stitch bases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\subgraph S
        \\  A --> C
        \\  B --> C
        \\end
        \\subgraph T
        \\  D --> F
        \\  E --> F
        \\end
        \\
    );

    const result = try select.resolvePermits(a, graph);
    const laid_out = try ladder.runForced(a, graph, &result.plan, 80, .natural);
    const bundles = laid_out.sketch.bundles.selected_bundles;
    try std.testing.expectEqual(@as(usize, 2), bundles.len);
    try std.testing.expectEqual(@as(usize, 2), laid_out.sketch.rails.len);
    for (bundles) |j| {
        try std.testing.expectEqual(@as(usize, 2), j.members.len);
        var matched = false;
        for (laid_out.sketch.rails) |rail| {
            if (rail.taps.len != 2) continue;
            const fwd = (rail.taps[0].edge == j.members[0] and rail.taps[1].edge == j.members[1]);
            const rev = (rail.taps[0].edge == j.members[1] and rail.taps[1].edge == j.members[0]);
            if (fwd or rev) matched = true;
        }
        try std.testing.expect(matched);
    }
    try std.testing.expect(bundles[0].members[0] != bundles[1].members[0]);
    try std.testing.expect(bundles[0].members[1] != bundles[1].members[1]);
}

test "cluster unification: a bridge never transits a stitched rail's arrowhead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\flowchart TD
        \\subgraph S1
        \\  A1 --> C
        \\  A2 --> C
        \\  A3 --> C
        \\end
        \\subgraph S2
        \\  B1 --> D
        \\  B2 --> D
        \\end
        \\H --> A1
        \\C --> E
        \\C --> H
        \\
    );
    const result = try select.resolvePermits(a, graph);
    const laid_out = try ladder.runForced(a, graph, &result.plan, 120, .natural);
    const report = try raster.rasterize(a, laid_out.sketch, .bridge);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try std.testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
    try std.testing.expectEqual(@as(u32, 0), report.arrow_base.lateral_arms);
}

test "cluster unification: bridges route around each other, not through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\graph LR
        \\    subgraph auth-service/
        \\        INDEX[src/index.ts<br/>Entry point]
        \\        PROV[src/provider.ts<br/>Provider config]
        \\        CFG[src/config/]
        \\        ADAPT[src/adapters/account.ts]
        \\        CLAIMS[src/claims/custom-claims.ts]
        \\        INTER[src/interactions/]
        \\        VIEWS[views/*.ejs]
        \\        DATA[data/users.yaml]
        \\    end
        \\    INDEX --> PROV
        \\    PROV --> CFG
        \\    PROV --> ADAPT
        \\    PROV --> CLAIMS
        \\    PROV --> INTER
        \\    INTER --> VIEWS
        \\    ADAPT --> DATA
        \\    subgraph web-app/
        \\        AUTH[contexts/auth-context.tsx]
        \\        ROUTES[routes/_authenticated/]
        \\    end
        \\    AUTH -.->|OIDC flow| PROV
        \\    subgraph api-server/
        \\        COMPOSE[docker-compose.yaml]
        \\        VALID[JWT validation]
        \\    end
        \\    COMPOSE -->|runs| INDEX
        \\    VALID -.->|fetch JWKS| PROV
        \\
    );
    const result = try select.resolvePermits(a, graph);
    const winner = try select.choose(a, graph, &result.plan, 120, .bridge);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    try std.testing.expectEqual(@as(u32, 0), report.arrow_base.lateral_arms);
}
