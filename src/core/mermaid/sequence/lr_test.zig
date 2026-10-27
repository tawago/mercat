const std = @import("std");
const unicode = @import("unicode");
const fixture = @import("tb_fixture_test.zig");

const testing = std.testing;
const at = fixture.at;

const three =
    \\sequenceDiagram
    \\    direction LR
    \\    participant A
    \\    participant B
    \\    participant C
    \\    A->>B: one
    \\    B->>C: two
    \\    C-->>A: three
;

const crowded =
    \\sequenceDiagram
    \\    direction LR
    \\    participant Client
    \\    participant Gateway
    \\    participant Auth
    \\    Client->>Gateway: request
    \\    Gateway->>Auth: verify
    \\    Auth-->>Gateway: ok
    \\    Client->>Auth: done
;

const every_kind =
    \\sequenceDiagram
    \\    direction LR
    \\    A->B: a
    \\    A-->B: b
    \\    A->>B: c
    \\    A-->>B: d
    \\    A-xB: e
    \\    A--xB: f
    \\    A-)B: g
    \\    A--)B: h
    \\    B->>B: again
;

const Grid = struct {
    text: []const u8,
    rows: [][]const u8,

    fn of(source: []const u8, width: u32) !Grid {
        const text = try fixture.drawn(source, width);
        return .{ .text = text, .rows = try fixture.lines(testing.allocator, text) };
    }

    fn deinit(self: Grid) void {
        testing.allocator.free(self.rows);
        testing.allocator.free(self.text);
    }

    fn find(self: Grid, needle: []const u8) [2]usize {
        for (self.rows, 0..) |row, r| {
            if (std.mem.indexOf(u8, row, needle)) |byte| return .{ r, unicode.displayWidth(row[0..byte]) };
        }
        unreachable;
    }

    fn lifelineRow(self: Grid, name: []const u8) usize {
        return self.find(name)[0];
    }
};

test "a label touches its message line: left of a downward line, right of an upward one" {
    const g = try Grid.of(three, 80);
    defer g.deinit();
    const one = g.find("one");
    try testing.expectEqual(@as(u21, '│'), at(g.rows[one[0]], one[1] + 3));
    const two = g.find("two");
    try testing.expectEqual(@as(u21, '│'), at(g.rows[two[0]], two[1] + 3));
    const up = g.find("three");
    try testing.expectEqual(@as(u21, '┆'), at(g.rows[up[0]], up[1] - 1));
}

test "a label lies in the gap its line enters last, the first one touching the receiver's lifeline row" {
    const g = try Grid.of(three, 80);
    defer g.deinit();
    const a = g.lifelineRow("A");
    const b = g.lifelineRow("B");
    const c = g.lifelineRow("C");
    try testing.expectEqual(b - 1, g.find("one")[0]);
    try testing.expectEqual(c - 1, g.find("two")[0]);
    try testing.expectEqual(a + 1, g.find("three")[0]);
}

test "a gap is as tall as the rows its labels own, and the boxes need" {
    const g = try Grid.of(three, 80);
    defer g.deinit();
    try testing.expectEqual(g.lifelineRow("A") + 3, g.lifelineRow("B"));
    try testing.expectEqual(g.lifelineRow("B") + 3, g.lifelineRow("C"));
    try testing.expectEqual(g.lifelineRow("C") + 2, g.rows.len);
}

test "neighbouring lines: no empty column when they point opposite ways, one when the same way" {
    const g = try Grid.of(three, 80);
    defer g.deinit();
    const one = g.find("one");
    const two = g.find("two");
    const line_one = one[1] + 3;
    const line_two = two[1] + 3;
    try testing.expectEqual(line_one + 2, line_two);
    try testing.expectEqual(line_two + 1, g.find("three")[1] - 1);
}

test "a hemmed label sits centered on its own line, which it interrupts, one line cell before the head" {
    const g = try Grid.of(crowded, 80);
    defer g.deinit();
    const ok = g.find("ok");
    const line = ok[1];
    try testing.expectEqual(@as(u21, '▲'), at(g.rows[g.lifelineRow("Gateway")], line));
    try testing.expectEqual(@as(u21, '┆'), at(g.rows[ok[0] - 1], line));
    try testing.expect(ok[0] - 1 > g.lifelineRow("Gateway"));
    try testing.expect(at(g.rows[ok[0]], line - 1) != ' ');
    try testing.expect(at(g.rows[ok[0]], line + 2) != ' ');
}

test "many participants and few messages flip to left-right, which fits where top-down cannot" {
    const source =
        \\sequenceDiagram
        \\    participant Client
        \\    participant Gateway
        \\    participant Auth
        \\    participant Users
        \\    participant Billing
        \\    participant Audit
        \\    Client->>Gateway: request
        \\    Gateway->>Auth: verify
        \\    Auth-->>Gateway: ok
        \\    Gateway->>Billing: charge
        \\    Billing->>Audit: log
    ;
    const g = try Grid.of(source, 40);
    defer g.deinit();
    try testing.expect(g.lifelineRow("Client") < g.lifelineRow("Audit"));
    for ([_][]const u8{ "request", "verify", "ok", "charge", "log" }) |word| _ = g.find(word);
}

test "names never shortened: a wide-glyph name fills its box exactly" {
    const source =
        \\sequenceDiagram
        \\    direction LR
        \\    participant S as 日本語サーバ
        \\    participant C
        \\    S->>C: hi
    ;
    const g = try Grid.of(source, 80);
    defer g.deinit();
    const r = g.find("日本語サーバ")[0];
    const border = g.rows[r - 1];
    const name_row = g.rows[r];
    const right = std.mem.indexOf(u8, name_row, "│┄").?;
    try testing.expectEqual(unicode.displayWidth(std.mem.trimEnd(u8, border, " ")), unicode.displayWidth(name_row[0 .. right + "│".len]));
}

test "every message kind is distinguishable left-right" {
    const g = try Grid.of(every_kind, 120);
    defer g.deinit();
    var cells: [8][2]u21 = undefined;
    const b = g.lifelineRow("B");
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" }, 0..) |label, i| {
        const col = g.find(label)[1] + 1;
        cells[i] = .{ at(g.rows[b - 2], col), at(g.rows[b], col) };
    }
    for (cells, 0..) |x, i| for (cells[i + 1 ..]) |y| try testing.expect(x[0] != y[0] or x[1] != y[1]);
}

test "no left-right label covers a message line, lifeline or box at any width: the ink overlay refuses it" {
    for ([_][]const u8{ three, crowded, every_kind }) |source| {
        const need = (try fixture.fit(source, 0)).too_wide;
        try testing.expectEqual(need, (try fixture.fit(source, need - 1)).too_wide);
        const g = try Grid.of(source, need);
        defer g.deinit();
        for (g.rows) |row| try testing.expect(unicode.displayWidth(row) <= need);
    }
}
