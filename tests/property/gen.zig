//! Generic value generators for property tests.
//!
//! Each generator takes a `std.Random` (and `std.mem.Allocator` where needed)
//! and produces a deterministic value seeded from upstream. Generators here
//! depend only on `std`. The `semGraph` generator is a placeholder until
//! build.zig wires the property-test module to the mermaid_v2 parse module.
const std = @import("std");

/// Uniform integer in the inclusive range [lo, hi]. Asserts lo <= hi.
pub fn intRange(rng: std.Random, comptime T: type, lo: T, hi: T) T {
    std.debug.assert(lo <= hi);
    return rng.intRangeAtMost(T, lo, hi);
}

/// Bernoulli draw: returns true with probability `p_true` (clamped to [0,1]).
pub fn boolWeighted(rng: std.Random, p_true: f32) bool {
    const p = std.math.clamp(p_true, 0.0, 1.0);
    return rng.float(f32) < p;
}

/// Allocate a slice of length in [0, max_len] filled by `gen_elem`.
/// Caller owns returned slice; on partial failure already-built elements
/// are not freed (callers should use arenas for complex element types).
pub fn slice(
    allocator: std.mem.Allocator,
    comptime T: type,
    rng: std.Random,
    max_len: usize,
    gen_elem: *const fn (std.mem.Allocator, std.Random) anyerror!T,
) ![]T {
    const len = if (max_len == 0) 0 else rng.intRangeAtMost(usize, 0, max_len);
    const buf = try allocator.alloc(T, len);
    errdefer allocator.free(buf);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[i] = try gen_elem(allocator, rng);
    }
    return buf;
}

/// ASCII alphabetic string of length in [0, max_len], allocator-owned.
pub fn alphabeticString(allocator: std.mem.Allocator, rng: std.Random, max_len: usize) ![]u8 {
    const len = if (max_len == 0) 0 else rng.intRangeAtMost(usize, 0, max_len);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const upper = rng.boolean();
        const off = rng.intRangeAtMost(u8, 0, 25);
        buf[i] = (if (upper) @as(u8, 'A') else @as(u8, 'a')) + off;
    }
    return buf;
}

/// Pick one tag of an enum uniformly at random.
pub fn pickEnum(rng: std.Random, comptime E: type) E {
    const fields = @typeInfo(E).@"enum".fields;
    comptime std.debug.assert(fields.len > 0);
    const idx = rng.intRangeLessThan(usize, 0, fields.len);
    inline for (fields, 0..) |f, i| {
        if (i == idx) return @field(E, f.name);
    }
    unreachable;
}

/// TODO(parser-agent, next round): wire to
/// `src/core/mermaid_v2/sem_graph.zig` once build.zig exposes it as
/// a module to the property-test step. Until then this stub panics.
pub fn semGraph(allocator: std.mem.Allocator, rng: std.Random, opts: anytype) !void {
    _ = allocator;
    _ = rng;
    _ = opts;
    @panic("wire after build.zig adds property-test module");
}

test "intRange respects bounds" {
    var prng = std.Random.DefaultPrng.init(0xABCD);
    const r = prng.random();
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const v = intRange(r, u32, 10, 20);
        try std.testing.expect(v >= 10 and v <= 20);
    }
}

test "boolWeighted clamps" {
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    try std.testing.expect(boolWeighted(r, 1.5) == true);
    try std.testing.expect(boolWeighted(r, -1.0) == false);
}

test "alphabeticString is alphabetic and bounded" {
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    const s = try alphabeticString(std.testing.allocator, r, 32);
    defer std.testing.allocator.free(s);
    try std.testing.expect(s.len <= 32);
    for (s) |c| try std.testing.expect(std.ascii.isAlphabetic(c));
}

test "pickEnum yields a valid tag" {
    const E = enum { a, b, c };
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    const v = pickEnum(r, E);
    try std.testing.expect(v == .a or v == .b or v == .c);
}
