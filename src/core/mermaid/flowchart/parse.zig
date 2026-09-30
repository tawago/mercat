const std = @import("std");
const sg = @import("sem_graph.zig");
const cep = @import("parse/cluster_endpoints.zig");
const bt = @import("parse/builder_types.zig");
const scanner = @import("parse/scanner.zig");
const shape_reader = @import("parse/shape.zig");
const token = @import("parse/token.zig");

const Scanner = scanner.Scanner;
const Token = token.Token;
const Direction = sg.Direction;
const Node = sg.Node;
const Edge = sg.Edge;
const Cluster = sg.Cluster;
const ClassDef = sg.ClassDef;
const SemGraph = sg.SemGraph;
const NodeId = sg.NodeId;
const EdgeId = sg.EdgeId;
const ClusterId = sg.ClusterId;
const ClassId = sg.ClassId;

pub const ParseError = error{
    UnexpectedToken,
    UnterminatedSubgraph,
    InvalidDirection,
    InvalidNode,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !SemGraph {
    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_ptr.deinit();
        allocator.destroy(arena_ptr);
    }

    var p = Parser.init(arena_ptr.allocator(), source);
    try p.parseHeader();
    try p.parseBody();
    try bt.pruneEmptyClusters(p.aa, p.nodes_list.items, &p.clusters_list);

    const nodes = try p.materializeNodes();
    const edges = try p.edges_list.toOwnedSlice(p.aa);
    const clusters = try p.materializeClusters();
    const classes = try p.classes_list.toOwnedSlice(p.aa);

    return .{
        .direction = p.direction,
        .nodes = nodes,
        .edges = edges,
        .clusters = clusters,
        .classes = classes,
        .skipped_lines = p.skipped_lines,
        .arena = arena_ptr,
    };
}

const Parser = struct {
    aa: std.mem.Allocator,
    source: []const u8,
    lexer: Scanner,

    direction: Direction = .TD,
    skipped_lines: u32 = 0,
    node_index: std.StringHashMap(NodeId),
    class_index: std.StringHashMap(ClassId),
    cluster_index: std.StringHashMap(ClusterId),
    nodes_list: std.ArrayList(bt.NodeBuilder),
    edges_list: std.ArrayList(Edge),
    clusters_list: std.ArrayList(bt.ClusterBuilder),
    classes_list: std.ArrayList(ClassDef),
    cluster_stack: std.ArrayList(ClusterId),

    fn init(aa: std.mem.Allocator, source: []const u8) Parser {
        return .{
            .aa = aa,
            .source = source,
            .lexer = Scanner.init(source),
            .node_index = std.StringHashMap(NodeId).init(aa),
            .class_index = std.StringHashMap(ClassId).init(aa),
            .cluster_index = std.StringHashMap(ClusterId).init(aa),
            .nodes_list = .empty,
            .edges_list = .empty,
            .clusters_list = .empty,
            .classes_list = .empty,
            .cluster_stack = .empty,
        };
    }

    fn peek(self: *Parser) Token {
        return token.peek(self.lexer);
    }

    fn take(self: *Parser) Token {
        return token.next(&self.lexer);
    }

    fn currentCluster(self: *Parser) ?ClusterId {
        const n = self.cluster_stack.items.len;
        return if (n == 0) null else self.cluster_stack.items[n - 1];
    }

    fn parseHeader(self: *Parser) !void {
        while (self.peek().kind == .newline) _ = self.take();
        if (self.peek().kind != .header) return;
        _ = self.take();
        const t = self.peek();
        switch (t.kind) {
            .dir => {
                self.direction = token.direction(t.text);
                _ = self.take();
            },
            .newline, .eof, .semicolon => {},
            else => return ParseError.InvalidDirection,
        }
        const sep = self.peek().kind;
        if (sep == .newline or sep == .semicolon) _ = self.take();
    }

    fn parseBody(self: *Parser) !void {
        while (true) {
            const tok = self.peek();
            switch (tok.kind) {
                .eof => return,
                .newline, .semicolon, .end => {
                    _ = self.take();
                },
                .subgraph => {
                    _ = self.take();
                    try self.parseSubgraph();
                },
                .class_def => {
                    _ = self.take();
                    try self.parseClassDef();
                },
                .class => {
                    _ = self.take();
                    try self.parseClassAssignment();
                },
                .direction => self.skipLine(),
                else => try self.parseStatementRecovering(),
            }
        }
    }

    fn parseSubgraph(self: *Parser) !void {
        var raw_id: []const u8 = "";
        var label: []const u8 = "";
        const id_tok = self.peek();
        switch (id_tok.kind) {
            .id, .dir, .string => {
                _ = self.take();
                raw_id = id_tok.text;
                label = id_tok.text;
            },
            .newline, .eof => {},
            else => return ParseError.UnexpectedToken,
        }
        if (self.peek().kind == .open and self.peek().bracket == '[') {
            _ = self.take();
            label = try scanner.breaks(self.aa, self.lexer.rawUntil(']'));
        }
        self.skipLine();

        const cid: ClusterId = @intCast(self.clusters_list.items.len);
        const parent = self.currentCluster();
        try self.clusters_list.append(self.aa, .{
            .id = cid,
            .raw_id = raw_id,
            .label = label,
            .parent = parent,
            .members = .empty,
            .sub_clusters = .empty,
            .direction = null,
        });
        if (raw_id.len > 0) try self.cluster_index.put(raw_id, cid);
        if (parent) |pid| try self.clusters_list.items[pid].sub_clusters.append(self.aa, cid);
        try self.cluster_stack.append(self.aa, cid);
        defer _ = self.cluster_stack.pop();

        while (true) {
            const tok = self.peek();
            switch (tok.kind) {
                .eof => return ParseError.UnterminatedSubgraph,
                .newline, .semicolon => {
                    _ = self.take();
                },
                .end => {
                    _ = self.take();
                    self.skipLine();
                    return;
                },
                .subgraph => {
                    _ = self.take();
                    try self.parseSubgraph();
                },
                .direction => {
                    _ = self.take();
                    self.captureSubgraphDirection(cid);
                },
                .class_def => {
                    _ = self.take();
                    try self.parseClassDef();
                },
                .class => {
                    _ = self.take();
                    try self.parseClassAssignment();
                },
                else => try self.parseStatementRecovering(),
            }
        }
    }

    fn captureSubgraphDirection(self: *Parser, cid: ClusterId) void {
        const tok = self.peek();
        const dir: ?Direction = if (tok.kind == .dir) token.direction(tok.text) else null;
        if (dir) |d| self.clusters_list.items[cid].direction = d;
        self.skipLine();
    }

    fn parseClassDef(self: *Parser) !void {
        const name_tok = self.peek();
        if (name_tok.kind != .id) {
            self.skipLine();
            return;
        }
        _ = self.take();
        const style = self.lexer.restOfLine();
        const id: ClassId = @intCast(self.classes_list.items.len);
        try self.classes_list.append(self.aa, .{ .id = id, .name = name_tok.text, .style = style });
        try self.class_index.put(name_tok.text, id);
    }

    fn parseClassAssignment(self: *Parser) !void {
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(self.aa);
        while (true) {
            const tok = self.peek();
            if (tok.kind != .id) break;
            _ = self.take();
            try ids.append(self.aa, tok.text);
            if (self.peek().kind == .comma) {
                _ = self.take();
                continue;
            }
            break;
        }
        const cn = self.peek();
        if (cn.kind != .id) {
            self.skipLine();
            return;
        }
        _ = self.take();
        const class_id = try self.ensureClass(cn.text);
        for (ids.items) |raw| {
            const nid = try self.ensureNode(raw);
            try self.nodes_list.items[nid].classes.append(self.aa, class_id);
        }
        self.skipLine();
    }

    fn ensureClass(self: *Parser, name: []const u8) !ClassId {
        if (self.class_index.get(name)) |id| return id;
        const id: ClassId = @intCast(self.classes_list.items.len);
        try self.classes_list.append(self.aa, .{ .id = id, .name = name, .style = "" });
        try self.class_index.put(name, id);
        return id;
    }

    const Mark = struct {
        lexer: Scanner,
        nodes_len: usize,
        edges_len: usize,
        classes_len: usize,
    };

    fn markState(self: *Parser) Mark {
        return .{
            .lexer = self.lexer,
            .nodes_len = self.nodes_list.items.len,
            .edges_len = self.edges_list.items.len,
            .classes_len = self.classes_list.items.len,
        };
    }

    fn rollbackTo(self: *Parser, m: Mark) void {
        while (self.nodes_list.items.len > m.nodes_len) {
            const b = self.nodes_list.items[self.nodes_list.items.len - 1];
            _ = self.node_index.remove(b.raw_id);
            if (b.cluster) |cid| _ = self.clusters_list.items[cid].members.pop();
            self.nodes_list.shrinkRetainingCapacity(self.nodes_list.items.len - 1);
        }
        while (self.classes_list.items.len > m.classes_len) {
            const c = self.classes_list.items[self.classes_list.items.len - 1];
            _ = self.class_index.remove(c.name);
            self.classes_list.shrinkRetainingCapacity(self.classes_list.items.len - 1);
        }
        self.edges_list.shrinkRetainingCapacity(m.edges_len);
        self.lexer = m.lexer;
    }

    fn parseStatementRecovering(self: *Parser) ParseError!void {
        const tok = self.peek();
        if (tok.kind == .id and isSkippableDirective(tok.text)) {
            self.skipLine();
            return;
        }
        const m = self.markState();
        self.parseStatement() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                if (lineHasEdgeOperator(m.lexer)) return err;
                self.rollbackTo(m);
                self.skipLine();
                self.skipped_lines += 1;
            },
        };
    }

    fn lineHasEdgeOperator(from: Scanner) bool {
        var probe = from;
        while (true) {
            switch (token.next(&probe).kind) {
                .newline, .semicolon, .eof => return false,
                .link => return true,
                else => {},
            }
        }
    }

    fn parseStatement(self: *Parser) ParseError!void {
        var sources: std.ArrayList(NodeId) = .empty;
        defer sources.deinit(self.aa);
        var targets: std.ArrayList(NodeId) = .empty;
        defer targets.deinit(self.aa);

        try sources.append(self.aa, try self.parseStatementStartRef());
        while (self.peek().kind == .amp) {
            _ = self.take();
            try sources.append(self.aa, try self.parseTargetNodeRef());
        }
        while (true) {
            const tok = self.peek();
            const l = tok.link orelse break;
            _ = self.take();
            var elabel: ?[]const u8 = l.label;
            if (self.peek().kind == .pipe) {
                _ = self.take();
                elabel = self.lexer.rawUntil('|');
            }
            if (elabel) |el| elabel = try scanner.breaks(self.aa, el);
            targets.clearRetainingCapacity();
            try targets.append(self.aa, try self.parseTargetNodeRef());
            while (self.peek().kind == .amp) {
                _ = self.take();
                try targets.append(self.aa, try self.parseTargetNodeRef());
            }
            for (sources.items) |from_id| for (targets.items) |to_id| {
                const eid: EdgeId = @intCast(self.edges_list.items.len);
                try self.edges_list.append(self.aa, .{
                    .id = eid,
                    .from = from_id,
                    .to = to_id,
                    .kind = l.kind,
                    .arrow_from = l.from,
                    .arrow_to = l.to,
                    .label = elabel,
                });
            };
            std.mem.swap(std.ArrayList(NodeId), &sources, &targets);
        }
        switch (self.peek().kind) {
            .newline, .semicolon => _ = self.take(),
            .eof, .end => {},
            else => return ParseError.UnexpectedToken,
        }
    }

    fn parseStatementStartRef(self: *Parser) !NodeId {
        const id_tok = self.peek();
        if (id_tok.kind != .id and id_tok.kind != .dir) return ParseError.InvalidNode;
        _ = self.take();
        const next = self.peek().kind;
        if (!isNodeDeclarationTail(next) and (next == .link or next == .amp)) {
            if (self.cluster_index.get(id_tok.text)) |cid|
                return cep.clusterRepresentative(self.nodes_list.items, self.clusters_list.items, self.edges_list.items, cid, .source) catch ParseError.InvalidNode;
        }
        return self.finishNodeRef(id_tok.text);
    }

    fn parseTargetNodeRef(self: *Parser) !NodeId {
        const id_tok = self.peek();
        if (id_tok.kind != .id and id_tok.kind != .dir) return ParseError.InvalidNode;
        _ = self.take();
        if (!isNodeDeclarationTail(self.peek().kind)) {
            if (self.cluster_index.get(id_tok.text)) |cid|
                return cep.clusterRepresentative(self.nodes_list.items, self.clusters_list.items, self.edges_list.items, cid, .target) catch ParseError.InvalidNode;
        }
        return self.finishNodeRef(id_tok.text);
    }

    fn finishNodeRef(self: *Parser, raw_id: []const u8) !NodeId {
        const nid = try self.ensureNode(raw_id);
        if (self.peek().kind == .open) {
            const si = shape_reader.read(&self.lexer);
            self.nodes_list.items[nid].shape = si.shape;
            if (si.label.len > 0) self.nodes_list.items[nid].label = try scanner.breaks(self.aa, si.label);
        }
        try self.maybeInlineClass(nid);
        return nid;
    }

    fn maybeInlineClass(self: *Parser, nid: NodeId) !void {
        if (self.peek().kind != .colon) return;
        const saved = self.lexer;
        _ = self.take();
        if (self.peek().kind != .colon) {
            self.lexer = saved;
            return;
        }
        _ = self.take();
        if (self.peek().kind != .colon) {
            self.lexer = saved;
            return;
        }
        _ = self.take();
        const cn = self.peek();
        if (cn.kind != .id) return;
        _ = self.take();
        const class_id = try self.ensureClass(cn.text);
        try self.nodes_list.items[nid].classes.append(self.aa, class_id);
    }

    fn skipLine(self: *Parser) void {
        while (true) switch (self.peek().kind) {
            .newline, .semicolon => {
                _ = self.take();
                return;
            },
            .eof => return,
            else => _ = self.take(),
        };
    }

    fn ensureNode(self: *Parser, raw_id: []const u8) !NodeId {
        if (self.node_index.get(raw_id)) |id| return id;
        const id: NodeId = @intCast(self.nodes_list.items.len);
        try self.nodes_list.append(self.aa, .{
            .id = id,
            .raw_id = raw_id,
            .label = raw_id,
            .shape = .rect,
            .classes = .empty,
            .cluster = self.currentCluster(),
        });
        try self.node_index.put(raw_id, id);
        if (self.currentCluster()) |cid| try self.clusters_list.items[cid].members.append(self.aa, id);
        return id;
    }

    fn materializeNodes(self: *Parser) ![]const Node {
        const out = try self.aa.alloc(Node, self.nodes_list.items.len);
        for (self.nodes_list.items, 0..) |*b, i| out[i] = .{
            .id = b.id,
            .raw_id = b.raw_id,
            .label = b.label,
            .shape = b.shape,
            .classes = try b.classes.toOwnedSlice(self.aa),
            .cluster = b.cluster,
        };
        return out;
    }

    fn materializeClusters(self: *Parser) ![]const Cluster {
        const out = try self.aa.alloc(Cluster, self.clusters_list.items.len);
        for (self.clusters_list.items, 0..) |*b, i| out[i] = .{
            .id = b.id,
            .raw_id = b.raw_id,
            .label = b.label,
            .parent = b.parent,
            .members = try b.members.toOwnedSlice(self.aa),
            .sub_clusters = try b.sub_clusters.toOwnedSlice(self.aa),
            .direction = b.direction,
        };
        return out;
    }
};

fn isNodeDeclarationTail(k: token.Kind) bool {
    return k == .open or k == .colon;
}

fn isSkippableDirective(text: []const u8) bool {
    const names = [_][]const u8{ "click", "style", "linkStyle", "call" };
    for (names) |n| if (std.mem.eql(u8, text, n)) return true;
    return false;
}

test {
    _ = @import("parse/scanner_test.zig");
    _ = @import("parse/token_test.zig");
    _ = @import("parse/parse_test.zig");
}
