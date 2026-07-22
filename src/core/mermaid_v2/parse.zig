//! Flowchart parser. Single-pass recursive-descent on `lexer.Lexer`
//! producing a `sem_graph.SemGraph` whose storage is owned by an internal
//! arena. Tolerant mode: known non-graph directives (`click`, `style`, ...)
//! are consumed without effect, and a statement that fails to parse is
//! skipped line-by-line (counted in `SemGraph.skipped_lines`) — unless the
//! line carries an edge operator, in which case the error propagates:
//! silently dropping an edge is worse than not rendering. Label text is
//! read raw from source between bracket pairs, bypassing the lexer.

const std = @import("std");
const lex = @import("parse/lexer.zig");
const sg = @import("sem_graph.zig");
const cep = @import("parse/cluster_endpoints.zig");
const th = @import("parse/token_helpers.zig");
const bt = @import("parse/builder_types.zig");
const sr = @import("parse/shape_reader.zig");

const Lexer = lex.Lexer;
const TokenKind = lex.TokenKind;
const Direction = sg.Direction;
const NodeShape = sg.NodeShape;
const EdgeKind = sg.EdgeKind;
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

/// Parses flowchart source into a SemGraph owning an arena. Caller must
/// call `result.deinit(allocator)` to release storage.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !SemGraph {
    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer { arena_ptr.deinit(); allocator.destroy(arena_ptr); }

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
    lexer: Lexer,

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
            .aa = aa, .source = source, .lexer = Lexer.init(source),
            .node_index = std.StringHashMap(NodeId).init(aa),
            .class_index = std.StringHashMap(ClassId).init(aa),
            .cluster_index = std.StringHashMap(ClusterId).init(aa),
            .nodes_list = .empty, .edges_list = .empty,
            .clusters_list = .empty, .classes_list = .empty,
            .cluster_stack = .empty,
        };
    }

    fn currentCluster(self: *Parser) ?ClusterId {
        const n = self.cluster_stack.items.len;
        return if (n == 0) null else self.cluster_stack.items[n - 1];
    }

    fn parseHeader(self: *Parser) !void {
        while (self.lexer.peek().kind == .newline) _ = self.lexer.next();
        if (self.lexer.peek().kind != .kw_flowchart) return;
        _ = self.lexer.next();
        switch (self.lexer.peek().kind) {
            .dir_td => { self.direction = .TD; _ = self.lexer.next(); },
            .dir_bt => { self.direction = .BT; _ = self.lexer.next(); },
            .dir_lr => { self.direction = .LR; _ = self.lexer.next(); },
            .dir_rl => { self.direction = .RL; _ = self.lexer.next(); },
            .newline, .eof, .semicolon => {},
            else => return ParseError.InvalidDirection,
        }
        const sep = self.lexer.peek().kind;
        if (sep == .newline or sep == .semicolon) _ = self.lexer.next();
    }

    fn parseBody(self: *Parser) !void {
        while (true) {
            const tok = self.lexer.peek();
            switch (tok.kind) {
                .eof => return,
                .newline, .semicolon, .kw_end => { _ = self.lexer.next(); },
                .kw_subgraph => { _ = self.lexer.next(); try self.parseSubgraph(); },
                .kw_classdef => { _ = self.lexer.next(); try self.parseClassDef(); },
                .kw_class => { _ = self.lexer.next(); try self.parseClassAssignment(); },
                .kw_direction => self.skipLine(),
                else => try self.parseStatementRecovering(),
            }
        }
    }

    fn parseSubgraph(self: *Parser) !void {
        var raw_id: []const u8 = "";
        var label: []const u8 = "";
        const id_tok = self.lexer.peek();
        switch (id_tok.kind) {
            .identifier, .dir_td, .dir_bt, .dir_lr, .dir_rl, .string => {
                _ = self.lexer.next();
                raw_id = id_tok.text;
                label = id_tok.text;
            },
            .newline, .eof => {},
            else => return ParseError.UnexpectedToken,
        }
        if (self.lexer.peek().kind == .shape_open and self.lexer.peek().bracket == '[') {
            _ = self.lexer.next();
            label = try th.normalizeLineBreaks(self.aa, sr.readRawUntilCloseChar(&self.lexer, ']'));
        }
        self.skipLine();

        const cid: ClusterId = @intCast(self.clusters_list.items.len);
        const parent = self.currentCluster();
        try self.clusters_list.append(self.aa, .{
            .id = cid, .raw_id = raw_id, .label = label, .parent = parent,
            .members = .empty, .sub_clusters = .empty, .direction = null,
        });
        if (raw_id.len > 0) try self.cluster_index.put(raw_id, cid);
        if (parent) |pid| try self.clusters_list.items[pid].sub_clusters.append(self.aa, cid);
        try self.cluster_stack.append(self.aa, cid);
        defer _ = self.cluster_stack.pop();

        while (true) {
            const tok = self.lexer.peek();
            switch (tok.kind) {
                .eof => return ParseError.UnterminatedSubgraph,
                .newline, .semicolon => { _ = self.lexer.next(); },
                .kw_end => { _ = self.lexer.next(); self.skipLine(); return; },
                .kw_subgraph => { _ = self.lexer.next(); try self.parseSubgraph(); },
                .kw_direction => { _ = self.lexer.next(); self.captureSubgraphDirection(cid); },
                .kw_classdef => { _ = self.lexer.next(); try self.parseClassDef(); },
                .kw_class => { _ = self.lexer.next(); try self.parseClassAssignment(); },
                else => try self.parseStatementRecovering(),
            }
        }
    }

    /// Reads the `dir_*` token following an in-subgraph `direction` line
    /// and records it on the cluster being built. Unknown/absent tokens
    /// leave the cluster's direction as inherited (null).
    fn captureSubgraphDirection(self: *Parser, cid: ClusterId) void {
        const tok = self.lexer.peek();
        const dir: ?Direction = switch (tok.kind) {
            .dir_td => .TD,
            .dir_bt => .BT,
            .dir_lr => .LR,
            .dir_rl => .RL,
            else => null,
        };
        if (dir) |d| self.clusters_list.items[cid].direction = d;
        self.skipLine();
    }

    fn parseClassDef(self: *Parser) !void {
        const name_tok = self.lexer.peek();
        if (name_tok.kind != .identifier) { self.skipLine(); return; }
        _ = self.lexer.next();
        const style = sr.readRestOfLine(&self.lexer);
        const id: ClassId = @intCast(self.classes_list.items.len);
        try self.classes_list.append(self.aa, .{ .id = id, .name = name_tok.text, .style = style });
        try self.class_index.put(name_tok.text, id);
    }

    fn parseClassAssignment(self: *Parser) !void {
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(self.aa);
        while (true) {
            const tok = self.lexer.peek();
            if (tok.kind != .identifier) break;
            _ = self.lexer.next();
            try ids.append(self.aa, tok.text);
            if (self.lexer.peek().kind == .comma) { _ = self.lexer.next(); continue; }
            break;
        }
        const cn = self.lexer.peek();
        if (cn.kind != .identifier) { self.skipLine(); return; }
        _ = self.lexer.next();
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

    /// Snapshot of the mutable parser state that a single statement can
    /// grow, for rollback when the statement fails to parse. (Class tags
    /// appended to PRE-existing nodes are not unwound — a stray class on a
    /// surviving node is cosmetic, unlike a phantom node or edge.)
    const Mark = struct {
        lexer: Lexer,
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
            // A rolled-back node is necessarily the last-appended member
            // of its cluster (later members were popped first).
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

    /// Run one statement with line-level recovery. Known non-graph
    /// directives (`click`, `style`, `linkStyle`, `call`) are consumed
    /// without effect. Any other statement that fails is rolled back and
    /// skipped (counted in `skipped_lines`) — unless its line contains an
    /// edge operator, in which case the parse error propagates so the
    /// caller falls back to echoing the source: a diagram missing an edge
    /// lies, a diagram missing a styling line does not.
    fn parseStatementRecovering(self: *Parser) ParseError!void {
        const tok = self.lexer.peek();
        if (tok.kind == .identifier and th.isSkippableDirective(tok.text)) {
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

    /// True if any token between `from`'s cursor and the next statement
    /// boundary (newline/semicolon/eof) is an edge operator. Probes a
    /// copy of the lexer; parser state is untouched.
    fn lineHasEdgeOperator(from: Lexer) bool {
        var probe = from;
        while (true) {
            const tk = probe.next();
            switch (tk.kind) {
                .newline, .semicolon, .eof => return false,
                else => if (edgeKind(tk.kind) != null) return true,
            }
        }
    }

    fn parseStatement(self: *Parser) ParseError!void {
        // `&`-joined node lists desugar to the cross-product of edges; sources/targets swap each hop to chain.
        // guarded-by: parse/parse_test.zig "ampersand both sides: cross-product with shapes and edge label"
        var sources: std.ArrayList(NodeId) = .empty;
        defer sources.deinit(self.aa);
        var targets: std.ArrayList(NodeId) = .empty;
        defer targets.deinit(self.aa);

        try sources.append(self.aa, try self.parseStatementStartRef());
        while (self.lexer.peek().kind == .ampersand) {
            _ = self.lexer.next();
            try sources.append(self.aa, try self.parseTargetNodeRef());
        }
        while (true) {
            const tok = self.lexer.peek();
            const ek = edgeKind(tok.kind) orelse break;
            const arrow = decodeArrows(tok.text);
            _ = self.lexer.next();
            // Inline-label form `-- text -->` carries its label on the edge
            // token; the `|...|` pipe form (which wins) supplies it trailing.
            var elabel: ?[]const u8 = tok.edge_label;
            if (self.lexer.peek().kind == .pipe) {
                _ = self.lexer.next();
                elabel = sr.readRawUntilCloseChar(&self.lexer, '|');
            }
            if (elabel) |el| elabel = try th.normalizeLineBreaks(self.aa, el);
            targets.clearRetainingCapacity();
            try targets.append(self.aa, try self.parseTargetNodeRef());
            while (self.lexer.peek().kind == .ampersand) {
                _ = self.lexer.next();
                try targets.append(self.aa, try self.parseTargetNodeRef());
            }
            for (sources.items) |from_id| for (targets.items) |to_id| {
                const eid: EdgeId = @intCast(self.edges_list.items.len);
                try self.edges_list.append(self.aa, .{
                    .id = eid, .from = from_id, .to = to_id, .kind = ek,
                    .arrow_from = arrow.from, .arrow_to = arrow.to, .label = elabel,
                });
            };
            std.mem.swap(std.ArrayList(NodeId), &sources, &targets);
        }
        switch (self.lexer.peek().kind) {
            .newline, .semicolon => _ = self.lexer.next(),
            .eof, .kw_end => {},
            else => return ParseError.UnexpectedToken,
        }
    }

    fn parseStatementStartRef(self: *Parser) !NodeId {
        const id_tok = self.lexer.peek();
        if (id_tok.kind != .identifier and !isDirectionKw(id_tok.kind)) return ParseError.InvalidNode;
        _ = self.lexer.next();
        const next = self.lexer.peek().kind;
        if (!isNodeDeclarationTail(next) and (edgeKind(next) != null or next == .ampersand)) {
            if (self.cluster_index.get(id_tok.text)) |cid|
                return cep.clusterRepresentative(self.nodes_list.items, self.clusters_list.items, self.edges_list.items, cid, .source) catch ParseError.InvalidNode;
        }
        return self.finishNodeRef(id_tok.text);
    }

    fn parseTargetNodeRef(self: *Parser) !NodeId {
        const id_tok = self.lexer.peek();
        if (id_tok.kind != .identifier and !isDirectionKw(id_tok.kind)) return ParseError.InvalidNode;
        _ = self.lexer.next();
        if (!isNodeDeclarationTail(self.lexer.peek().kind)) {
            if (self.cluster_index.get(id_tok.text)) |cid|
                return cep.clusterRepresentative(self.nodes_list.items, self.clusters_list.items, self.edges_list.items, cid, .target) catch ParseError.InvalidNode;
        }
        return self.finishNodeRef(id_tok.text);
    }

    fn finishNodeRef(self: *Parser, raw_id: []const u8) !NodeId {
        const nid = try self.ensureNode(raw_id);
        if (self.lexer.peek().kind == .shape_open) {
            const si = try sr.parseShape(&self.lexer);
            self.nodes_list.items[nid].shape = si.shape;
            if (si.label.len > 0) self.nodes_list.items[nid].label = try th.normalizeLineBreaks(self.aa, si.label);
        }
        try self.maybeInlineClass(nid);
        return nid;
    }

    fn maybeInlineClass(self: *Parser, nid: NodeId) !void {
        if (self.lexer.peek().kind != .colon) return;
        const saved = self.lexer;
        _ = self.lexer.next();
        if (self.lexer.peek().kind != .colon) { self.lexer = saved; return; }
        _ = self.lexer.next();
        if (self.lexer.peek().kind != .colon) { self.lexer = saved; return; }
        _ = self.lexer.next();
        const cn = self.lexer.peek();
        if (cn.kind != .identifier) return;
        _ = self.lexer.next();
        const class_id = try self.ensureClass(cn.text);
        try self.nodes_list.items[nid].classes.append(self.aa, class_id);
    }

    fn skipLine(self: *Parser) void {
        while (true) switch (self.lexer.peek().kind) {
            .newline, .semicolon => { _ = self.lexer.next(); return; },
            .eof => return,
            else => _ = self.lexer.next(),
        };
    }

    fn ensureNode(self: *Parser, raw_id: []const u8) !NodeId {
        if (self.node_index.get(raw_id)) |id| return id;
        const id: NodeId = @intCast(self.nodes_list.items.len);
        try self.nodes_list.append(self.aa, .{
            .id = id, .raw_id = raw_id, .label = raw_id, .shape = .rect,
            .classes = .empty, .cluster = self.currentCluster(),
        });
        try self.node_index.put(raw_id, id);
        if (self.currentCluster()) |cid| try self.clusters_list.items[cid].members.append(self.aa, id);
        return id;
    }

    fn materializeNodes(self: *Parser) ![]const Node {
        const out = try self.aa.alloc(Node, self.nodes_list.items.len);
        for (self.nodes_list.items, 0..) |*b, i| out[i] = .{
            .id = b.id, .raw_id = b.raw_id, .label = b.label, .shape = b.shape,
            .classes = try b.classes.toOwnedSlice(self.aa), .cluster = b.cluster,
        };
        return out;
    }

    fn materializeClusters(self: *Parser) ![]const Cluster {
        const out = try self.aa.alloc(Cluster, self.clusters_list.items.len);
        for (self.clusters_list.items, 0..) |*b, i| out[i] = .{
            .id = b.id, .raw_id = b.raw_id, .label = b.label, .parent = b.parent,
            .members = try b.members.toOwnedSlice(self.aa),
            .sub_clusters = try b.sub_clusters.toOwnedSlice(self.aa),
            .direction = b.direction,
        };
        return out;
    }
};

const decodeArrows = th.decodeArrows;
const isDirectionKw = th.isDirectionKw;
const isNodeDeclarationTail = th.isNodeDeclarationTail;
const edgeKind = th.edgeKind;
test {
    _ = @import("parse/parse_test.zig");
}
