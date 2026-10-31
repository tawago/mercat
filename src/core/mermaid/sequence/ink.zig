//! The cell owner overlay: every cell of a sequence drawing belongs to one participant (box,
//! lifeline, activation), message, label, note or fragment, and only the overwrites below are
//! legal. Any other overwrite is a layout bug and fails the drawing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Line = @import("tb_text.zig").Line;
const Canvas = @import("../shared/canvas.zig").Canvas;

pub const Owner = enum(u8) { none, box, lifeline, bar, stroke, label, note, frame };

pub const Cell = struct { glyph: u21 = ' ', owner: Owner = .none };

pub const Run = struct { x: i32, y: i32, bytes: []const u8 };

pub const Error = error{ InkConflict, OffCanvas } || Allocator.Error;

pub fn legal(old: Owner, new: Owner) bool {
    if (old == .none) return true;
    return switch (new) {
        .stroke => old == .lifeline,
        .note => old == .lifeline or old == .bar,
        .frame => old == .lifeline or old == .bar,
        .bar => old == .bar,
        else => false,
    };
}

pub const Ink = struct {
    arena: Allocator,
    width: u32,
    height: u32,
    cells: []Cell,
    runs: std.ArrayList(Run) = .empty,

    pub fn init(arena: Allocator, width: u32, height: u32) !Ink {
        const cells = try arena.alloc(Cell, @as(usize, width) * height);
        @memset(cells, .{});
        return .{ .arena = arena, .width = width, .height = height, .cells = cells };
    }

    pub fn at(self: *const Ink, x: i32, y: i32) ?*Cell {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return null;
        return &self.cells[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))];
    }

    pub fn owner(self: *const Ink, x: i32, y: i32) Owner {
        const cell = self.at(x, y) orelse return .none;
        return cell.owner;
    }

    pub fn put(self: *Ink, x: i32, y: i32, glyph: u21, who: Owner) Error!void {
        const cell = self.at(x, y) orelse return error.OffCanvas;
        if (!legal(cell.owner, who)) return error.InkConflict;
        cell.* = .{ .glyph = glyph, .owner = who };
    }

    /// A line of text: its cells become `who`'s, drawn whole by the painter.
    pub fn text(self: *Ink, x: i32, y: i32, line: Line, who: Owner) Error!void {
        var i: i32 = 0;
        while (i < line.width) : (i += 1) try self.put(x + i, y, ' ', who);
        try self.runs.append(self.arena, .{ .x = x, .y = y, .bytes = line.bytes });
    }

    pub fn toText(ink: *const Ink, allocator: Allocator) ![]const u8 {
        var canvas = try Canvas.init(ink.arena, ink.width, ink.height);
        for (0..ink.height) |y| {
            for (0..ink.width) |x| {
                const cell = ink.cells[y * ink.width + x];
                if (cell.glyph != ' ') canvas.setChar(@intCast(x), @intCast(y), cell.glyph, .node_border);
            }
        }
        for (ink.runs.items) |run| try canvas.drawTextSpanning(run.x, run.y, run.bytes, .node_text);
        return canvas.toString(allocator);
    }
};

pub const Box = struct { tl: u21, tr: u21, bl: u21, br: u21, h: u21 = '─', v: u21 = '│' };
pub const rounded = Box{ .tl = '╭', .tr = '╮', .bl = '╰', .br = '╯' };
pub const square = Box{ .tl = '┌', .tr = '┐', .bl = '└', .br = '┘' };

/// A box outline; `fill` also takes the cells inside it.
pub fn rect(ink: *Ink, left: i32, top: i32, right: i32, bottom: i32, style: Box, who: Owner, fill: bool) Error!void {
    var x = left;
    while (x <= right) : (x += 1) {
        var y = top;
        while (y <= bottom) : (y += 1) {
            const edge = y == top or y == bottom or x == left or x == right;
            if (!edge and !fill) continue;
            const g: u21 = if (y == top)
                (if (x == left) style.tl else if (x == right) style.tr else style.h)
            else if (y == bottom)
                (if (x == left) style.bl else if (x == right) style.br else style.h)
            else if (edge) style.v else ' ';
            try ink.put(x, y, g, who);
        }
    }
}

test {
    _ = @import("ink_test.zig");
}
