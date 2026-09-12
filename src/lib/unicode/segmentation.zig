const std = @import("std");
const tables = @import("tables.zig");

pub const Utf8Error = error{InvalidUtf8};

pub const Decoded = struct {
    codepoint: u21,
    start: usize,
    end: usize,
};

pub const GraphemeBreak = enum(u8) {
    other = 0,
    cr = 1,
    lf = 2,
    control = 3,
    extend = 4,
    zwj = 5,
    regional_indicator = 6,
    prepend = 7,
    spacing_mark = 8,
    l = 9,
    v = 10,
    t = 11,
    lv = 12,
    lvt = 13,
};

pub fn nextBoundary(text: []const u8, start: usize) Utf8Error!usize {
    return nextBoundaryCounted(text, start, null);
}

/// As `nextBoundary`, while counting scalar decodes performed by segmentation.
pub fn nextBoundaryCounted(text: []const u8, start: usize, operations: ?*usize) Utf8Error!usize {
    var previous = try decodeAtCounted(text, start, operations);
    var previous_gcb = graphemeBreak(previous.codepoint);
    var boundary = previous.end;
    while (boundary < text.len) {
        const current = decodeAtCounted(text, boundary, operations) catch return boundary;
        const current_gcb = graphemeBreak(current.codepoint);
        if (shouldBreak(text, start, boundary, previous_gcb, current_gcb, current.codepoint, operations)) return boundary;
        previous = current;
        previous_gcb = current_gcb;
        boundary = current.end;
    }
    return text.len;
}

pub fn decodeAt(text: []const u8, index: usize) Utf8Error!Decoded {
    if (index >= text.len) return error.InvalidUtf8;
    const len = std.unicode.utf8ByteSequenceLength(text[index]) catch return error.InvalidUtf8;
    if (index + len > text.len) return error.InvalidUtf8;
    const cp = std.unicode.utf8Decode(text[index .. index + len]) catch return error.InvalidUtf8;
    return .{ .codepoint = cp, .start = index, .end = index + len };
}

fn decodeAtCounted(text: []const u8, index: usize, operations: ?*usize) Utf8Error!Decoded {
    if (operations) |count| count.* +|= 1;
    return decodeAt(text, index);
}

pub fn decodePrevious(text: []const u8, end: usize) Utf8Error!Decoded {
    if (end == 0 or end > text.len) return error.InvalidUtf8;
    var start = end - 1;
    while (start > 0 and text[start] & 0xc0 == 0x80) start -= 1;
    const decoded = try decodeAt(text, start);
    if (decoded.end != end) return error.InvalidUtf8;
    return decoded;
}

fn shouldBreak(
    text: []const u8,
    cluster_start: usize,
    boundary: usize,
    previous: GraphemeBreak,
    current: GraphemeBreak,
    current_cp: u21,
    operations: ?*usize,
) bool {
    if (previous == .cr and current == .lf) return false;
    if (isControl(previous) or isControl(current)) return true;
    if (previous == .l and (current == .l or current == .v or current == .lv or current == .lvt)) return false;
    if ((previous == .lv or previous == .v) and (current == .v or current == .t)) return false;
    if ((previous == .lvt or previous == .t) and current == .t) return false;
    if (current == .extend or current == .zwj or current == .spacing_mark) return false;
    if (previous == .prepend) return false;
    if (tables.incb.lookup(current_cp) == 2 and hasIndicLinker(text, cluster_start, boundary, operations)) return false;
    if (tables.extended_pictographic.contains(current_cp) and hasExtendedPictographicZwj(text, cluster_start, boundary, operations)) return false;
    if (previous == .regional_indicator and current == .regional_indicator and precedingRiCount(text, cluster_start, boundary, operations) % 2 == 1) return false;
    return true;
}

fn hasIndicLinker(text: []const u8, cluster_start: usize, boundary: usize, operations: ?*usize) bool {
    var end = boundary;
    var saw_linker = false;
    while (end > cluster_start) {
        const decoded = decodePreviousCounted(text, end, operations) catch return false;
        switch (tables.incb.lookup(decoded.codepoint)) {
            1 => saw_linker = true,
            2 => return saw_linker,
            3 => {},
            else => return false,
        }
        end = decoded.start;
    }
    return false;
}

fn hasExtendedPictographicZwj(text: []const u8, cluster_start: usize, boundary: usize, operations: ?*usize) bool {
    var decoded = decodePreviousCounted(text, boundary, operations) catch return false;
    if (graphemeBreak(decoded.codepoint) != .zwj) return false;
    var end = decoded.start;
    while (end > cluster_start) {
        decoded = decodePreviousCounted(text, end, operations) catch return false;
        if (graphemeBreak(decoded.codepoint) == .extend) {
            end = decoded.start;
            continue;
        }
        return tables.extended_pictographic.contains(decoded.codepoint);
    }
    return false;
}

fn precedingRiCount(text: []const u8, cluster_start: usize, boundary: usize, operations: ?*usize) usize {
    var end = boundary;
    var count: usize = 0;
    while (end > cluster_start) {
        const decoded = decodePreviousCounted(text, end, operations) catch break;
        if (graphemeBreak(decoded.codepoint) != .regional_indicator) break;
        count += 1;
        end = decoded.start;
    }
    return count;
}

fn decodePreviousCounted(text: []const u8, end: usize, operations: ?*usize) Utf8Error!Decoded {
    if (operations) |count| count.* +|= 1;
    return decodePrevious(text, end);
}

pub fn graphemeBreak(cp: u21) GraphemeBreak {
    return @enumFromInt(tables.gcb.lookup(cp));
}

fn isControl(value: GraphemeBreak) bool {
    return value == .cr or value == .lf or value == .control;
}

test {
    _ = std;
}
