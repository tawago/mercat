const p0 = @import("rgi_0.zig").sequences;
const p1 = @import("rgi_1.zig").sequences;
const p2 = @import("rgi_2.zig").sequences;
const p3 = @import("rgi_3.zig").sequences;
const p4 = @import("rgi_4.zig").sequences;
const p5 = @import("rgi_5.zig").sequences;
const p6 = @import("rgi_6.zig").sequences;
const p7 = @import("rgi_7.zig").sequences;
pub const max_sequence_len = 10;
pub fn contains(cps: []const u21) bool {
    if (find(&p0, cps)) return true;
    if (find(&p1, cps)) return true;
    if (find(&p2, cps)) return true;
    if (find(&p3, cps)) return true;
    if (find(&p4, cps)) return true;
    if (find(&p5, cps)) return true;
    if (find(&p6, cps)) return true;
    if (find(&p7, cps)) return true;
    return false;
}

fn find(sequences: []const []const u21, cps: []const u21) bool {
    var low: usize = 0;
    var high = sequences.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (compare(sequences[mid], cps)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return true,
        }
    }
    return false;
}

fn compare(a: []const u21, b: []const u21) std.math.Order {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        if (x < y) return .lt;
        if (x > y) return .gt;
    }
    return std.math.order(a.len, b.len);
}

const std = @import("std");
