const std = @import("std");
const lex = @import("lexer.zig");
const th = @import("token_helpers.zig");
const sg = @import("../sem_graph.zig");

const Lexer = lex.Lexer;
const TokenKind = lex.TokenKind;
const ArrowEnd = sg.ArrowEnd;
const t = std.testing;

fn expectKinds(src: []const u8, kinds: []const TokenKind) !void {
    var lx = Lexer.init(src);
    for (kinds) |k| {
        const tok = lx.next();
        try t.expectEqual(k, tok.kind);
    }
    try t.expectEqual(TokenKind.eof, lx.next().kind);
}

test "diagram opener with direction" {
    try expectKinds("flowchart TD\n", &.{ .kw_flowchart, .dir_td, .newline });
}

test "graph keyword aliases flowchart, all directions classify" {
    try expectKinds("graph LR", &.{ .kw_flowchart, .dir_lr });
    try expectKinds("graph BT", &.{ .kw_flowchart, .dir_bt });
    try expectKinds("graph RL", &.{ .kw_flowchart, .dir_rl });
    try expectKinds("graph TB", &.{ .kw_flowchart, .dir_td });
}

test "simple node and solid edge" {
    var lx = Lexer.init("A --> B\n");
    const a = lx.next();
    try t.expectEqual(TokenKind.identifier, a.kind);
    try t.expectEqualStrings("A", a.text);
    const e = lx.next();
    try t.expectEqual(TokenKind.edge_solid, e.kind);
    try t.expectEqualStrings("-->", e.text);
    try t.expectEqualStrings("B", lx.next().text);
    try t.expectEqual(TokenKind.newline, lx.next().kind);
    try t.expectEqual(TokenKind.eof, lx.next().kind);
}

test "edge variants" {
    try expectKinds("A --- B", &.{ .identifier, .edge_solid, .identifier });
    try expectKinds("A -.-> B", &.{ .identifier, .edge_dotted, .identifier });
    try expectKinds("A ==> B", &.{ .identifier, .edge_thick, .identifier });
    try expectKinds("A ~~~ B", &.{ .identifier, .edge_invisible, .identifier });
}

test "bracketed shape A[Hello]" {
    var lx = Lexer.init("A[Hello]");
    try t.expectEqualStrings("A", lx.next().text);
    const open = lx.next();
    try t.expectEqual(TokenKind.shape_open, open.kind);
    try t.expectEqual(@as(u8, '['), open.bracket);
    try t.expectEqual(@as(u8, 1), open.bracket_len);
    try t.expectEqualStrings("Hello", lx.next().text);
    const close = lx.next();
    try t.expectEqual(TokenKind.shape_close, close.kind);
    try t.expectEqual(@as(u8, ']'), close.bracket);
    try t.expectEqual(TokenKind.eof, lx.next().kind);
}

test "double brackets emit two shape_open tokens" {
    try expectKinds("A[[X]]", &.{
        .identifier, .shape_open, .shape_open, .identifier, .shape_close, .shape_close,
    });
}

test "edge label with pipes" {
    var lx = Lexer.init("A -->|maybe| B\n");
    try t.expectEqual(TokenKind.identifier, lx.next().kind);
    try t.expectEqual(TokenKind.edge_solid, lx.next().kind);
    try t.expectEqual(TokenKind.pipe, lx.next().kind);
    const lbl = lx.next();
    try t.expectEqual(TokenKind.identifier, lbl.kind);
    try t.expectEqualStrings("maybe", lbl.text);
    try t.expectEqual(TokenKind.pipe, lx.next().kind);
    try t.expectEqual(TokenKind.identifier, lx.next().kind);
    try t.expectEqual(TokenKind.newline, lx.next().kind);
}

test "subgraph block" {
    try expectKinds(
        "subgraph S\n  A\nend\n",
        &.{ .kw_subgraph, .identifier, .newline, .identifier, .newline, .kw_end, .newline },
    );
}

test "comment is skipped" {
    var lx = Lexer.init("%% this is ignored\nA\n");
    try t.expectEqual(TokenKind.newline, lx.next().kind);
    const id = lx.next();
    try t.expectEqual(TokenKind.identifier, id.kind);
    try t.expectEqualStrings("A", id.text);
    try t.expectEqual(TokenKind.newline, lx.next().kind);
    try t.expectEqual(TokenKind.eof, lx.next().kind);
}

test "string literal strips quotes" {
    var lx = Lexer.init("\"hello world\"");
    const tok = lx.next();
    try t.expectEqual(TokenKind.string, tok.kind);
    try t.expectEqualStrings("hello world", tok.text);
}

test "identifier may start with digit" {
    var lx = Lexer.init("1A 2B_3");
    try t.expectEqualStrings("1A", lx.next().text);
    try t.expectEqualStrings("2B_3", lx.next().text);
}

test "punctuation tokens" {
    try expectKinds("; , : &", &.{ .semicolon, .comma, .colon, .ampersand });
}

test "ampersand node lists tokenize" {
    try expectKinds("LB --> Web1 & Web2 & Web3", &.{
        .identifier, .edge_solid, .identifier, .ampersand, .identifier, .ampersand, .identifier,
    });
}

test "triple parens emit three shape_open/close tokens" {
    var lx = Lexer.init("S(((Start)))");
    try t.expectEqualStrings("S", lx.next().text);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const open = lx.next();
        try t.expectEqual(TokenKind.shape_open, open.kind);
        try t.expectEqual(@as(u8, '('), open.bracket);
    }
    try t.expectEqualStrings("Start", lx.next().text);
    i = 0;
    while (i < 3) : (i += 1) {
        const close = lx.next();
        try t.expectEqual(TokenKind.shape_close, close.kind);
        try t.expectEqual(@as(u8, ')'), close.bracket);
    }
    try t.expectEqual(TokenKind.eof, lx.next().kind);
}

test "peek does not advance" {
    var lx = Lexer.init("A B");
    try t.expectEqualStrings("A", lx.peek().text);
    try t.expectEqualStrings("A", lx.next().text);
    try t.expectEqualStrings("B", lx.next().text);
}

test "leading '>' lexes as shape_open, not an edge/arrow char" {
    var lx = Lexer.init(">Foo]");
    const open = lx.next();
    try t.expectEqual(TokenKind.shape_open, open.kind);
    try t.expectEqual(@as(u8, '>'), open.bracket);
    try t.expectEqual(@as(u8, 1), open.bracket_len);
    try t.expectEqualStrings("Foo", lx.next().text);
    try t.expectEqual(TokenKind.shape_close, lx.next().kind);
}

test "CRLF normalises to a single newline token" {
    try expectKinds("A\r\nB", &.{ .identifier, .newline, .identifier });
}

test "inline edge label keeps an embedded dash intact" {
    var lx = Lexer.init("A -- pre-check --> B\n");
    try t.expectEqualStrings("A", lx.next().text);
    const e = lx.next();
    try t.expectEqual(TokenKind.edge_solid, e.kind);
    try t.expect(e.edge_label != null);
    try t.expectEqualStrings("pre-check", e.edge_label.?);
    try t.expectEqualStrings("B", lx.next().text);
    try t.expectEqual(TokenKind.newline, lx.next().kind);
    try t.expectEqual(TokenKind.eof, lx.next().kind);
}

test "tight inline label on a dotted edge" {
    var lx = Lexer.init("A -.narrates.-> B\n");
    try t.expectEqualStrings("A", lx.next().text);
    const e = lx.next();
    try t.expectEqual(TokenKind.edge_dotted, e.kind);
    try t.expect(e.edge_label != null);
    try t.expectEqualStrings("narrates", e.edge_label.?);
    try t.expectEqualStrings("B", lx.next().text);

    var lx2 = Lexer.init("A -.captured as-we-build.-> B");
    _ = lx2.next();
    const e2 = lx2.next();
    try t.expectEqual(TokenKind.edge_dotted, e2.kind);
    try t.expectEqualStrings("captured as-we-build", e2.edge_label.?);

    var lx3 = Lexer.init("A --text--> B");
    _ = lx3.next();
    const e3 = lx3.next();
    try t.expectEqual(TokenKind.edge_solid, e3.kind);
    try t.expectEqualStrings("text", e3.edge_label.?);

    var lx4 = Lexer.init("A ==text==> B");
    _ = lx4.next();
    const e4 = lx4.next();
    try t.expectEqual(TokenKind.edge_thick, e4.kind);
    try t.expectEqualStrings("text", e4.edge_label.?);

    var lxd1 = Lexer.init("A -.ok.-> B\n");
    _ = lxd1.next();
    const ed1 = lxd1.next();
    try t.expectEqual(TokenKind.edge_dotted, ed1.kind);
    try t.expectEqualStrings("ok", ed1.edge_label.?);
    try t.expectEqualStrings("B", lxd1.next().text);

    var lxd3 = Lexer.init("A -.x.- B\n");
    _ = lxd3.next();
    const ed3 = lxd3.next();
    try t.expectEqual(TokenKind.edge_dotted, ed3.kind);
    try t.expectEqualStrings("x", ed3.edge_label.?);
    try t.expectEqualStrings("B", lxd3.next().text);

    var lx5 = Lexer.init("A --B\n");
    _ = lx5.next();
    try t.expect(lx5.next().kind != TokenKind.edge_solid);

    var lx6 = Lexer.init("A --|text| B\n");
    _ = lx6.next();
    try t.expect(lx6.next().kind != TokenKind.edge_solid);
}

test "glued o/x on a complete run is an arrow end whatever follows" {
    const Case = struct {
        src: []const u8,
        kind: TokenKind,
        to: ArrowEnd,
        node: []const u8,
    };
    for ([_]Case{
        .{ .src = "A --ok--> B\n", .kind = .edge_solid, .to = .circle, .node = "k" },
        .{ .src = "A --x1--> B\n", .kind = .edge_solid, .to = .cross, .node = "1" },
        .{ .src = "A --oops--> B\n", .kind = .edge_solid, .to = .circle, .node = "ops" },
        .{ .src = "A ==ok==> B\n", .kind = .edge_thick, .to = .circle, .node = "k" },
        .{ .src = "A ----ok----> B\n", .kind = .edge_solid, .to = .circle, .node = "k" },
        .{ .src = "A --oB[label] --> C\n", .kind = .edge_solid, .to = .circle, .node = "B" },
        .{ .src = "A--oB-->C\n", .kind = .edge_solid, .to = .circle, .node = "B" },
        .{ .src = "A--xB-->C\n", .kind = .edge_solid, .to = .cross, .node = "B" },
        .{ .src = "A-.-oB-.->C\n", .kind = .edge_dotted, .to = .circle, .node = "B" },
        .{ .src = "A==oB==>C\n", .kind = .edge_thick, .to = .circle, .node = "B" },
        .{ .src = "A --oB --> C\n", .kind = .edge_solid, .to = .circle, .node = "B" },
        .{ .src = "A --oB; C --> D\n", .kind = .edge_solid, .to = .circle, .node = "B" },
        .{ .src = "A --o|t| B\n", .kind = .edge_solid, .to = .circle, .node = "|" },
    }) |c| {
        var lx = Lexer.init(c.src);
        try t.expectEqualStrings("A", lx.next().text);
        const e = lx.next();
        try t.expectEqual(c.kind, e.kind);
        try t.expectEqual(@as(?[]const u8, null), e.edge_label);
        try t.expectEqual(c.to, th.decodeArrows(e.text).to);
        try t.expectEqualStrings(c.node, lx.next().text);
    }

    var lxi = Lexer.init("A -.ok.-> B\n");
    _ = lxi.next();
    const ei = lxi.next();
    try t.expectEqual(TokenKind.edge_dotted, ei.kind);
    try t.expectEqualStrings("ok", ei.edge_label.?);

    for ([_][]const u8{ "A --o B\n", "A --x B\n", "A --oB\n", "A -.-o B\n" }) |src| {
        var lxa = Lexer.init(src);
        _ = lxa.next();
        const ea = lxa.next();
        try t.expect(ea.kind == .edge_solid or ea.kind == .edge_dotted);
        try t.expect(ea.edge_label == null);
        try t.expectEqualStrings("B", lxa.next().text);
    }
}

test "solo CR (old Mac line ending) emits a newline token but does not bump the line counter" {
    var lx = Lexer.init("A\rB");
    try t.expectEqual(@as(u32, 1), lx.next().line);
    const cr = lx.next();
    try t.expectEqual(TokenKind.newline, cr.kind);
    const b = lx.next();
    try t.expectEqual(@as(u32, 1), b.line);
}

test "leading '<' on an edge requires -/=/~ or tryEdge bails" {
    var ok = Lexer.init("A <--> B");
    try t.expectEqualStrings("A", ok.next().text);
    const e = ok.next();
    try t.expectEqual(TokenKind.edge_solid, e.kind);
    try t.expectEqualStrings("<-->", e.text);
    try t.expectEqualStrings("B", ok.next().text);

    var bad = Lexer.init("A <xyz");
    try t.expectEqualStrings("A", bad.next().text);
    const err_tok = bad.next();
    try t.expectEqual(TokenKind.err, err_tok.kind);
    try t.expectEqualStrings("<", err_tok.text);
    try t.expectEqualStrings("xyz", bad.next().text);
}

test "double-ended circle/cross edges lex as one edge token with the marker text" {
    var a = Lexer.init("A o--o B");
    try t.expectEqualStrings("A", a.next().text);
    const ea = a.next();
    try t.expectEqual(TokenKind.edge_solid, ea.kind);
    try t.expectEqualStrings("o--o", ea.text);
    try t.expectEqualStrings("B", a.next().text);
    try t.expectEqual(ArrowEnd.circle, th.decodeArrows(ea.text).from);
    try t.expectEqual(ArrowEnd.circle, th.decodeArrows(ea.text).to);

    var b = Lexer.init("A x--x B");
    _ = b.next();
    const eb = b.next();
    try t.expectEqual(TokenKind.edge_solid, eb.kind);
    try t.expectEqualStrings("x--x", eb.text);
    try t.expectEqual(ArrowEnd.cross, th.decodeArrows(eb.text).from);
    try t.expectEqual(ArrowEnd.cross, th.decodeArrows(eb.text).to);

    var c = Lexer.init("A x==x B");
    _ = c.next();
    const ec = c.next();
    try t.expectEqual(TokenKind.edge_thick, ec.kind);
    try t.expectEqualStrings("x==x", ec.text);
    try t.expectEqual(ArrowEnd.cross, th.decodeArrows(ec.text).from);
    try t.expectEqual(ArrowEnd.cross, th.decodeArrows(ec.text).to);

    var d = Lexer.init("A o-.-o B");
    _ = d.next();
    const ed = d.next();
    try t.expectEqual(TokenKind.edge_dotted, ed.kind);
    try t.expectEqualStrings("o-.-o", ed.text);
    try t.expectEqual(ArrowEnd.circle, th.decodeArrows(ed.text).from);
    try t.expectEqual(ArrowEnd.circle, th.decodeArrows(ed.text).to);
}

test "leading o/x is an edge marker only when glued to a connector" {
    try expectKinds("order --> next", &.{ .identifier, .edge_solid, .identifier });
    try expectKinds("x --> y", &.{ .identifier, .edge_solid, .identifier });
    var lx = Lexer.init("o --> p");
    const id = lx.next();
    try t.expectEqual(TokenKind.identifier, id.kind);
    try t.expectEqualStrings("o", id.text);
    try t.expectEqual(TokenKind.edge_solid, lx.next().kind);
    try t.expectEqualStrings("p", lx.next().text);
}

test "line and column tracking" {
    var lx = Lexer.init("A\nBB");
    const a = lx.next();
    try t.expectEqual(@as(u32, 1), a.line);
    try t.expectEqual(@as(u32, 1), a.col);
    _ = lx.next();
    const rail = lx.next();
    try t.expectEqual(@as(u32, 2), rail.line);
    try t.expectEqual(@as(u32, 1), rail.col);
}
