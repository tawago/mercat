//! Tests for `lexer.zig`. Token-level checks: kinds, text, bracket
//! fields, positional tokens, inline-label edges, and comment skipping.

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
    // By the time next() reaches the bracket-open branch, '<'/'-' edge
    // prefixes have already been ruled out, so a bare leading '>' (e.g.
    // asymmetric-shape syntax `A>label]`) must route to shape_open.
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
    // The label text itself contains a solo dash ("pre-check"). A connector
    // char only closes the label when followed by another connector char or
    // '.', so the lone dash inside the word must stay part of the label
    // instead of being mistaken for the start of the closing "-->" run.
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
    // Mermaid accepts labels tight against the connector runs: `A-.text.->B`
    // is the same edge as `A -. text .-> B`. The opening run here is just
    // "-." with no arrow, so the lexer must probe for the label even though
    // no whitespace follows.
    var lx = Lexer.init("A -.narrates.-> B\n");
    try t.expectEqualStrings("A", lx.next().text);
    const e = lx.next();
    try t.expectEqual(TokenKind.edge_dotted, e.kind);
    try t.expect(e.edge_label != null);
    try t.expectEqualStrings("narrates", e.edge_label.?);
    try t.expectEqualStrings("B", lx.next().text);

    // Labels with interior spaces and dashes stay intact in the tight form.
    var lx2 = Lexer.init("A -.captured as-we-build.-> B");
    _ = lx2.next();
    const e2 = lx2.next();
    try t.expectEqual(TokenKind.edge_dotted, e2.kind);
    try t.expectEqualStrings("captured as-we-build", e2.edge_label.?);

    // Tight solid and thick variants take the same path.
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

    // A short run with no closing connector before end-of-line still bails:
    // "--" followed by an identifier is not an edge.
    var lx5 = Lexer.init("A --B\n");
    _ = lx5.next();
    try t.expect(lx5.next().kind != TokenKind.edge_solid);

    // The pipe-label form keeps its own path: a short run before '|' bails
    // rather than swallowing the pipe text as an inline label.
    var lx6 = Lexer.init("A --|text| B\n");
    _ = lx6.next();
    try t.expect(lx6.next().kind != TokenKind.edge_solid);
}

test "solo CR (old Mac line ending) emits a newline token but does not bump the line counter" {
    // Only CRLF collapses into a single line-incrementing newline; a lone
    // '\r' with no following '\n' still tokenizes as .newline (advanceRaw
    // resets the column) but leaves the line counter unchanged, per
    // advanceRaw's "don't bump line for \r alone" contract.
    var lx = Lexer.init("A\rB");
    try t.expectEqual(@as(u32, 1), lx.next().line);
    const cr = lx.next();
    try t.expectEqual(TokenKind.newline, cr.kind);
    const b = lx.next();
    try t.expectEqual(@as(u32, 1), b.line);
}

test "leading '<' on an edge requires -/=/~ or tryEdge bails" {
    // Well-formed: '<' followed by a connector run lexes as one bidirectional
    // edge token.
    var ok = Lexer.init("A <--> B");
    try t.expectEqualStrings("A", ok.next().text);
    const e = ok.next();
    try t.expectEqual(TokenKind.edge_solid, e.kind);
    try t.expectEqualStrings("<-->", e.text);
    try t.expectEqualStrings("B", ok.next().text);

    // Malformed: '<' not followed by -/=/~ makes tryEdge bail, so the '<'
    // is re-lexed on its own as an error token instead of being absorbed
    // into a bogus edge.
    var bad = Lexer.init("A <xyz");
    try t.expectEqualStrings("A", bad.next().text);
    const err_tok = bad.next();
    try t.expectEqual(TokenKind.err, err_tok.kind);
    try t.expectEqualStrings("<", err_tok.text);
    try t.expectEqualStrings("xyz", bad.next().text);
}

test "double-ended circle/cross edges lex as one edge token with the marker text" {
    // o--o / x--x / x==x / o-.-o glue a leading circle/cross end-marker to the
    // connector: one edge_* token whose text carries both end markers, which
    // decodeArrows turns into from/to = circle/cross.
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
    // NEGATIVE guards: a bare or spaced leading o/x, or a longer word, stays a
    // normal identifier — the peekAt(1)-must-be-a-connector gate.
    try expectKinds("order --> next", &.{ .identifier, .edge_solid, .identifier });
    try expectKinds("x --> y", &.{ .identifier, .edge_solid, .identifier });
    // A node id `o` spaced from the connector keeps its identity.
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
    const bb = lx.next();
    try t.expectEqual(@as(u32, 2), bb.line);
    try t.expectEqual(@as(u32, 1), bb.col);
}
