//! The ink grammar of a painted grid: which cells are boxes, frames, strokes
//! and end markers, and which cells the arms join.

const std = @import("std");
const unicode = @import("unicode");

pub const End = enum { none, filled, open, circle, cross };

pub const Finding = struct {
    kind: Kind,
    row: usize,
    col: usize,

    pub const Kind = enum {
        /// An arm that reaches no ink, box or frame.
        dangling_arm,
        /// Ink entering an end marker from its side or through its tip.
        arm_into_marker,
        /// An end marker whose tip does not touch a box.
        marker_off_box,
        /// Ink inside a node box.
        ink_in_box,
        /// Connected ink that reaches fewer than two box borders.
        loose_ink,
        /// Connected ink that closes a loop: two routes between the same
        /// cells, so no reader can tell which edge is which.
        ink_cycle,
        /// Ink that no declared edge accounts for.
        unowned_ink,
        /// A drawing glyph outside the grammar.
        unknown_glyph,
    };
};

pub const Style = enum { neutral, solid, dotted, thick };

/// A place a trace ends: a node box or a subgraph frame, by index.
pub const Target = struct { frame: bool, index: u32 };

pub const Terminal = struct { cell: usize, target: Target, end: End };

pub const Scan = struct {
    width: usize,
    cells: usize,
    boxes: []const []const u8,
    frames: []const []const u8,
    terminals: []const Terminal,
    links: []const [2]usize,
    styles: []const Style,
    findings: std.ArrayList(Finding),
    clipped: bool,
};

const clip_marker = "»";
const clip: u21 = '»';

const n_arm: u4 = 1;
const e_arm: u4 = 2;
const s_arm: u4 = 4;
const w_arm: u4 = 8;
const d_row = [4]i8{ -1, 0, 1, 0 };
const d_col = [4]i8{ 0, 1, 0, -1 };

fn armBit(dir: u2) u4 {
    return @as(u4, 1) << dir;
}

fn opposite(dir: u2) u2 {
    return dir +% 2;
}

const Ink = struct { arms: u4, style: Style };

fn ink(cp: u21) ?Ink {
    const s: Style = .solid;
    const d: Style = .dotted;
    const t: Style = .thick;
    const x: Style = .neutral;
    return switch (cp) {
        '╵' => .{ .arms = n_arm, .style = s },
        '╶' => .{ .arms = e_arm, .style = s },
        '╷' => .{ .arms = s_arm, .style = s },
        '╴' => .{ .arms = w_arm, .style = s },
        '│' => .{ .arms = n_arm | s_arm, .style = s },
        '─' => .{ .arms = e_arm | w_arm, .style = s },
        '└', '╰' => .{ .arms = n_arm | e_arm, .style = x },
        '┌', '╭' => .{ .arms = e_arm | s_arm, .style = x },
        '┐', '╮' => .{ .arms = s_arm | w_arm, .style = x },
        '┘', '╯' => .{ .arms = n_arm | w_arm, .style = x },
        '├' => .{ .arms = n_arm | e_arm | s_arm, .style = x },
        '┤' => .{ .arms = n_arm | s_arm | w_arm, .style = x },
        '┬' => .{ .arms = e_arm | s_arm | w_arm, .style = x },
        '┴' => .{ .arms = n_arm | e_arm | w_arm, .style = x },
        '┼' => .{ .arms = 15, .style = x },
        '┊' => .{ .arms = n_arm | s_arm, .style = d },
        '╌' => .{ .arms = e_arm | w_arm, .style = d },
        '║' => .{ .arms = n_arm | s_arm, .style = t },
        '═' => .{ .arms = e_arm | w_arm, .style = t },
        '╚' => .{ .arms = n_arm | e_arm, .style = t },
        '╔' => .{ .arms = e_arm | s_arm, .style = t },
        '╗' => .{ .arms = s_arm | w_arm, .style = t },
        '╝' => .{ .arms = n_arm | w_arm, .style = t },
        '╠' => .{ .arms = n_arm | e_arm | s_arm, .style = t },
        '╣' => .{ .arms = n_arm | s_arm | w_arm, .style = t },
        '╦' => .{ .arms = e_arm | s_arm | w_arm, .style = t },
        '╩' => .{ .arms = n_arm | e_arm | w_arm, .style = t },
        '╬' => .{ .arms = 15, .style = t },
        '╨', '╧' => .{ .arms = n_arm | e_arm | w_arm, .style = x },
        '╥', '╤' => .{ .arms = e_arm | s_arm | w_arm, .style = x },
        '╞' => .{ .arms = n_arm | e_arm | s_arm, .style = x },
        '╡' => .{ .arms = n_arm | s_arm | w_arm, .style = x },
        else => null,
    };
}

const Marker = struct { end: End, dir: ?u2 };

fn marker(cp: u21) ?Marker {
    return switch (cp) {
        '▲' => .{ .end = .filled, .dir = 0 },
        '▶', '►' => .{ .end = .filled, .dir = 1 },
        '▼' => .{ .end = .filled, .dir = 2 },
        '◀', '◄' => .{ .end = .filled, .dir = 3 },
        '△' => .{ .end = .open, .dir = 0 },
        '▷' => .{ .end = .open, .dir = 1 },
        '▽' => .{ .end = .open, .dir = 2 },
        '◁' => .{ .end = .open, .dir = 3 },
        '○' => .{ .end = .circle, .dir = null },
        '✕' => .{ .end = .cross, .dir = null },
        else => null,
    };
}

const top_left = [_]u21{ '┌', '╭', '╱', '<', '◇', '/' };
const top_right = [_]u21{ '┐', '╮', '╲', '>', '◇', '╱', '\\', clip };
const bottom_left = [_]u21{ '└', '╰', '╲', '<', '◇', '╱', '/' };
const bottom_right = [_]u21{ '┘', '╯', '╱', '>', '◇', '\\', clip };
const across = [_]u21{ '─', '═', '┬', '┴', '┼', '╤', '╧', '╥', '╨' };
const left_side = [_]u21{ '│', '(', '<', '├', '┤', '┼', '║', '╞', '╡' };
const right_side = [_]u21{ '│', ')', '>', '├', '┤', '┼', '║', '╞', '╡', clip };

// Box drawing and geometric shapes: the blocks the painter draws from.
fn drawing(cp: u21) bool {
    return (cp >= 0x2500 and cp <= 0x257F) or (cp >= 0x25A0 and cp <= 0x25FF) or cp == '✕' or cp == '►' or cp == '◄';
}

fn isText(cp: u21) bool {
    return cp != ' ' and ink(cp) == null and marker(cp) == null;
}

fn in(set: []const u21, cp: u21) bool {
    return std.mem.indexOfScalar(u21, set, cp) != null;
}

const Cell = struct { text: []const u8, cp: u21 };

const Owner = union(enum) { free, node_border: u32, node_inner: u32, frame: u32 };

const Rect = struct { top: usize, left: usize, bottom: usize, right: usize, title: ?[]const u8 };

const Reader = struct {
    arena: std.mem.Allocator,
    rows: []const []const Cell,
    width: usize,
    owner: []Owner,
    boxes: std.ArrayList([]const u8) = .empty,
    frames: std.ArrayList([]const u8) = .empty,
    terminals: std.ArrayList(Terminal) = .empty,
    links: std.AutoArrayHashMapUnmanaged([2]usize, void) = .empty,
    findings: std.ArrayList(Finding) = .empty,

    fn cp(self: *const Reader, r: usize, c: usize) u21 {
        if (r >= self.rows.len or c >= self.rows[r].len) return ' ';
        return self.rows[r][c].cp;
    }

    fn step(self: *const Reader, cell: usize, dir: u2) ?usize {
        const r: isize = @as(isize, @intCast(cell / self.width)) + d_row[dir];
        const c: isize = @as(isize, @intCast(cell % self.width)) + d_col[dir];
        if (r < 0 or c < 0 or r >= self.rows.len or c >= self.width) return null;
        return @as(usize, @intCast(r)) * self.width + @as(usize, @intCast(c));
    }

    fn at(self: *const Reader, cell: usize) u21 {
        return self.cp(cell / self.width, cell % self.width);
    }

    fn note(self: *Reader, kind: Finding.Kind, cell: usize) !void {
        try self.findings.append(self.arena, .{ .kind = kind, .row = cell / self.width, .col = cell % self.width });
    }

    fn link(self: *Reader, a: usize, b: usize) !void {
        try self.links.put(self.arena, .{ @min(a, b), @max(a, b) }, {});
    }

    fn inkAt(self: *const Reader, cell: usize) ?Ink {
        if (self.owner[cell] != .free) return null;
        return ink(self.at(cell));
    }

    fn markerAt(self: *const Reader, cell: usize) ?Marker {
        if (self.owner[cell] != .free) return null;
        return marker(self.at(cell));
    }

    fn targetOf(owner: Owner) ?Target {
        return switch (owner) {
            .node_border => |i| .{ .frame = false, .index = i },
            .frame => |i| .{ .frame = true, .index = i },
            else => null,
        };
    }

    fn terminal(self: *Reader, cell: usize, owner: Owner, end: End) !void {
        const target = targetOf(owner).?;
        for (self.terminals.items) |t| {
            if (t.cell == cell and t.end == end and std.meta.eql(t.target, target)) return;
        }
        try self.terminals.append(self.arena, .{ .cell = cell, .target = target, .end = end });
    }

    fn closeRect(self: *const Reader, top: usize, left: usize, right: usize) ?usize {
        var r = top + 1;
        while (r < self.rows.len) : (r += 1) {
            const l = self.cp(r, left);
            if (r > top + 1 and in(&bottom_left, l) and self.closesAt(top, left, right, r)) return r;
            if (!in(&left_side, l)) return null;
        }
        return null;
    }

    fn closesAt(self: *const Reader, top: usize, left: usize, right: usize, bottom: usize) bool {
        for (left + 1..right) |c| if (!in(&across, self.cp(bottom, c))) return false;
        if (!in(&bottom_right, self.cp(bottom, right))) return false;
        for (top + 1..bottom) |i| if (!in(&right_side, self.cp(i, right))) return false;
        return true;
    }

    fn findRect(self: *const Reader, top: usize, left: usize) !?Rect {
        var title: ?[]const u8 = null;
        var c = left + 1;
        while (c < self.width) : (c += 1) {
            const g = self.cp(top, c);
            if (in(&across, g)) continue;
            if (in(&top_right, g)) {
                const bottom = self.closeRect(top, left, c) orelse return null;
                return .{ .top = top, .left = left, .bottom = bottom, .right = c, .title = title };
            }
            if (g != ' ' or title != null or c != left + 2) return null;
            const start = c + 1;
            var k = start;
            while (k + 1 < self.width) : (k += 1) {
                const next = self.cp(top, k + 1);
                if (self.cp(top, k) == ' ' and (in(&across, next) or in(&top_right, next))) break;
            } else return null;
            var text: std.ArrayList(u8) = .empty;
            for (start..k) |i| try text.appendSlice(self.arena, self.rows[top][i].text);
            title = text.items;
            c = k;
        }
        return null;
    }

    fn interiorInk(self: *const Reader, rect: Rect, lo: usize, hi: usize) bool {
        for (rect.top + 1..rect.bottom) |r| for (lo..hi) |c| {
            const g = self.cp(r, c);
            if (ink(g) != null or marker(g) != null) return true;
        };
        return false;
    }

    fn contains(outer: Rect, inner: Rect) bool {
        return inner.top > outer.top and inner.bottom < outer.bottom and inner.left > outer.left and inner.right < outer.right;
    }

    fn isSubroutine(self: *const Reader, rect: Rect) bool {
        if (rect.right < rect.left + 3) return false;
        if (self.cp(rect.top, rect.left + 1) != '┬' or self.cp(rect.bottom, rect.left + 1) != '┴') return false;
        if (self.cp(rect.top, rect.right - 1) != '┬' or self.cp(rect.bottom, rect.right - 1) != '┴') return false;
        for (rect.top + 1..rect.bottom) |r| {
            if (self.cp(r, rect.left + 1) != '│' or self.cp(r, rect.right - 1) != '│') return false;
        }
        return true;
    }

    fn label(self: *const Reader, rect: Rect, lo: usize, hi: usize) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (rect.top + 1..rect.bottom) |r| {
            if (r > rect.top + 1) try out.append(self.arena, '\n');
            for (lo..hi) |c| if (c < self.rows[r].len) try out.appendSlice(self.arena, self.rows[r][c].text);
        }
        if (self.cp(rect.top, rect.right) == clip) try out.appendSlice(self.arena, "…");
        return out.items;
    }

    fn mark(self: *Reader, rect: Rect, border: Owner, inner: ?Owner) void {
        for (rect.top..rect.bottom + 1) |r| for (rect.left..rect.right + 1) |c| {
            const edge = r == rect.top or r == rect.bottom or c == rect.left or c == rect.right;
            const cell = r * self.width + c;
            if (edge) self.owner[cell] = border else if (inner) |o| self.owner[cell] = o;
        };
    }

    fn findBoxes(self: *Reader) !void {
        var rects: std.ArrayList(Rect) = .empty;
        for (self.rows, 0..) |row, r| for (row, 0..) |cell, c| {
            if (in(&top_left, cell.cp)) if (try self.findRect(r, c)) |rect| try rects.append(self.arena, rect);
        };
        for (rects.items) |rect| {
            var holds_box = false;
            for (rects.items) |other| holds_box = holds_box or contains(rect, other);
            if (rect.title != null or holds_box) {
                try self.frames.append(self.arena, rect.title orelse "");
                self.mark(rect, .{ .frame = @intCast(self.frames.items.len - 1) }, null);
                continue;
            }
            const sub = self.isSubroutine(rect);
            const lo = rect.left + @as(usize, if (sub) 2 else 1);
            const hi = rect.right - @as(usize, if (sub) 1 else 0);
            if (self.interiorInk(rect, lo, hi)) continue;
            const text = try self.label(rect, lo, hi);
            if (std.mem.trim(u8, text, " \n").len == 0) continue;
            try self.boxes.append(self.arena, text);
            const i: u32 = @intCast(self.boxes.items.len - 1);
            self.mark(rect, .{ .node_border = i }, .{ .node_inner = i });
            if (sub) for (rect.top + 1..rect.bottom) |r| {
                self.owner[r * self.width + rect.left + 1] = .{ .node_border = i };
                self.owner[r * self.width + rect.right - 1] = .{ .node_border = i };
            };
        }
    }

    // How many side-by-side runs or frames one run may cross in a row.
    const crossings = 6;

    // Where an arm leaving `from` toward `dir` lands once it has passed
    // whatever lies at `cell`.
    fn reach(self: *Reader, from: usize, cell: usize, dir: u2, jumps: u8) error{OutOfMemory}!void {
        const back = armBit(opposite(dir));
        const owner = self.owner[cell];
        switch (owner) {
            .node_border => return self.terminal(from, owner, .none),
            .node_inner => return self.note(.ink_in_box, cell),
            .frame => {
                const arms = if (ink(self.at(cell))) |k| k.arms else 0;
                if (arms & back != 0 and arms & armBit(dir) == 0) return self.terminal(from, owner, .none);
            },
            .free => {
                if (self.inkAt(cell)) |k| if (k.arms & back != 0) return self.link(from, cell);
                if (self.markerAt(cell)) |m| {
                    if (m.dir == null or m.dir.? == dir) return self.link(from, cell);
                    return self.note(.arm_into_marker, cell);
                }
                if (self.inkAt(cell) == null) {
                    if (jumps == crossings and self.inLabel(cell, dir)) return self.overLabel(from, cell, dir);
                    return self.note(.dangling_arm, from);
                }
            },
        }
        if (jumps == 0) return self.note(.dangling_arm, from);
        const beyond = self.step(cell, dir) orelse return self.note(.dangling_arm, from);
        return self.reach(from, beyond, dir, jumps - 1);
    }

    // Whether `cell` is label text, or the space between two words of a
    // label that a run in `dir` meets side-on.
    fn inLabel(self: *const Reader, cell: usize, dir: u2) bool {
        const g = self.at(cell);
        if (isText(g)) return true;
        if (g != ' ' or dir % 2 == 1) return false;
        const l = self.step(cell, 3) orelse return false;
        const r = self.step(cell, 1) orelse return false;
        return isText(self.at(l)) and isText(self.at(r));
    }

    // An edge label written on a run interrupts it; the run resumes on the
    // label's far side, in line.
    fn overLabel(self: *Reader, from: usize, first: usize, dir: u2) error{OutOfMemory}!void {
        const limit: usize = if (dir % 2 == 0) 4 else 64;
        var cell = first;
        for (0..limit) |_| {
            const next = self.step(cell, dir) orelse break;
            const g = self.at(next);
            const gap = g == ' ' and dir % 2 == 1 and if (self.step(next, dir)) |n| isText(self.at(n)) else false;
            if (self.owner[next] != .free or !(self.inLabel(next, dir) or gap)) return self.reach(from, next, dir, 0);
            cell = next;
        }
        return self.note(.dangling_arm, from);
    }

    fn traceArms(self: *Reader) !void {
        for (self.owner, 0..) |o, cell| {
            if (o != .free) continue;
            const g = self.at(cell);
            if (drawing(g) and ink(g) == null and marker(g) == null) try self.note(.unknown_glyph, cell);
            const k = ink(g) orelse continue;
            for (0..4) |i| {
                const dir: u2 = @intCast(i);
                if (k.arms & armBit(dir) == 0) continue;
                const next = self.step(cell, dir) orelse {
                    try self.note(.dangling_arm, cell);
                    continue;
                };
                try self.reach(cell, next, dir, crossings);
            }
        }
    }

    fn traceMarkers(self: *Reader) !void {
        for (self.owner, 0..) |o, cell| {
            if (o != .free) continue;
            const m = marker(self.at(cell)) orelse continue;
            if (m.dir) |dir| {
                try self.markerEnds(cell, m.end, dir);
                for ([_]u2{ dir +% 1, dir +% 3 }) |side| {
                    const n = self.step(cell, side) orelse continue;
                    if (self.inkAt(n)) |k| if (k.arms & armBit(opposite(side)) != 0) try self.note(.arm_into_marker, n);
                }
                continue;
            }
            var boxes_seen: u8 = 0;
            for (0..4) |i| {
                const n = self.step(cell, @intCast(i)) orelse continue;
                if (self.owner[n] == .node_border) boxes_seen += 1;
            }
            for (0..4) |i| {
                const dir: u2 = @intCast(i);
                const n = self.step(cell, dir) orelse continue;
                if (self.owner[n] != .node_border) continue;
                const base = self.step(cell, opposite(dir));
                if (boxes_seen == 1 or (base != null and self.owner[base.?] == .node_border)) {
                    try self.markerEnds(cell, m.end, dir);
                    break;
                }
            }
        }
    }

    fn markerEnds(self: *Reader, cell: usize, end: End, dir: u2) !void {
        const tip = self.step(cell, dir);
        if (tip) |t| switch (self.owner[t]) {
            .node_border, .frame => try self.terminal(cell, self.owner[t], end),
            else => try self.note(.marker_off_box, cell),
        } else try self.note(.marker_off_box, cell);
        const base = self.step(cell, opposite(dir)) orelse return;
        switch (self.owner[base]) {
            .node_border => try self.terminal(cell, self.owner[base], .none),
            .free => if (self.markerAt(base)) |other| {
                if (other.dir == null or other.dir.? == opposite(dir)) try self.link(cell, base);
            },
            else => {},
        }
    }
};

// Parses painted text into cells, one per display column.
fn grid(arena: std.mem.Allocator, text: []const u8) !struct { rows: []const []const Cell, width: usize, clipped: bool } {
    var rows: std.ArrayList([]const Cell) = .empty;
    var width: usize = 0;
    var clipped = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.endsWith(u8, line, clip_marker)) clipped = true;
        var cells: std.ArrayList(Cell) = .empty;
        var i: usize = 0;
        while (i < line.len) {
            const g = unicode.nextGlyph(line, i);
            if (g.bytes.len == 0) break;
            i += g.bytes.len;
            const single = (std.unicode.utf8ByteSequenceLength(g.bytes[0]) catch 1) == g.bytes.len;
            const code: u21 = if (single) std.unicode.utf8Decode(g.bytes) catch 0 else 0;
            try cells.append(arena, .{ .text = g.bytes, .cp = code });
            for (1..g.width) |_| try cells.append(arena, .{ .text = "", .cp = 0 });
        }
        width = @max(width, cells.items.len);
        try rows.append(arena, cells.items);
    }
    return .{ .rows = rows.items, .width = @max(width, 1), .clipped = clipped };
}

/// Reads the ink grammar of painted plain text.
pub fn scan(arena: std.mem.Allocator, text: []const u8) !Scan {
    const g = try grid(arena, text);
    const cells = g.rows.len * g.width;
    const owner = try arena.alloc(Owner, cells);
    @memset(owner, .free);
    var reader: Reader = .{ .arena = arena, .rows = g.rows, .width = g.width, .owner = owner };
    try reader.findBoxes();
    try reader.traceArms();
    try reader.traceMarkers();
    const styles = try arena.alloc(Style, cells);
    for (styles, 0..) |*style, cell| {
        style.* = if (reader.inkAt(cell)) |k| k.style else .neutral;
    }
    return .{
        .width = g.width,
        .cells = cells,
        .boxes = reader.boxes.items,
        .frames = reader.frames.items,
        .terminals = reader.terminals.items,
        .links = reader.links.keys(),
        .styles = styles,
        .findings = reader.findings,
        .clipped = g.clipped,
    };
}
