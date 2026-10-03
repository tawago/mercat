//! Flowchart source to SemGraph. Tolerant: a line without a link operator that fails to parse is
//! skipped and counted; a failing line with a link operator fails the whole parse.

const std = @import("std");
const sg = @import("sem_graph.zig");
const Builder = @import("parse/builder.zig").Builder;
const scanner = @import("parse/scanner.zig");
const shape_reader = @import("parse/shape.zig");
const token = @import("parse/token.zig");

const Scanner = scanner.Scanner;
const Token = token.Token;
const NodeId = sg.NodeId;

pub const ParseError = error{
    UnexpectedToken,
    UnterminatedSubgraph,
    InvalidDirection,
    InvalidNode,
    OutOfMemory,
};

/// The graph's memory belongs to its arena; free it with `deinit`. Ids and labels that hold no
/// line break slice `source`, which must outlive the graph.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!sg.SemGraph {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    var p: Parser = .{ .sc = Scanner.init(source), .b = Builder.init(arena.allocator()) };
    try p.header();
    try p.body();
    const built = try p.b.finish();
    return .{
        .direction = p.direction,
        .nodes = built.nodes,
        .edges = built.edges,
        .clusters = built.clusters,
        .classes = &.{},
        .skipped_lines = p.skipped,
        .arena = arena,
    };
}

const Parser = struct {
    sc: Scanner,
    b: Builder,
    direction: sg.Direction = .TD,
    skipped: u32 = 0,
    sources: std.ArrayList(NodeId) = .empty,
    targets: std.ArrayList(NodeId) = .empty,
    names: std.ArrayList([]const u8) = .empty,

    fn peek(p: *Parser) Token {
        return token.peek(p.sc);
    }

    fn take(p: *Parser) Token {
        return token.next(&p.sc);
    }

    /// Consumes tokens through the next newline or semicolon.
    fn skipLine(p: *Parser) void {
        while (true) switch (p.take().kind) {
            .newline, .semicolon, .eof => return,
            else => {},
        };
    }

    fn header(p: *Parser) ParseError!void {
        while (p.peek().kind == .newline) _ = p.take();
        if (p.peek().kind != .header) return;
        _ = p.take();
        const t = p.peek();
        switch (t.kind) {
            .dir => {
                p.direction = token.direction(t.text);
                _ = p.take();
            },
            .newline, .eof, .semicolon => {},
            else => return error.InvalidDirection,
        }
        const sep = p.peek().kind;
        if (sep == .newline or sep == .semicolon) _ = p.take();
    }

    fn body(p: *Parser) ParseError!void {
        while (true) {
            switch (p.peek().kind) {
                .eof => {
                    if (p.b.open != null) return error.UnterminatedSubgraph;
                    return;
                },
                .newline, .semicolon => _ = p.take(),
                .end => {
                    _ = p.take();
                    if (p.b.closeCluster()) p.skipLine();
                },
                .subgraph => {
                    _ = p.take();
                    try p.openSubgraph();
                },
                .class_def => {
                    _ = p.take();
                    p.classDef();
                },
                .class => {
                    _ = p.take();
                    try p.classAssignment();
                },
                .direction => {
                    _ = p.take();
                    p.subgraphDirection();
                },
                else => try p.statementOrSkip(),
            }
        }
    }

    fn openSubgraph(p: *Parser) ParseError!void {
        var raw_id: []const u8 = "";
        const t = p.peek();
        switch (t.kind) {
            .id, .dir, .string => {
                _ = p.take();
                raw_id = t.text;
            },
            .newline, .eof => {},
            else => return error.UnexpectedToken,
        }
        var label = raw_id;
        const o = p.peek();
        if (o.kind == .open and o.bracket == '[') {
            _ = p.take();
            label = try scanner.breaks(p.b.a, p.sc.rawUntil(']'));
        }
        p.skipLine();
        try p.b.openCluster(raw_id, label);
    }

    fn subgraphDirection(p: *Parser) void {
        const t = p.peek();
        if (t.kind == .dir) p.b.setDirection(token.direction(t.text));
        p.skipLine();
    }

    /// A style definition names no node and changes no shape; it is read past.
    fn classDef(p: *Parser) void {
        if (p.peek().kind != .id) return p.skipLine();
        _ = p.take();
        p.sc.skipRest();
    }

    /// `class A,B name` declares the listed nodes when a class name follows them.
    fn classAssignment(p: *Parser) ParseError!void {
        p.names.clearRetainingCapacity();
        while (p.peek().kind == .id) {
            try p.names.append(p.b.a, p.take().text);
            if (p.peek().kind != .comma) break;
            _ = p.take();
        }
        if (p.peek().kind == .id) {
            for (p.names.items) |name| _ = try p.b.node(name);
        }
        p.skipLine();
    }

    fn statementOrSkip(p: *Parser) ParseError!void {
        const t = p.peek();
        if (t.kind == .id and isIgnoredDirective(t.text)) return p.skipLine();
        const start = p.sc;
        const mark = p.b.begin();
        p.statement() catch |err| {
            if (err == error.OutOfMemory or lineHasLink(start)) return err;
            p.b.rollback(mark);
            p.sc = start;
            p.skipLine();
            p.skipped += 1;
        };
    }

    fn statement(p: *Parser) ParseError!void {
        const a = p.b.a;
        p.sources.clearRetainingCapacity();
        try p.sources.append(a, try p.ref(true));
        while (p.peek().kind == .amp) {
            _ = p.take();
            try p.sources.append(a, try p.ref(false));
        }
        while (true) {
            const link = p.peek().link orelse break;
            _ = p.take();
            var label = link.label;
            if (p.peek().kind == .pipe) {
                _ = p.take();
                label = p.sc.rawUntil('|');
            }
            if (label) |text| label = try scanner.breaks(a, text);
            p.targets.clearRetainingCapacity();
            try p.targets.append(a, try p.ref(false));
            while (p.peek().kind == .amp) {
                _ = p.take();
                try p.targets.append(a, try p.ref(false));
            }
            for (p.sources.items) |from| for (p.targets.items) |to| try p.b.addEdge(from, to, link, label);
            std.mem.swap(std.ArrayList(NodeId), &p.sources, &p.targets);
        }
        switch (p.peek().kind) {
            .newline, .semicolon => _ = p.take(),
            .eof, .end => {},
            else => return error.UnexpectedToken,
        }
    }

    /// A node reference, or the member a known subgraph id stands for when it is used bare as an
    /// endpoint: the first reference of a statement counts only when a link or `&` follows.
    fn ref(p: *Parser, first: bool) ParseError!NodeId {
        const t = p.peek();
        if (t.kind != .id and t.kind != .dir) return error.InvalidNode;
        _ = p.take();
        const after = p.peek().kind;
        const bare = after != .open and after != .colon;
        if (bare and (!first or after == .link or after == .amp)) {
            if (p.b.clusterNamed(t.text)) |cluster| {
                return p.b.representative(cluster, if (first) .source else .target) orelse error.InvalidNode;
            }
        }
        const id = try p.b.node(t.text);
        if (after == .open) {
            const shaped = shape_reader.read(&p.sc);
            const label = if (shaped.label.len > 0) try scanner.breaks(p.b.a, shaped.label) else null;
            p.b.declare(id, shaped.shape, label);
        }
        p.classSuffix();
        return id;
    }

    /// `:::name` after a node is read past.
    fn classSuffix(p: *Parser) void {
        var probe = p.sc;
        for (0..3) |_| if (token.next(&probe).kind != .colon) return;
        p.sc = probe;
        if (p.peek().kind == .id) _ = p.take();
    }
};

fn isIgnoredDirective(text: []const u8) bool {
    for ([_][]const u8{ "click", "style", "linkStyle", "call" }) |d| {
        if (std.mem.eql(u8, text, d)) return true;
    }
    return false;
}

fn lineHasLink(from: Scanner) bool {
    var sc = from;
    while (true) switch (token.next(&sc).kind) {
        .newline, .semicolon, .eof => return false,
        .link => return true,
        else => {},
    };
}

test {
    _ = @import("parse/builder_test.zig");
    _ = @import("parse/parse_test.zig");
    _ = @import("parse/scanner_test.zig");
    _ = @import("parse/token_test.zig");
}
