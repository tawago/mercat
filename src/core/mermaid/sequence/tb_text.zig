//! The break state of every text in a top-down drawing: its lines, and the one degradation that
//! may change them, a break at the space nearest the middle of the widest line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode");
const seq = @import("seq.zig");

pub const Line = struct { bytes: []const u8, width: u32 };

const br_tags = [_][]const u8{ "<br/>", "<br>" };

pub const Texts = struct {
    arena: Allocator,
    lines: []std.ArrayList(Line),

    pub fn init(arena: Allocator, raw: []const []const u8) !Texts {
        const lines = try arena.alloc(std.ArrayList(Line), raw.len);
        for (raw, lines) |text, *out| {
            out.* = .empty;
            const clean = try arena.dupe(u8, text);
            std.mem.replaceScalar(u8, clean, '\t', ' ');
            var rest: []const u8 = clean;
            while (true) {
                const cut = nextBr(rest);
                const piece = std.mem.trim(u8, rest[0..cut.start], " \r");
                if (piece.len > 0) try out.append(arena, .{ .bytes = piece, .width = width(piece) });
                if (cut.start == rest.len) break;
                rest = rest[cut.end..];
            }
        }
        return .{ .arena = arena, .lines = lines };
    }

    pub fn of(self: *const Texts, t: seq.TextIx) []const Line {
        return self.lines[t].items;
    }

    pub fn count(self: *const Texts, t: seq.TextIx) u32 {
        return @intCast(self.lines[t].items.len);
    }

    /// The display width of the widest line.
    pub fn widest(self: *const Texts, t: seq.TextIx) u32 {
        var w: u32 = 0;
        for (self.lines[t].items) |line| w = @max(w, line.width);
        return w;
    }

    pub fn canBreak(self: *const Texts, t: seq.TextIx) bool {
        const ix = self.widestIndex(t) orelse return false;
        return breakPoint(self.lines[t].items[ix].bytes) != null;
    }

    /// Breaks the widest line (the first of equals) at the space nearest its middle in display
    /// columns, the left one on a tie. False when that line has no space to break at.
    pub fn breakOnce(self: *Texts, t: seq.TextIx) !bool {
        const ix = self.widestIndex(t) orelse return false;
        const line = self.lines[t].items[ix].bytes;
        const at = breakPoint(line) orelse return false;
        const left = std.mem.trimEnd(u8, line[0..at], " ");
        const right = std.mem.trimStart(u8, line[at + 1 ..], " ");
        self.lines[t].items[ix] = .{ .bytes = left, .width = width(left) };
        try self.lines[t].insert(self.arena, ix + 1, .{ .bytes = right, .width = width(right) });
        return true;
    }

    fn widestIndex(self: *const Texts, t: seq.TextIx) ?usize {
        var best: ?usize = null;
        for (self.lines[t].items, 0..) |line, i| {
            if (best == null or line.width > self.lines[t].items[best.?].width) best = i;
        }
        return best;
    }
};

pub fn width(text: []const u8) u32 {
    return @intCast(unicode.displayWidth(text));
}

/// The byte index of the space nearest the middle of `line` that leaves text on both sides.
fn breakPoint(line: []const u8) ?usize {
    const total = width(line);
    var best: ?usize = null;
    var best_dist: u32 = std.math.maxInt(u32);
    for (line, 0..) |c, i| {
        if (c != ' ') continue;
        if (std.mem.trim(u8, line[0..i], " ").len == 0) continue;
        if (std.mem.trim(u8, line[i + 1 ..], " ").len == 0) continue;
        const col = width(line[0..i]);
        const dist: u32 = @intCast(@abs(@as(i64, 2 * col) - @as(i64, total) + 1));
        if (dist < best_dist) {
            best = i;
            best_dist = dist;
        }
    }
    return best;
}

const Cut = struct { start: usize, end: usize };

fn nextBr(text: []const u8) Cut {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        for (br_tags) |tag| {
            if (std.mem.startsWith(u8, text[i..], tag)) return .{ .start = i, .end = i + tag.len };
        }
    }
    return .{ .start = text.len, .end = text.len };
}

test {
    _ = @import("tb_text_test.zig");
}
