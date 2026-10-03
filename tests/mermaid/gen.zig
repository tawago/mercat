//! Seeded flowchart generator. One seed gives one source, always the same.
//! It samples the syntax a reader meets in practice: every direction, node
//! shapes (bracket and `@{ shape }` forms), every edge operator, both label
//! forms, `&` lists, chains, nested subgraphs with their own direction, edges
//! to a subgraph, self-loops, cycles, disconnected parts, wide characters,
//! `<br>` and `%%` comments.

const std = @import("std");

pub const Options = struct {
    max_nodes: u8 = 10,
    /// Node ids, indexed like `default_ids`; renaming keeps every random draw.
    ids: []const []const u8 = &default_ids,
    /// Give every node an explicit label, so the drawing does not show ids.
    labelled: bool = false,
};

const directions = [_][]const u8{ "TD", "TB", "BT", "LR", "RL" };
const shapes = [_][2][]const u8{
    .{ "[", "]" },   .{ "(", ")" },   .{ "{", "}" },     .{ "([", "])" },
    .{ "[[", "]]" }, .{ "[(", ")]" }, .{ "((", "))" },   .{ ">", "]" },
    .{ "{{", "}}" }, .{ "[/", "/]" }, .{ "[\\", "\\]" },
};
const at_shapes = [_][]const u8{ "rect", "rounded", "circle", "diamond", "hex", "cyl", "stadium" };
const operators = [_][]const u8{ "-->", "---", "-.->", "-.-", "==>", "===", "--o", "--x", "<-->", "o--o", "x--x", "~~~" };
const words = [_][]const u8{ "load", "parse", "check", "ok", "retry", "store", "emit", "user", "queue", "a longer label here", "日本語", "数据", "é" };
pub const default_ids = [_][]const u8{ "A", "B", "C", "D", "E", "F", "G", "H", "n1", "n2", "xy", "ox", "p9", "q", "r2", "x", "o" };

const Writer = struct {
    arena: std.mem.Allocator,
    rng: std.Random,
    options: Options,
    out: std.ArrayList(u8) = .empty,
    named: [default_ids.len]bool = @splat(false),

    fn put(self: *Writer, text: []const u8) !void {
        try self.out.appendSlice(self.arena, text);
    }

    fn label(self: *Writer) !void {
        const n = self.rng.intRangeAtMost(usize, 1, 2);
        for (0..n) |i| {
            if (i > 0) try self.put(if (self.rng.uintLessThan(u8, 10) == 0) "<br>" else " ");
            try self.put(words[self.rng.uintLessThan(usize, words.len)]);
        }
    }

    // A node reference; the first mention may carry a shape and label.
    fn node(self: *Writer, i: usize) !void {
        try self.put(self.options.ids[i]);
        if (self.named[i]) return;
        self.named[i] = true;
        const roll = self.rng.uintLessThan(u8, 100);
        if (self.options.labelled and roll >= 55) {
            try self.put("[");
            try self.label();
            try self.put("]");
        } else if (roll < 2) {
            try self.put("@{ shape: ");
            try self.put(at_shapes[self.rng.uintLessThan(usize, at_shapes.len)]);
            try self.put(", label: \"");
            try self.label();
            try self.put("\" }");
        } else if (roll < 55) {
            const s = shapes[self.rng.uintLessThan(usize, shapes.len)];
            try self.put(s[0]);
            try self.label();
            try self.put(s[1]);
        }
    }

    fn edge(self: *Writer) !void {
        const op = operators[self.rng.uintLessThan(usize, operators.len)];
        const labelled = self.rng.uintLessThan(u8, 5) == 0 and !std.mem.eql(u8, op, "~~~");
        try self.put(" ");
        if (labelled and std.mem.eql(u8, op, "-->") and self.rng.boolean()) {
            try self.put("-- ");
            try self.label();
            try self.put(" -->");
        } else {
            try self.put(op);
            if (labelled) {
                try self.put("|");
                try self.label();
                try self.put("|");
            }
        }
        try self.put(" ");
    }
};

/// The flowchart source for `seed`.
pub fn flowchart(arena: std.mem.Allocator, seed: u64, options: Options) ![]const u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    std.debug.assert(options.ids.len == default_ids.len);
    var w: Writer = .{ .arena = arena, .rng = prng.random(), .options = options };
    const rng = w.rng;
    const n = rng.intRangeAtMost(usize, 2, @min(options.max_nodes, default_ids.len));
    var pick: [default_ids.len]usize = undefined;
    for (&pick, 0..) |*p, i| p.* = i;
    rng.shuffle(usize, &pick);
    const nodes = pick[0..n];

    try w.put(if (rng.boolean()) "graph " else "flowchart ");
    try w.put(directions[rng.uintLessThan(usize, directions.len)]);
    try w.put("\n");
    if (rng.uintLessThan(u8, 6) == 0) try w.put("%% generated\n");

    const clustered = n >= 4 and rng.uintLessThan(u8, 5) < 2;
    if (clustered) {
        try w.put("subgraph S");
        if (rng.boolean()) {
            try w.put(" [");
            try w.label();
            try w.put("]");
        }
        try w.put("\n");
        if (rng.uintLessThan(u8, 3) == 0) {
            try w.put("  direction ");
            try w.put(directions[rng.uintLessThan(usize, directions.len)]);
            try w.put("\n");
        }
        const members = rng.intRangeAtMost(usize, 1, n / 2);
        if (members >= 2 and rng.boolean()) {
            try w.put("  subgraph T\n    ");
            try w.node(nodes[0]);
            try w.put("\n  end\n");
        }
        for (nodes[@intFromBool(members >= 2 and w.named[nodes[0]])..members]) |i| {
            try w.put("  ");
            try w.node(i);
            try w.put("\n");
        }
        try w.put("end\n");
    }

    for (1..n) |i| {
        if (rng.uintLessThan(u8, 8) == 0) continue;
        const from = nodes[rng.uintLessThan(usize, i)];
        const roll = rng.uintLessThan(u8, 12);
        if (roll == 0 and i + 1 < n) {
            try w.node(from);
            try w.put(" & ");
            try w.node(nodes[i + 1]);
            try w.edge();
            try w.node(nodes[i]);
        } else if (roll == 1 and i + 1 < n) {
            try w.node(from);
            try w.edge();
            try w.node(nodes[i]);
            try w.edge();
            try w.node(nodes[i + 1]);
        } else {
            try w.node(from);
            try w.edge();
            try w.node(nodes[i]);
        }
        try w.put("\n");
    }
    for (0..rng.uintLessThan(usize, n / 2 + 1)) |_| {
        try w.node(nodes[rng.uintLessThan(usize, n)]);
        try w.edge();
        try w.node(nodes[rng.uintLessThan(usize, n)]);
        try w.put("\n");
    }
    if (clustered and rng.uintLessThan(u8, 4) == 0) {
        try w.node(nodes[n - 1]);
        try w.put(" --> S\n");
    }
    for (nodes) |i| if (!w.named[i]) {
        try w.node(i);
        try w.put("\n");
    };
    return w.out.items;
}
