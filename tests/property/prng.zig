//! Deterministic seedable PRNG wrapper for the property-test harness.
//!
//! Reads the seed from env var `MERCAT_PROPTEST_SEED` (hex `0x...` or decimal).
//! Falls back to `default_seed` on any read/parse failure. Prints the
//! resolved seed to stderr once on construction so failing seeds can be
//! reproduced from CI logs.
const std = @import("std");

pub const default_seed: u64 = 0xC0FFEE;
pub const env_var_name = "MERCAT_PROPTEST_SEED";

pub const Prng = struct {
    inner: std.Random.DefaultPrng,
    seed: u64,

    pub fn fromEnv(allocator: std.mem.Allocator) Prng {
        const seed = readSeedFromEnv(allocator) orelse default_seed;
        return withSeed(seed);
    }

    pub fn withSeed(seed: u64) Prng {
        std.debug.print("[proptest] seed=0x{X}\n", .{seed});
        return .{
            .inner = std.Random.DefaultPrng.init(seed),
            .seed = seed,
        };
    }

    pub fn random(self: *Prng) std.Random {
        return self.inner.random();
    }
};

fn readSeedFromEnv(allocator: std.mem.Allocator) ?u64 {
    const raw = std.process.getEnvVarOwned(allocator, env_var_name) catch return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.len > 2 and (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X"))) {
        return std.fmt.parseInt(u64, trimmed[2..], 16) catch null;
    }
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

test "withSeed is deterministic" {
    var a = Prng.withSeed(0x1234);
    var b = Prng.withSeed(0x1234);
    try std.testing.expectEqual(a.random().int(u64), b.random().int(u64));
}

test "fromEnv falls back without env var" {
    const p = Prng.fromEnv(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, default_seed), p.seed);
}
