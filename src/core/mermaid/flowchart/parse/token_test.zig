const std = @import("std");
const sg = @import("../sem_graph.zig");
const scanner = @import("scanner.zig");
const token = @import("token.zig");

const Scanner = scanner.Scanner;
const Kind = token.Kind;
const ArrowEnd = sg.ArrowEnd;
const EdgeKind = sg.EdgeKind;
const t = std.testing;

fn expectKinds(src: []const u8, kinds: []const Kind) !void {
    var sc = Scanner.init(src);
    for (kinds) |k| {
        const tok = token.next(&sc);
        try t.expectEqual(k, tok.kind);
    }
    try t.expectEqual(Kind.eof, token.next(&sc).kind);
}

fn expectLink(tok: token.Token, kind: EdgeKind) !void {
    try t.expectEqual(Kind.link, tok.kind);
    try t.expectEqual(kind, tok.link.?.kind);
}

test "identifier may start with digit" {
    var sc = Scanner.init("1A 2B_3");
    try t.expectEqualStrings("1A", token.next(&sc).text);
    try t.expectEqualStrings("2B_3", token.next(&sc).text);
}

test "leading '>' lexes as open, not an edge/arrow char" {
    var sc = Scanner.init(">Foo]");
    const open = token.next(&sc);
    try t.expectEqual(Kind.open, open.kind);
    try t.expectEqual(@as(u8, '>'), open.bracket);
    try t.expectEqualStrings("Foo", token.next(&sc).text);
    try t.expectEqual(Kind.close, token.next(&sc).kind);
}

test "CRLF normalises to a single newline token" {
    try expectKinds("A\r\nB", &.{ .id, .newline, .id });
}

test "inline edge label keeps an embedded dash intact" {
    var sc = Scanner.init("A -- pre-check --> B\n");
    try t.expectEqualStrings("A", token.next(&sc).text);
    const e = token.next(&sc);
    try expectLink(e, .solid);
    try t.expectEqualStrings("pre-check", e.link.?.label.?);
    try t.expectEqualStrings("B", token.next(&sc).text);
    try t.expectEqual(Kind.newline, token.next(&sc).kind);
    try t.expectEqual(Kind.eof, token.next(&sc).kind);
}

test "tight inline label on a dotted edge" {
    const Case = struct { src: []const u8, kind: EdgeKind, label: []const u8, node: []const u8 };
    for ([_]Case{
        .{ .src = "A -.narrates.-> B\n", .kind = .dotted, .label = "narrates", .node = "B" },
        .{ .src = "A -.captured as-we-build.-> B", .kind = .dotted, .label = "captured as-we-build", .node = "B" },
        .{ .src = "A --text--> B", .kind = .solid, .label = "text", .node = "B" },
        .{ .src = "A ==text==> B", .kind = .thick, .label = "text", .node = "B" },
        .{ .src = "A -.ok.-> B\n", .kind = .dotted, .label = "ok", .node = "B" },
        .{ .src = "A -.x.- B\n", .kind = .dotted, .label = "x", .node = "B" },
    }) |c| {
        var sc = Scanner.init(c.src);
        try t.expectEqualStrings("A", token.next(&sc).text);
        const e = token.next(&sc);
        try expectLink(e, c.kind);
        try t.expectEqualStrings(c.label, e.link.?.label.?);
        try t.expectEqualStrings(c.node, token.next(&sc).text);
    }

    var lx5 = Scanner.init("A --B\n");
    _ = token.next(&lx5);
    try t.expect(token.next(&lx5).kind != Kind.link);

    var lx6 = Scanner.init("A --|text| B\n");
    _ = token.next(&lx6);
    try t.expect(token.next(&lx6).kind != Kind.link);
}

test "glued o/x on a complete run is an arrow end whatever follows" {
    const Case = struct {
        src: []const u8,
        kind: EdgeKind,
        to: ArrowEnd,
        node: []const u8,
    };
    for ([_]Case{
        .{ .src = "A --ok--> B\n", .kind = .solid, .to = .circle, .node = "k" },
        .{ .src = "A --x1--> B\n", .kind = .solid, .to = .cross, .node = "1" },
        .{ .src = "A --oops--> B\n", .kind = .solid, .to = .circle, .node = "ops" },
        .{ .src = "A ==ok==> B\n", .kind = .thick, .to = .circle, .node = "k" },
        .{ .src = "A ----ok----> B\n", .kind = .solid, .to = .circle, .node = "k" },
        .{ .src = "A --oB[label] --> C\n", .kind = .solid, .to = .circle, .node = "B" },
        .{ .src = "A--oB-->C\n", .kind = .solid, .to = .circle, .node = "B" },
        .{ .src = "A--xB-->C\n", .kind = .solid, .to = .cross, .node = "B" },
        .{ .src = "A-.-oB-.->C\n", .kind = .dotted, .to = .circle, .node = "B" },
        .{ .src = "A==oB==>C\n", .kind = .thick, .to = .circle, .node = "B" },
        .{ .src = "A --oB --> C\n", .kind = .solid, .to = .circle, .node = "B" },
        .{ .src = "A --oB; C --> D\n", .kind = .solid, .to = .circle, .node = "B" },
        .{ .src = "A --o|t| B\n", .kind = .solid, .to = .circle, .node = "|" },
    }) |c| {
        var sc = Scanner.init(c.src);
        try t.expectEqualStrings("A", token.next(&sc).text);
        const e = token.next(&sc);
        try expectLink(e, c.kind);
        try t.expectEqual(@as(?[]const u8, null), e.link.?.label);
        try t.expectEqual(c.to, e.link.?.to);
        try t.expectEqualStrings(c.node, token.next(&sc).text);
    }

    var lxi = Scanner.init("A -.ok.-> B\n");
    _ = token.next(&lxi);
    const ei = token.next(&lxi);
    try expectLink(ei, .dotted);
    try t.expectEqualStrings("ok", ei.link.?.label.?);

    for ([_][]const u8{ "A --o B\n", "A --x B\n", "A --oB\n", "A -.-o B\n" }) |src| {
        var sc = Scanner.init(src);
        _ = token.next(&sc);
        const ea = token.next(&sc);
        try t.expectEqual(Kind.link, ea.kind);
        try t.expect(ea.link.?.kind == .solid or ea.link.?.kind == .dotted);
        try t.expect(ea.link.?.label == null);
        try t.expectEqualStrings("B", token.next(&sc).text);
    }
}

test "a lone CR emits a newline token" {
    var sc = Scanner.init("A\rB");
    try t.expectEqualStrings("A", token.next(&sc).text);
    try t.expectEqual(Kind.newline, token.next(&sc).kind);
    try t.expectEqualStrings("B", token.next(&sc).text);
}

test "leading '<' on an edge requires -/=/~ or the link read bails" {
    var ok = Scanner.init("A <--> B");
    try t.expectEqualStrings("A", token.next(&ok).text);
    const e = token.next(&ok);
    try expectLink(e, .solid);
    try t.expectEqualStrings("<-->", e.text);
    try t.expectEqualStrings("B", token.next(&ok).text);

    var bad = Scanner.init("A <xyz");
    try t.expectEqualStrings("A", token.next(&bad).text);
    const err_tok = token.next(&bad);
    try t.expectEqual(Kind.other, err_tok.kind);
    try t.expectEqualStrings("<", err_tok.text);
    try t.expectEqualStrings("xyz", token.next(&bad).text);
}

test "leading o/x is an edge marker only when glued to a connector" {
    try expectKinds("order --> next", &.{ .id, .link, .id });
    try expectKinds("x --> y", &.{ .id, .link, .id });
    var sc = Scanner.init("o --> p");
    const id = token.next(&sc);
    try t.expectEqual(Kind.id, id.kind);
    try t.expectEqualStrings("o", id.text);
    try t.expectEqual(Kind.link, token.next(&sc).kind);
    try t.expectEqualStrings("p", token.next(&sc).text);
}

test "both ends of a link read from its text; double-ended markers lex as one link; directions classify" {
    const Case = struct { src: []const u8, from: ArrowEnd, to: ArrowEnd, kind: ?EdgeKind = null };
    for ([_]Case{
        .{ .src = "-->", .from = .none, .to = .filled },
        .{ .src = "---", .from = .none, .to = .none },
        .{ .src = "<-->", .from = .filled, .to = .filled },
        .{ .src = "<--", .from = .filled, .to = .none },
        .{ .src = "~~~", .from = .none, .to = .none },
        .{ .src = "-- yes -->", .from = .none, .to = .filled },
        .{ .src = "-. maybe .-", .from = .none, .to = .none },
        .{ .src = "o--o", .from = .circle, .to = .circle, .kind = .solid },
        .{ .src = "x--x", .from = .cross, .to = .cross, .kind = .solid },
        .{ .src = "x==x", .from = .cross, .to = .cross, .kind = .thick },
        .{ .src = "o-.-o", .from = .circle, .to = .circle, .kind = .dotted },
    }) |c| {
        var sc = Scanner.init(c.src);
        const e = token.next(&sc);
        try t.expectEqual(Kind.link, e.kind);
        try t.expectEqual(c.from, e.link.?.from);
        try t.expectEqual(c.to, e.link.?.to);
        if (c.kind) |k| {
            try t.expectEqual(k, e.link.?.kind);
            try t.expectEqualStrings(c.src, e.text);
        }
        try t.expectEqual(Kind.eof, token.next(&sc).kind);
    }

    try expectKinds("graph TB", &.{ .header, .dir });
    for ([_]struct { []const u8, sg.Direction }{
        .{ "LR", .LR }, .{ "BT", .BT }, .{ "RL", .RL }, .{ "TB", .TD }, .{ "TD", .TD },
    }) |c| try t.expectEqual(c[1], token.direction(c[0]));
}

test "keywords are words that are not followed by more word bytes" {
    try expectKinds("end endx subgraph subgraphs class classDef classdef direction", &.{ .end, .id, .subgraph, .id, .class, .class_def, .class_def, .direction });
    try expectKinds("flowchart graph Graph", &.{ .header, .header, .id });
}
