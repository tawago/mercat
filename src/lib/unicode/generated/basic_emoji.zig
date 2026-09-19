const p0 = @import("basic_emoji_0.zig").ranges;
pub fn contains(cp: u21) bool {
    if (find(&p0, cp) != 0) return true;
    return false;
}

fn find(ranges: []const [3]u32, cp: u21) u8 {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (cp < ranges[mid][0]) high = mid else if (cp > ranges[mid][1]) low = mid + 1 else return 1;
    }
    return 0;
}
