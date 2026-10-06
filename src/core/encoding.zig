//! Turns input bytes into valid UTF-8 before anything parses them.
//!
//! Invalid UTF-8 is decoded lossily: each maximal subpart of an ill-formed
//! sequence (Unicode §3.9 "U+FFFD Substitution of Maximal Subparts", the
//! WHATWG decoder's behavior) becomes one U+FFFD, so a stray byte never
//! changes how the rest of the document parses. A UTF-8 byte order mark is
//! dropped. Input that starts with a UTF-16 byte order mark is transcoded to
//! UTF-8; unpaired surrogates (and a dangling odd byte) become U+FFFD.
//!
//! `decode` reports where the first replacement happened, so the caller can
//! print one warning per input.
const std = @import("std");

pub const replacement = "\u{FFFD}";

pub const Encoding = enum {
    utf8,
    utf16le,
    utf16be,

    pub fn name(self: Encoding) []const u8 {
        return switch (self) {
            .utf8 => "UTF-8",
            .utf16le, .utf16be => "UTF-16",
        };
    }

    /// What a replaced unit is called in the warning.
    pub fn unitName(self: Encoding, count: usize) []const u8 {
        return switch (self) {
            .utf8 => if (count == 1) "byte" else "bytes",
            .utf16le, .utf16be => if (count == 1) "code unit" else "code units",
        };
    }
};

/// Where the first invalid sequence was and how much input was replaced.
pub const Issue = struct {
    /// 1-based line of the first invalid sequence.
    line: usize,
    /// 1-based column, counted in characters of the decoded line.
    column: usize,
    /// Input units (bytes, or UTF-16 code units) replaced with U+FFFD.
    replaced: usize,
};

pub const Decoded = struct {
    /// Valid UTF-8. Borrows the input when nothing had to change.
    text: []const u8,
    owned: bool,
    encoding: Encoding,
    issue: ?Issue,

    pub fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.text);
    }
};

const utf8_bom = "\xEF\xBB\xBF";

/// Decodes `bytes` to valid UTF-8 (see the module comment). The result
/// borrows `bytes` when it is already valid UTF-8.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!Decoded {
    if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) return decodeUtf16(allocator, bytes[2..], .little);
    if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) return decodeUtf16(allocator, bytes[2..], .big);
    const body = if (std.mem.startsWith(u8, bytes, utf8_bom)) bytes[utf8_bom.len..] else bytes;
    if (std.unicode.utf8ValidateSlice(body)) return .{ .text = body, .owned = false, .encoding = .utf8, .issue = null };

    var out: Output = .{ .allocator = allocator };
    errdefer out.buf.deinit(allocator);
    try out.buf.ensureTotalCapacity(allocator, body.len + 16);
    var i: usize = 0;
    while (i < body.len) {
        const n = wellFormedPrefix(body[i..]);
        if (n.valid) {
            try out.scalar(body[i .. i + n.len]);
        } else {
            try out.replace(n.len);
        }
        i += n.len;
    }
    return out.finish(.utf8);
}

/// Lossy decoding only, for callers that report nothing (the parser's own
/// safety net). Returns an owned copy.
pub fn toValidUtf8(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]u8 {
    const decoded = try decode(allocator, bytes);
    if (decoded.owned) return @constCast(decoded.text);
    return allocator.dupe(u8, decoded.text);
}

const Prefix = struct { len: usize, valid: bool };

/// Length of the well-formed sequence at the start of `s` (Unicode Table
/// 3-7), or of its maximal ill-formed subpart (at least one byte).
fn wellFormedPrefix(s: []const u8) Prefix {
    const b0 = s[0];
    if (b0 < 0x80) return .{ .len = 1, .valid = true };
    const need: usize, const lo: u8, const hi: u8 = switch (b0) {
        0xC2...0xDF => .{ 2, 0x80, 0xBF },
        0xE0 => .{ 3, 0xA0, 0xBF },
        0xE1...0xEC, 0xEE...0xEF => .{ 3, 0x80, 0xBF },
        0xED => .{ 3, 0x80, 0x9F },
        0xF0 => .{ 4, 0x90, 0xBF },
        0xF1...0xF3 => .{ 4, 0x80, 0xBF },
        0xF4 => .{ 4, 0x80, 0x8F },
        else => return .{ .len = 1, .valid = false },
    };
    var len: usize = 1;
    while (len < need) : (len += 1) {
        if (len >= s.len) return .{ .len = len, .valid = false };
        const b = s[len];
        const ok = if (len == 1) b >= lo and b <= hi else b >= 0x80 and b <= 0xBF;
        if (!ok) return .{ .len = len, .valid = false };
    }
    return .{ .len = need, .valid = true };
}

fn decodeUtf16(allocator: std.mem.Allocator, body: []const u8, endian: std.builtin.Endian) error{OutOfMemory}!Decoded {
    var out: Output = .{ .allocator = allocator };
    errdefer out.buf.deinit(allocator);
    try out.buf.ensureTotalCapacity(allocator, body.len + 16);
    const units = body.len / 2;
    var i: usize = 0;
    while (i < units) {
        const unit = std.mem.readInt(u16, body[i * 2 ..][0..2], endian);
        var cp: u21 = unit;
        var used: usize = 1;
        if (unit >= 0xD800 and unit <= 0xDBFF and i + 1 < units) {
            const low = std.mem.readInt(u16, body[(i + 1) * 2 ..][0..2], endian);
            if (low >= 0xDC00 and low <= 0xDFFF) {
                cp = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (low - 0xDC00);
                used = 2;
            }
        }
        i += used;
        if (cp >= 0xD800 and cp <= 0xDFFF) {
            try out.replace(1);
            continue;
        }
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch unreachable;
        try out.scalar(enc[0..n]);
    }
    if (body.len % 2 != 0) try out.replace(1);
    return out.finish(if (endian == .little) .utf16le else .utf16be);
}

/// Accumulates decoded text and tracks the line and column of the output.
const Output = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    line: usize = 1,
    column: usize = 1,
    issue: ?Issue = null,

    fn scalar(self: *Output, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
        if (bytes.len == 1 and bytes[0] == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
    }

    fn replace(self: *Output, units: usize) !void {
        if (self.issue) |*issue| {
            issue.replaced += units;
        } else {
            self.issue = .{ .line = self.line, .column = self.column, .replaced = units };
        }
        try self.scalar(replacement);
    }

    fn finish(self: *Output, encoding: Encoding) !Decoded {
        return .{
            .text = try self.buf.toOwnedSlice(self.allocator),
            .owned = true,
            .encoding = encoding,
            .issue = self.issue,
        };
    }
};

/// Formats the one-line warning for `issue` ("<name>: invalid UTF-8 at line
/// L, column C (N bytes replaced with U+FFFD)") into `buf`.
pub fn describeIssue(buf: []u8, name: []const u8, encoding: Encoding, issue: Issue) []const u8 {
    return std.fmt.bufPrint(buf, "{s}: invalid {s} at line {d}, column {d} ({d} {s} replaced with U+FFFD)", .{
        name, encoding.name(), issue.line, issue.column, issue.replaced, encoding.unitName(issue.replaced),
    }) catch "input is not valid text";
}

test {
    _ = @import("encoding_test.zig");
}
