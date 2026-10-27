//! Builds the top-down stages of one source for the tests: no tests of its own.

const std = @import("std");
const parse = @import("parse.zig");
const normalize = @import("normalize.zig");
const seq = @import("seq.zig");
const Texts = @import("tb_text.zig").Texts;
const tb_rows = @import("tb_rows.zig");
const tb_columns = @import("tb_columns.zig");
const render_mod = @import("render.zig");
const ladder = @import("../shared/ladder.zig");

pub const Stages = struct {
    arena: std.heap.ArenaAllocator,
    s: seq.Sequence,
    texts: Texts,
    rows: tb_rows.Rows,
    layout: tb_columns.Layout,

    pub fn deinit(self: *Stages) void {
        self.arena.deinit();
    }

    /// Breaks text `t` once and lays the state out again.
    pub fn breakText(self: *Stages, t: seq.TextIx, margin: u32) !void {
        _ = try self.texts.breakOnce(t);
        try self.relayout(margin);
    }

    pub fn relayout(self: *Stages, margin: u32) !void {
        const a = self.arena.allocator();
        self.rows = try tb_rows.build(a, &self.s, &self.texts);
        self.layout = try tb_columns.place(a, &self.s, &self.texts, &self.rows, margin);
    }
};

pub fn stages(source: []const u8, margin: u32) !Stages {
    var out: Stages = undefined;
    out.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer out.arena.deinit();
    const a = out.arena.allocator();
    var diagram = try parse.parse(a, source);
    out.s = try normalize.normalize(a, &diagram);
    out.texts = try Texts.init(a, out.s.texts);
    try out.relayout(margin);
    return out;
}

/// The drawing at `width`, or an error when it does not fit.
pub fn drawn(source: []const u8, width: u32) ![]const u8 {
    return switch (try render_mod.render(std.testing.allocator, source, width)) {
        .drawn => |text| text,
        .too_wide => error.TestUnexpectedResult,
    };
}

pub fn fit(source: []const u8, width: u32) !ladder.Fit {
    return render_mod.render(std.testing.allocator, source, width);
}

/// The display rows of a drawing.
pub fn lines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| try out.append(allocator, line);
    return out.toOwnedSlice(allocator);
}

/// The scalar at display column `col` of an all-narrow row, or a space past its end.
pub fn at(line: []const u8, col: usize) u21 {
    var view = std.unicode.Utf8View.initUnchecked(line);
    var it = view.iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) {
        if (i == col) return cp;
    }
    return ' ';
}

pub fn piercing_alternative() []const u8 {
    return
    \\sequenceDiagram
    \\    participant B as Browser
    \\    participant S as Server
    \\    participant D as Database
    \\    B->>S: POST /login
    \\    activate S
    \\    S->>D: find user
    \\    D-->>S: user row
    \\    alt password ok
    \\        S-->>B: 200 + token
    \\        B-->>S: hehe
    \\        activate B
    \\        B-->>S: hahaha
    \\        deactivate B
    \\        B-->>D: aaa
    \\    else bad password
    \\        S-->>B: 401
    \\    end
    \\    deactivate S
    ;
}
