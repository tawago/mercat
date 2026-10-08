const std = @import("std");
const ledger = @import("base/ledger.zig");
const budget = @import("budget.zig");
const sem_graph = @import("sem_graph.zig");
const parse_mod = @import("parse.zig");

const Rung = budget.Rung;
const hasWidthOverflow = budget.hasWidthOverflow;

const test_bundle_permits: ledger.BundlePermits = .{ .policy = .joined };

fn testBundlePermits() *const ledger.BundlePermits {
    return &test_bundle_permits;
}

fn firstFit(a: std.mem.Allocator, src: []const u8, width: u32) !budget.Candidate {
    const g = try parse_mod.parse(a, src);
    return budget.firstFit(try budget.enumerate(a, g, testBundlePermits(), width));
}

test "switch_direction does not fit when rotation also overflows; declared direction kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try firstFit(arena.allocator(), "graph LR\nA[aaaaaa]-->B[bbbbbb]-->C[cccccc]-->D[dddddd]-->E[eeeeee]\n", 4);
    try std.testing.expectEqual(Rung.truncate, result.rung);
    try std.testing.expectEqual(sem_graph.Direction.LR, result.sketch.direction);
}

test "a deep LR chain first fits at switch_direction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try firstFit(
        arena.allocator(),
        "graph LR\nA[Alpha]-->B[Bravo]-->C[Charlie]-->D[Delta]-->E[Echo]" ++
            "-->F[Foxtrot]-->G[Golf]-->H[Hotel]\n",
        40,
    );
    try std.testing.expectEqual(Rung.switch_direction, result.rung);
    try std.testing.expect(!hasWidthOverflow(result.sketch.diagnostics));
}

test "runForced returns exactly the requested rung, fitting or not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse_mod.parse(
        a,
        "graph LR\nA[Alpha]-->B[Bravo]-->C[Charlie]-->D[Delta]-->E[Echo]" ++
            "-->F[Foxtrot]-->G[Golf]-->H[Hotel]\n",
    );
    const forced = try budget.runForced(a, g, testBundlePermits(), 40, .natural);
    try std.testing.expectEqual(Rung.natural, forced.rung);
    try std.testing.expectEqual(sem_graph.Direction.LR, forced.sketch.direction);
    try std.testing.expect(hasWidthOverflow(forced.sketch.diagnostics));

    const g2 = try parse_mod.parse(a, "graph TD\nA-->B\n");
    const rotated = try budget.runForced(a, g2, testBundlePermits(), 120, .switch_direction);
    try std.testing.expectEqual(Rung.switch_direction, rotated.rung);
    try std.testing.expectEqual(sem_graph.Direction.LR, rotated.sketch.direction);
}

test "every degenerate graph has a first fit at every width" {
    const graphs = [_][]const u8{
        "graph TD\nA\n",
        "graph TD\nA\nB\n",
        "graph LR\nA-->B\n",
        "graph TD\nA-->B\nC-->D\n",
    };
    for (graphs) |src| {
        for ([_]u32{ 1, 4, 40, 120 }) |w| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            _ = try firstFit(arena.allocator(), src, w);
        }
    }
}
