const std = @import("std");

pub const Source = struct { path: []const u8, contents: []const u8 };

// A production edge is an `@import("....zig")` outside `test` blocks and outside `_ = @import(...)`
// aggregation lines. Test files are not nodes: they sit above the modules they exercise.
pub fn check(
    a: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    sources: []const Source,
) !void {
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (sources, 0..) |s, i| try index.put(a, s.path, i);

    const adj = try a.alloc(std.ArrayList(usize), sources.len);
    for (adj) |*list| list.* = .empty;
    for (sources, 0..) |s, i| {
        var targets: std.ArrayList([]const u8) = .empty;
        try productionImports(a, &targets, s.contents);
        for (targets.items) |target| {
            const resolved = try resolve(a, s.path, target) orelse continue;
            const j = index.get(resolved) orelse continue;
            try adj[i].append(a, j);
        }
    }

    var walk: Walk = .{
        .a = a,
        .adj = adj,
        .order = try a.alloc(?usize, sources.len),
        .low = try a.alloc(usize, sources.len),
        .on_stack = try a.alloc(bool, sources.len),
    };
    @memset(walk.order, null);
    @memset(walk.on_stack, false);
    for (0..sources.len) |v| {
        if (walk.order[v] == null) try walk.visit(v);
    }

    const ByPath = struct {
        sources: []const Source,
        fn less(ctx: @This(), x: usize, y: usize) bool {
            return std.mem.lessThan(u8, ctx.sources[x].path, ctx.sources[y].path);
        }
        fn firstLess(ctx: @This(), x: []usize, y: []usize) bool {
            return less(ctx, x[0], y[0]);
        }
    };
    const by_path: ByPath = .{ .sources = sources };

    var found: std.ArrayList([]usize) = .empty;
    for (walk.components.items) |members| {
        const cyclic = members.len > 1 or std.mem.indexOfScalar(usize, adj[members[0]].items, members[0]) != null;
        if (!cyclic) continue;
        const sorted = try a.dupe(usize, members);
        std.mem.sort(usize, sorted, by_path, ByPath.less);
        try found.append(a, sorted);
    }
    std.mem.sort([]usize, found.items, by_path, ByPath.firstLess);

    for (found.items) |members| {
        var names: std.ArrayList(u8) = .empty;
        for (members, 0..) |m, k| {
            if (k > 0) try names.appendSlice(a, ", ");
            try names.appendSlice(a, sources[m].path);
        }
        const msg = try std.fmt.allocPrint(
            a,
            "{s}: import cycle among {d} files: {s} (move what they share into a file none of them imports back)",
            .{ sources[members[0]].path, members.len, names.items },
        );
        try violations.append(a, msg);
    }
}

const Walk = struct {
    a: std.mem.Allocator,
    adj: []const std.ArrayList(usize),
    order: []?usize,
    low: []usize,
    on_stack: []bool,
    stack: std.ArrayList(usize) = .empty,
    next: usize = 0,
    components: std.ArrayList([]const usize) = .empty,

    fn visit(self: *Walk, v: usize) std.mem.Allocator.Error!void {
        self.order[v] = self.next;
        self.low[v] = self.next;
        self.next += 1;
        try self.stack.append(self.a, v);
        self.on_stack[v] = true;
        for (self.adj[v].items) |w| {
            if (self.order[w] == null) {
                try self.visit(w);
                self.low[v] = @min(self.low[v], self.low[w]);
            } else if (self.on_stack[w]) {
                self.low[v] = @min(self.low[v], self.order[w].?);
            }
        }
        if (self.low[v] != self.order[v].?) return;
        var members: std.ArrayList(usize) = .empty;
        while (true) {
            const w = self.stack.pop().?;
            self.on_stack[w] = false;
            try members.append(self.a, w);
            if (w == v) break;
        }
        try self.components.append(self.a, try members.toOwnedSlice(self.a));
    }
};

fn productionImports(a: std.mem.Allocator, out: *std.ArrayList([]const u8), contents: []const u8) !void {
    const needle = "@import(\"";
    var in_test = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (in_test) {
            if (std.mem.eql(u8, line, "}")) in_test = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "test ") or std.mem.eql(u8, line, "test {")) {
            in_test = std.mem.endsWith(u8, line, "{");
            continue;
        }
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (std.mem.startsWith(u8, trimmed, "_ = @import(")) continue;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, line, i, needle)) |start| {
            const open = start + needle.len;
            const end = std.mem.indexOfScalarPos(u8, line, open, '"') orelse break;
            i = end + 1;
            const target = line[open..end];
            if (std.mem.endsWith(u8, target, ".zig")) try out.append(a, target);
        }
    }
}

fn resolve(a: std.mem.Allocator, from: []const u8, target: []const u8) !?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (std.fs.path.dirname(from)) |dir| {
        var it = std.mem.tokenizeAny(u8, dir, "/\\");
        while (it.next()) |p| try parts.append(a, p);
    }
    var it = std.mem.tokenizeScalar(u8, target, '/');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.pop() == null) return null;
            continue;
        }
        try parts.append(a, p);
    }
    return try std.mem.join(a, "/", parts.items);
}

fn runCheck(a: std.mem.Allocator, sources: []const Source) ![]const []const u8 {
    var violations: std.ArrayList([]const u8) = .empty;
    try check(a, &violations, sources);
    return violations.items;
}

test "a chain that never returns is not a cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try runCheck(arena.allocator(), &.{
        .{ .path = "a.zig", .contents = "const b = @import(\"b.zig\");\nconst c = @import(\"c.zig\");\n" },
        .{ .path = "b.zig", .contents = "const c = @import(\"c.zig\");\n" },
        .{ .path = "c.zig", .contents = "const std = @import(\"std\");\n" },
    });
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a three-file ring and a separate pair are two reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try runCheck(arena.allocator(), &.{
        .{ .path = "a.zig", .contents = "const b = @import(\"b.zig\");\n" },
        .{ .path = "b.zig", .contents = "const c = @import(\"c.zig\");\n" },
        .{ .path = "c.zig", .contents = "const a = @import(\"a.zig\");\n" },
        .{ .path = "p.zig", .contents = "const q = @import(\"q.zig\");\n" },
        .{ .path = "q.zig", .contents = "const p = @import(\"p.zig\");\n" },
    });
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expect(std.mem.indexOf(u8, found[0], "3 files: a.zig, b.zig, c.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, found[1], "2 files: p.zig, q.zig") != null);
}

test "a file that imports itself is a cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try runCheck(arena.allocator(), &.{
        .{ .path = "a.zig", .contents = "const me = @import(\"a.zig\");\n" },
    });
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "test blocks, aggregation lines, comments and test files make no edges; an import after a closed test block does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b_imports_a: Source = .{ .path = "b.zig", .contents = "// const a = @import(\"a.zig\");\nconst a = @import(\"a.zig\"); // trailing\n" };
    const cases = [_]struct { a: []const u8, cycles: usize }{
        .{ .a = "const std = @import(\"std\");\n\ntest \"uses b\" {\n    const b = @import(\"b.zig\");\n    _ = b;\n}\n\ntest {\n    _ = @import(\"a_test.zig\");\n}\n", .cycles = 0 },
        .{ .a = "test \"x\" {\n}\n\nconst late = @import(\"b.zig\");\n", .cycles = 1 },
    };
    for (cases) |case| {
        const found = try runCheck(arena.allocator(), &.{ .{ .path = "a.zig", .contents = case.a }, b_imports_a });
        try std.testing.expectEqual(case.cycles, found.len);
    }
}

test "relative targets resolve against the importing file's directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try runCheck(arena.allocator(), &.{
        .{ .path = "layout/a.zig", .contents = "const u = @import(\"../util.zig\");\nconst s = @import(\"sib.zig\");\n" },
        .{ .path = "layout/sib.zig", .contents = "const std = @import(\"std\");\n" },
        .{ .path = "util.zig", .contents = "const a = @import(\"layout/a.zig\");\nconst out = @import(\"../../outside.zig\");\n" },
    });
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(std.mem.indexOf(u8, found[0], "layout/a.zig, util.zig") != null);
}
