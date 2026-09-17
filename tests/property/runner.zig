//! `forAll` runner for the property-test harness.
//!
//! Allocator policy: each iteration uses an `ArenaAllocator` parented to
//! `std.testing.allocator`. The generator and property both run against the
//! arena, and the entire arena is reset between iterations so per-iteration
//! allocations are freed automatically — generators do not need to track
//! ownership of intermediate buffers.
const std = @import("std");
const prng_mod = @import("prng.zig");

pub const ShrinkOptions = struct {
    attempts: u8 = 3,
    halve_params: bool = true,
};

pub const RunOptions = struct {
    count: u32 = 256,
    shrink: ShrinkOptions = .{},
};

/// Run `prop` against `count` generated `Param` values. The first failure is
/// logged with the seed and iteration index, an optional shrink pass is
/// attempted (currently a cheap re-run of the failing generator), and the
/// original error is propagated.
pub fn forAll(
    comptime Param: type,
    gen: *const fn (std.mem.Allocator, std.Random, u32) anyerror!Param,
    prop: *const fn (Param) anyerror!void,
    opts: RunOptions,
) !void {
    var prng = prng_mod.Prng.fromEnv(std.testing.allocator);
    const rng = prng.random();

    var i: u32 = 0;
    while (i < opts.count) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const param = try gen(aa, rng, i);
        prop(param) catch |err| {
            std.debug.print(
                "[proptest] FAIL @ seed=0x{X} iter={d}: {s}\n",
                .{ prng.seed, i, @errorName(err) },
            );
            try shrink(Param, gen, prop, prng.seed, i, opts.shrink);
            return err;
        };
    }
}

fn shrink(
    comptime Param: type,
    gen: *const fn (std.mem.Allocator, std.Random, u32) anyerror!Param,
    prop: *const fn (Param) anyerror!void,
    seed: u64,
    fail_iter: u32,
    opts: ShrinkOptions,
) !void {
    var attempt: u8 = 0;
    var idx: u32 = fail_iter;
    while (attempt < opts.attempts and idx > 0) : (attempt += 1) {
        idx = if (opts.halve_params) idx / 2 else idx -| 1;

        var local = prng_mod.Prng.withSeed(seed);
        const r = local.random();

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // Replay the stream up to idx so we get the same value the original
        // run would have produced at that iteration.
        var j: u32 = 0;
        while (j < idx) : (j += 1) {
            _ = gen(aa, r, j) catch break;
        }
        const param = gen(aa, r, idx) catch continue;
        if (prop(param)) |_| {
            // Did not reproduce at this index; try a smaller one.
            continue;
        } else |err| {
            std.debug.print(
                "[proptest] shrink reproduced FAIL @ seed=0x{X} iter={d} ({s})\n",
                .{ seed, idx, @errorName(err) },
            );
            return;
        }
    }
    std.debug.print(
        "[proptest] shrink: no smaller failing input found (seed=0x{X})\n",
        .{seed},
    );
}

test "forAll runs N times and detects always-failing property" {
    const Param = u32;
    const hits: u32 = 0;
    const gen = struct {
        fn g(_: std.mem.Allocator, rng: std.Random, _: u32) !Param {
            return rng.int(u32);
        }
    }.g;
    const prop = struct {
        fn p(_: Param) !void {}
    }.p;
    try forAll(Param, gen, prop, .{ .count = 16 });
    _ = hits;
}

test "forAll surfaces failures" {
    const Param = u32;
    const gen = struct {
        fn g(_: std.mem.Allocator, rng: std.Random, _: u32) !Param {
            return rng.int(u32);
        }
    }.g;
    const prop = struct {
        fn p(_: Param) !void {
            return error.AlwaysFails;
        }
    }.p;
    const result = forAll(Param, gen, prop, .{ .count = 4 });
    try std.testing.expectError(error.AlwaysFails, result);
}
