const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Graph = types.Graph;
const Node = types.Node;
const Edge = types.Edge;
const Subgraph = types.Subgraph;
const Direction = types.Direction;
const NodeShape = types.NodeShape;
const EdgeStyle = types.EdgeStyle;
const ArrowHead = types.ArrowHead;
const DiagramType = types.DiagramType;
const SequenceDiagram = types.SequenceDiagram;
const Participant = types.Participant;
const Message = types.Message;
const SequenceArrowType = types.SequenceArrowType;
const ParticipantType = types.ParticipantType;
const ClassDiagram = types.ClassDiagram;
const Class = types.Class;
const ClassMember = types.ClassMember;
const ClassRelation = types.ClassRelation;
const ClassRelationType = types.ClassRelationType;
const Visibility = types.Visibility;
const ERDiagram = types.ERDiagram;
const Entity = types.Entity;
const EntityAttribute = types.EntityAttribute;
const ERRelation = types.ERRelation;
const Cardinality = types.Cardinality;
const StateDiagram = types.StateDiagram;
const State = types.State;
const StateTransition = types.StateTransition;
const StateType = types.StateType;

pub const ParseError = error{
    InvalidSyntax,
    UnexpectedEnd,
    InvalidDirection,
    InvalidNodeShape,
    OutOfMemory,
};

pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize = 0,
    line: usize = 1,

    pub fn init(allocator: Allocator, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn parse(allocator: Allocator, source: []const u8) !Graph {
        var parser = Parser.init(allocator, source);
        return parser.parseGraph();
    }

    fn parseGraph(self: *Parser) !Graph {
        var graph = Graph.init(self.allocator);
        errdefer graph.deinit();

        self.skipWhitespaceAndComments();

        const diagram_type = DiagramType.fromSource(self.source[self.pos..]);
        graph.diagram_type = diagram_type;

        if (diagram_type == .flowchart) {
            if (self.consumeKeyword("graph") or self.consumeKeyword("flowchart")) {
                self.skipWhitespace();
                graph.direction = self.parseDirection();
            }
        } else if (diagram_type == .sequence) {
            _ = self.consumeKeyword("sequenceDiagram");
        }

        self.skipToNextLine();

        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;

            if (self.consumeKeyword("subgraph")) {
                try self.parseSubgraph(&graph, null);
                continue;
            }

            if (self.consumeKeyword("end")) {
                self.skipToNextLine();
                continue;
            }

            if (self.consumeKeyword("style") or
                self.consumeKeyword("classDef") or
                self.consumeKeyword("class") or
                self.consumeKeyword("linkStyle"))
            {
                self.skipToNextLine();
                continue;
            }

            try self.parseStatement(&graph);
        }

        if (graph.subgraphs.items.len > 0) {
            var sg_ids = std.StringHashMap(void).init(self.allocator);
            defer sg_ids.deinit();
            for (graph.subgraphs.items) |*sg| {
                try sg_ids.put(sg.id, {});
            }
            for (graph.edges.items) |*edge| {
                if (sg_ids.contains(edge.from)) {
                    if (graph.nodes.get(edge.from)) |node| {
                        if (std.mem.eql(u8, node.label, edge.from)) {
                            edge.from_is_subgraph = true;
                        }
                    }
                }
                if (sg_ids.contains(edge.to)) {
                    if (graph.nodes.get(edge.to)) |node| {
                        if (std.mem.eql(u8, node.label, edge.to)) {
                            edge.to_is_subgraph = true;
                        }
                    }
                }
            }
            var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
            defer to_remove.deinit(self.allocator);
            for (graph.node_order.items) |nid| {
                if (sg_ids.contains(nid)) {
                    if (graph.nodes.get(nid)) |node| {
                        if (std.mem.eql(u8, node.label, nid)) {
                            try to_remove.append(self.allocator, nid);
                        }
                    }
                }
            }
            for (to_remove.items) |nid| {
                _ = graph.nodes.remove(nid);
                var i: usize = 0;
                while (i < graph.node_order.items.len) {
                    if (std.mem.eql(u8, graph.node_order.items[i], nid)) {
                        _ = graph.node_order.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
        }

        return graph;
    }

    fn parseDirection(self: *Parser) Direction {
        if (self.consumeKeyword("LR")) return .LR;
        if (self.consumeKeyword("RL")) return .RL;
        if (self.consumeKeyword("TD")) return .TD;
        if (self.consumeKeyword("TB")) return .TB;
        if (self.consumeKeyword("BT")) return .BT;
        return .TD;
    }

    fn parseSubgraph(self: *Parser, graph: *Graph, parent_id: ?[]const u8) !void {
        self.skipWhitespace();

        var label: ?[]const u8 = null;
        const id_start = self.pos;
        if (!self.isAtEnd() and self.current() == '"') {
            self.advance();
            const quoted_start = self.pos;
            while (!self.isAtEnd() and self.current() != '"' and self.current() != '\n') {
                self.advance();
            }
            label = self.source[quoted_start..self.pos];
            if (!self.isAtEnd() and self.current() == '"') self.advance();
        } else {
            while (!self.isAtEnd() and !self.isWhitespace(self.current()) and self.current() != '[' and self.current() != '\n') {
                self.advance();
            }
        }
        const id = self.source[id_start..self.pos];

        self.skipWhitespace();
        if (self.current() == '[') {
            self.advance();
            const label_start = self.pos;
            while (!self.isAtEnd() and self.current() != ']') {
                self.advance();
            }
            var raw_label = self.source[label_start..self.pos];
            if (raw_label.len >= 2) {
                if ((raw_label[0] == '"' and raw_label[raw_label.len - 1] == '"') or
                    (raw_label[0] == '\'' and raw_label[raw_label.len - 1] == '\''))
                {
                    raw_label = raw_label[1 .. raw_label.len - 1];
                }
            }
            label = raw_label;
            if (!self.isAtEnd()) self.advance();
        }

        var subgraph = Subgraph.init(self.allocator, id, label, parent_id);
        errdefer subgraph.deinit();

        self.skipToNextLine();

        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;

            if (self.consumeKeyword("end")) {
                self.skipToNextLine();
                break;
            }
            if (self.consumeKeyword("subgraph")) {
                try self.parseSubgraph(graph, id);
                continue;
            }
            if (self.peekKeyword("direction")) {
                self.skipToNextLine();
                continue;
            }

            const prev_node_count = graph.node_order.items.len;
            try self.parseStatement(graph);

            for (graph.node_order.items[prev_node_count..]) |node_id| {
                try subgraph.addNode(node_id);
                if (graph.getNodeMut(node_id)) |node| {
                    node.subgraph_id = id;
                }
            }
        }

        try graph.addSubgraph(subgraph);
    }

    fn parseStatement(self: *Parser, graph: *Graph) !void {
        self.skipWhitespace();
        if (self.isAtEnd() or self.current() == '\n') {
            self.skipToNextLine();
            return;
        }

        const first_node = try self.parseNodeDef();
        try graph.addNode(first_node);

        self.skipWhitespace();

        var current_source_id = first_node.id;
        while (!self.isAtEnd() and !self.isLineEnd()) {
            self.skipWhitespace();
            if (self.isLineEnd()) break;

            const edge_info = self.parseEdgeOperator() orelse break;

            self.skipWhitespace();

            var label: ?[]const u8 = edge_info.embedded_label;
            if (self.current() == '|') {
                self.advance();
                const label_start = self.pos;
                while (!self.isAtEnd() and self.current() != '|') {
                    self.advance();
                }
                var raw_label = self.source[label_start..self.pos];
                if (raw_label.len >= 2) {
                    if ((raw_label[0] == '"' and raw_label[raw_label.len - 1] == '"') or
                        (raw_label[0] == '\'' and raw_label[raw_label.len - 1] == '\''))
                    {
                        raw_label = raw_label[1 .. raw_label.len - 1];
                    }
                }
                label = raw_label;
                if (!self.isAtEnd()) self.advance();
                self.skipWhitespace();
            }

            const target_node = try self.parseNodeDef();
            try graph.addNode(target_node);

            try graph.addEdge(.{
                .from = current_source_id,
                .to = target_node.id,
                .label = label,
                .style = edge_info.style,
                .arrow_start = edge_info.arrow_start,
                .arrow_end = edge_info.arrow_end,
            });

            current_source_id = target_node.id;
        }

        self.skipToNextLine();
    }

    const EdgeInfo = struct {
        style: EdgeStyle,
        arrow_start: ArrowHead,
        arrow_end: ArrowHead,
        embedded_label: ?[]const u8 = null,
    };

    fn parseEdgeOperator(self: *Parser) ?EdgeInfo {
        const start = self.pos;

        var arrow_start: ArrowHead = .none;
        var arrow_end: ArrowHead = .none;
        var style: EdgeStyle = .solid;

        if (self.matchChar('<')) {
            arrow_start = .arrow;
        } else if (self.matchChar('o')) {
            arrow_start = .circle;
        } else if (self.matchChar('x')) {
            arrow_start = .cross;
        }

        if (self.matchString("==")) {
            style = .thick;
            while (self.matchChar('=')) {}
        } else if (self.matchString("-.")) {
            style = .dotted;
            while (self.matchChar('.') or self.matchChar('-')) {}
        } else if (self.matchChar('-')) {
            style = .solid;
            while (self.matchChar('-')) {}
        } else {
            self.pos = start;
            return null;
        }

        var embedded_label: ?[]const u8 = null;
        if (!self.isAtEnd() and self.current() != '>' and self.current() != 'o' and
            self.current() != 'x' and !self.isWhitespace(self.current()) and
            !self.isLineEnd() and self.current() != '|')
        {
            const label_start = self.pos;
            while (!self.isAtEnd() and !self.isLineEnd()) {
                if (self.current() == '-') break;
                self.advance();
            }
            const label_end = self.pos;
            if (label_end > label_start) {
                var lbl = self.source[label_start..label_end];
                while (lbl.len > 0 and (lbl[lbl.len - 1] == ' ' or lbl[lbl.len - 1] == '\t')) {
                    lbl = lbl[0 .. lbl.len - 1];
                }
                if (lbl.len > 0) embedded_label = lbl;
            }
            while (self.matchChar('-')) {}
        }

        if (self.matchChar('>')) {
            arrow_end = .arrow;
        } else if (self.matchChar('o')) {
            arrow_end = .circle;
        } else if (self.matchChar('x')) {
            arrow_end = .cross;
        }

        if (self.pos == start) {
            return null;
        }

        return .{
            .style = style,
            .arrow_start = arrow_start,
            .arrow_end = arrow_end,
            .embedded_label = embedded_label,
        };
    }

    fn parseNodeDef(self: *Parser) !Node {
        self.skipWhitespace();

        const id_start = self.pos;
        while (!self.isAtEnd() and self.isIdChar(self.current())) {
            self.advance();
        }
        const id = self.source[id_start..self.pos];

        if (id.len == 0) {
            return ParseError.InvalidSyntax;
        }

        var shape: NodeShape = .rectangle;
        var label: []const u8 = id;

        if (!self.isAtEnd()) {
            const shape_result = self.parseNodeShape();
            if (shape_result) |result| {
                shape = result.shape;
                label = result.label;
            }
        }

        return .{
            .id = id,
            .label = label,
            .shape = shape,
        };
    }

    const ShapeResult = struct {
        shape: NodeShape,
        label: []const u8,
    };

    fn parseNodeShape(self: *Parser) ?ShapeResult {
        const c = self.current();

        if (c == '[') {
            self.advance();

            if (self.matchChar('[')) {
                const label = self.readUntilClose("]]");
                return .{ .shape = .subroutine, .label = label };
            }
            if (self.matchChar('(')) {
                const label = self.readUntilClose(")]");
                return .{ .shape = .cylinder, .label = label };
            }
            if (self.matchChar('/')) {
                const label_start = self.pos;
                while (!self.isAtEnd() and self.current() != '/' and self.current() != '\\' and self.current() != ']') {
                    self.advance();
                }
                const label = self.source[label_start..self.pos];
                if (self.matchChar('/')) {
                    _ = self.matchChar(']');
                    return .{ .shape = .parallelogram, .label = label };
                }
                if (self.matchChar('\\')) {
                    _ = self.matchChar(']');
                    return .{ .shape = .trapezoid, .label = label };
                }
                return .{ .shape = .rectangle, .label = label };
            }
            if (self.matchChar('\\')) {
                const label_start = self.pos;
                while (!self.isAtEnd() and self.current() != '/' and self.current() != '\\' and self.current() != ']') {
                    self.advance();
                }
                const label = self.source[label_start..self.pos];
                if (self.matchChar('\\')) {
                    _ = self.matchChar(']');
                    return .{ .shape = .parallelogram_alt, .label = label };
                }
                if (self.matchChar('/')) {
                    _ = self.matchChar(']');
                    return .{ .shape = .trapezoid_alt, .label = label };
                }
                return .{ .shape = .rectangle, .label = label };
            }

            const label = self.readUntilClose("]");
            return .{ .shape = .rectangle, .label = label };
        }

        if (c == '(') {
            self.advance();

            if (self.matchChar('[')) {
                const label = self.readUntilClose("])");
                return .{ .shape = .stadium, .label = label };
            }
            if (self.matchChar('(')) {
                const label = self.readUntilClose("))");
                return .{ .shape = .circle, .label = label };
            }

            const label = self.readUntilClose(")");
            return .{ .shape = .rounded, .label = label };
        }

        if (c == '{') {
            self.advance();

            if (self.matchChar('{')) {
                const label = self.readUntilClose("}}");
                return .{ .shape = .hexagon, .label = label };
            }

            const label = self.readUntilClose("}");
            return .{ .shape = .diamond, .label = label };
        }

        if (c == '>') {
            self.advance();
            const label = self.readUntilClose("]");
            return .{ .shape = .asymmetric, .label = label };
        }

        return null;
    }

    fn readUntilClose(self: *Parser, close: []const u8) []const u8 {
        const start = self.pos;
        while (!self.isAtEnd()) {
            if (self.matchString(close)) {
                return stripQuotes(self.source[start .. self.pos - close.len]);
            }
            self.advance();
        }
        return stripQuotes(self.source[start..self.pos]);
    }

    fn stripQuotes(label: []const u8) []const u8 {
        if (label.len < 2) return label;
        const first = label[0];
        const last = label[label.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return label[1 .. label.len - 1];
        }
        return label;
    }

    fn current(self: *Parser) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.pos];
    }

    fn peek(self: *Parser, offset: usize) u8 {
        if (self.pos + offset >= self.source.len) return 0;
        return self.source[self.pos + offset];
    }

    fn advance(self: *Parser) void {
        if (!self.isAtEnd()) {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
            }
            self.pos += 1;
        }
    }

    fn isAtEnd(self: *Parser) bool {
        return self.pos >= self.source.len;
    }

    fn isLineEnd(self: *Parser) bool {
        return self.isAtEnd() or self.current() == '\n';
    }

    fn isWhitespace(self: *Parser, c: u8) bool {
        _ = self;
        return c == ' ' or c == '\t' or c == '\r';
    }

    fn isIdChar(self: *Parser, c: u8) bool {
        _ = self;
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }

    fn skipWhitespace(self: *Parser) void {
        while (!self.isAtEnd() and self.isWhitespace(self.current())) {
            self.advance();
        }
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (!self.isAtEnd()) {
            self.skipWhitespace();
            if (self.current() == '\n') {
                self.advance();
                continue;
            }
            if (self.current() == '%' and self.peek(1) == '%') {
                self.skipToNextLine();
                continue;
            }
            break;
        }
    }

    fn skipToNextLine(self: *Parser) void {
        while (!self.isAtEnd() and self.current() != '\n') {
            self.advance();
        }
        if (!self.isAtEnd()) {
            self.advance();
        }
    }

    fn matchChar(self: *Parser, c: u8) bool {
        if (self.current() == c) {
            self.advance();
            return true;
        }
        return false;
    }

    fn matchString(self: *Parser, s: []const u8) bool {
        if (self.pos + s.len > self.source.len) return false;
        if (std.mem.eql(u8, self.source[self.pos .. self.pos + s.len], s)) {
            self.pos += s.len;
            return true;
        }
        return false;
    }

    fn consumeKeyword(self: *Parser, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[self.pos .. self.pos + keyword.len], keyword)) return false;

        if (self.pos + keyword.len < self.source.len) {
            const next = self.source[self.pos + keyword.len];
            if (self.isIdChar(next)) return false;
        }

        self.pos += keyword.len;
        return true;
    }

    fn peekKeyword(self: *Parser, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[self.pos .. self.pos + keyword.len], keyword)) return false;

        if (self.pos + keyword.len < self.source.len) {
            const next = self.source[self.pos + keyword.len];
            if (self.isIdChar(next)) return false;
        }

        return true;
    }

    pub fn parseSequence(allocator: Allocator, source: []const u8) !SequenceDiagram {
        var parser = Parser.init(allocator, source);
        return parser.parseSequenceDiagram();
    }

    fn parseSequenceDiagram(self: *Parser) !SequenceDiagram {
        var diagram = SequenceDiagram.init(self.allocator);
        errdefer diagram.deinit();

        self.skipWhitespaceAndComments();

        _ = self.consumeKeyword("sequenceDiagram");
        self.skipWhitespace();
        if (self.consumeKeyword("direction")) {
            self.skipWhitespace();
            diagram.direction = self.parseDirection();
            diagram.direction_explicit = true;
        }
        self.skipToNextLine();

        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;

            if (self.consumeKeyword("participant")) {
                try self.parseParticipantDecl(&diagram, .participant);
                continue;
            }
            if (self.consumeKeyword("actor")) {
                try self.parseParticipantDecl(&diagram, .actor);
                continue;
            }
            if (self.consumeKeyword("direction")) {
                self.skipWhitespace();
                diagram.direction = self.parseDirection();
                diagram.direction_explicit = true;
                self.skipToNextLine();
                continue;
            }
            if (self.consumeKeyword("autonumber")) {
                diagram.auto_number = true;
                self.skipToNextLine();
                continue;
            }
            if (self.consumeKeyword("Note") or self.consumeKeyword("note")) {
                try self.parseSequenceNote(&diagram);
                continue;
            }
            if (self.consumeKeyword("activate")) {
                try self.parseActivation(&diagram, true);
                continue;
            }
            if (self.consumeKeyword("deactivate")) {
                try self.parseActivation(&diagram, false);
                continue;
            }
            if (self.consumeKeyword("loop") or
                self.consumeKeyword("alt") or
                self.consumeKeyword("else") or
                self.consumeKeyword("opt") or
                self.consumeKeyword("par") or
                self.consumeKeyword("critical") or
                self.consumeKeyword("break") or
                self.consumeKeyword("rect") or
                self.consumeKeyword("end"))
            {
                self.skipToNextLine();
                continue;
            }

            const msg_result = try self.parseSequenceMessage(&diagram);
            if (!msg_result) {
                self.skipToNextLine();
            }
        }

        return diagram;
    }

    fn parseParticipantDecl(self: *Parser, diagram: *SequenceDiagram, ptype: ParticipantType) !void {
        self.skipWhitespace();

        const id_start = self.pos;
        while (!self.isAtEnd() and (self.isIdChar(self.current()) or self.current() == '_')) {
            self.advance();
        }
        const id = self.source[id_start..self.pos];

        if (id.len == 0) {
            self.skipToNextLine();
            return;
        }

        self.skipWhitespace();
        var alias: ?[]const u8 = null;
        if (self.consumeKeyword("as")) {
            self.skipWhitespace();
            if (self.current() == '"' or self.current() == '\'') {
                const quote = self.current();
                self.advance();
                const alias_start = self.pos;
                while (!self.isAtEnd() and self.current() != quote) {
                    self.advance();
                }
                alias = self.source[alias_start..self.pos];
                if (!self.isAtEnd()) self.advance();
            } else {
                const alias_start = self.pos;
                while (!self.isAtEnd() and !self.isLineEnd() and !self.isWhitespace(self.current())) {
                    self.advance();
                }
                alias = self.source[alias_start..self.pos];
            }
        }

        try diagram.addParticipant(.{
            .id = id,
            .alias = alias,
            .participant_type = ptype,
        });

        self.skipToNextLine();
    }

    fn parseSequenceMessage(self: *Parser, diagram: *SequenceDiagram) !bool {
        const start_pos = self.pos;

        const from_start = self.pos;
        while (!self.isAtEnd() and self.isIdChar(self.current())) {
            self.advance();
        }
        const from = self.source[from_start..self.pos];

        if (from.len == 0) {
            self.pos = start_pos;
            return false;
        }

        self.skipWhitespace();

        const arrow = self.parseSequenceArrow() orelse {
            self.pos = start_pos;
            return false;
        };

        self.skipWhitespace();

        const to_start = self.pos;
        while (!self.isAtEnd() and self.isIdChar(self.current())) {
            self.advance();
        }
        const to = self.source[to_start..self.pos];

        if (to.len == 0) {
            self.pos = start_pos;
            return false;
        }

        self.skipWhitespace();
        var text: []const u8 = "";
        if (self.matchChar(':')) {
            self.skipWhitespace();
            const text_start = self.pos;
            while (!self.isAtEnd() and self.current() != '\n') {
                self.advance();
            }
            text = std.mem.trimRight(u8, self.source[text_start..self.pos], " \t\r");
        }

        try diagram.addParticipant(.{ .id = from });
        try diagram.addParticipant(.{ .id = to });

        try diagram.addMessage(.{
            .from = from,
            .to = to,
            .text = text,
            .arrow_type = arrow,
            .is_self_message = std.mem.eql(u8, from, to),
        });

        self.skipToNextLine();
        return true;
    }

    fn parseSequenceArrow(self: *Parser) ?SequenceArrowType {
        if (self.matchString("-->>")) return .dashed_arrow;
        if (self.matchString("->>")) return .solid_arrow;
        if (self.matchString("--x")) return .dashed_cross;
        if (self.matchString("-x")) return .solid_cross;
        if (self.matchString("--)")) return .dashed_open;
        if (self.matchString("-)")) return .solid_open;
        if (self.matchString("-->")) return .dashed_line;
        if (self.matchString("->")) return .solid_line;

        return null;
    }

    fn parseSequenceNote(self: *Parser, diagram: *SequenceDiagram) !void {
        self.skipWhitespace();

        var position: types.NotePosition = .over;
        var participant1: ?[]const u8 = null;
        var participant2: ?[]const u8 = null;

        if (self.consumeKeyword("right")) {
            self.skipWhitespace();
            _ = self.consumeKeyword("of");
            position = .right_of;
        } else if (self.consumeKeyword("left")) {
            self.skipWhitespace();
            _ = self.consumeKeyword("of");
            position = .left_of;
        } else if (self.consumeKeyword("over")) {
            position = .over;
        }

        self.skipWhitespace();

        const p1_start = self.pos;
        while (!self.isAtEnd() and self.isIdChar(self.current())) {
            self.advance();
        }
        participant1 = self.source[p1_start..self.pos];

        self.skipWhitespace();
        if (self.matchChar(',')) {
            self.skipWhitespace();
            const p2_start = self.pos;
            while (!self.isAtEnd() and self.isIdChar(self.current())) {
                self.advance();
            }
            participant2 = self.source[p2_start..self.pos];
        }

        self.skipWhitespace();
        var text: []const u8 = "";
        if (self.matchChar(':')) {
            self.skipWhitespace();
            const text_start = self.pos;
            while (!self.isAtEnd() and self.current() != '\n') {
                self.advance();
            }
            text = std.mem.trimRight(u8, self.source[text_start..self.pos], " \t\r");
        }

        if (participant1) |p1| {
            if (p1.len > 0) {
                try diagram.addParticipant(.{ .id = p1 });
                if (participant2) |p2| {
                    if (p2.len > 0) {
                        try diagram.addParticipant(.{ .id = p2 });
                    }
                }

                try diagram.addNote(.{
                    .position = position,
                    .participant1 = p1,
                    .participant2 = participant2,
                    .text = text,
                });
            }
        }

        self.skipToNextLine();
    }

    fn parseActivation(self: *Parser, diagram: *SequenceDiagram, is_activate: bool) !void {
        self.skipWhitespace();

        const id_start = self.pos;
        while (!self.isAtEnd() and (self.isIdChar(self.current()) or self.current() == '_')) {
            self.advance();
        }
        const participant_id = self.source[id_start..self.pos];

        if (participant_id.len > 0) {
            try diagram.addParticipant(.{ .id = participant_id });

            try diagram.addActivation(.{
                .participant = participant_id,
                .is_activate = is_activate,
            });
        }

        self.skipToNextLine();
    }

    pub fn parseClassDiagram(allocator: Allocator, source: []const u8) !ClassDiagram {
        var parser = Parser.init(allocator, source);
        return parser.parseClassDiagramInternal();
    }

    fn parseClassDiagramInternal(self: *Parser) !ClassDiagram {
        var diagram = ClassDiagram.init(self.allocator);
        errdefer diagram.deinit();

        self.skipWhitespaceAndComments();

        _ = self.consumeKeyword("classDiagram");
        self.skipToNextLine();

        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;

            if (self.consumeKeyword("direction") or
                self.consumeKeyword("note") or
                self.consumeKeyword("callback") or
                self.consumeKeyword("link") or
                self.consumeKeyword("cssClass"))
            {
                self.skipToNextLine();
                continue;
            }

            if (self.consumeKeyword("class")) {
                self.skipWhitespace();
                const name_start = self.pos;
                while (!self.isAtEnd() and self.isIdChar(self.current())) {
                    self.advance();
                }
                const class_name = self.source[name_start..self.pos];
                if (class_name.len > 0) {
                    const result = try diagram.classes.getOrPut(class_name);
                    if (!result.found_existing) {
                        result.value_ptr.* = Class.init(self.allocator, class_name);
                        try diagram.class_order.append(self.allocator, class_name);
                    }
                }
                self.skipToNextLine();
                continue;
            }

            const parsed = try self.parseClassStatement(&diagram);
            if (!parsed) {
                self.skipToNextLine();
            }
        }

        return diagram;
    }

    fn parseClassStatement(self: *Parser, diagram: *ClassDiagram) !bool {
        const start_pos = self.pos;

        const first_name = self.parseClassName();
        if (first_name.len == 0) {
            self.pos = start_pos;
            return false;
        }

        self.skipWhitespace();

        if (self.matchChar(':')) {
            self.skipWhitespace();
            try self.parseClassMember(diagram, first_name);
            return true;
        }

        const rel_type = self.parseClassRelation();
        if (rel_type) |relation_type| {
            self.skipWhitespace();

            const second_name = self.parseClassName();
            if (second_name.len == 0) {
                self.pos = start_pos;
                return false;
            }

            self.skipWhitespace();
            var label: ?[]const u8 = null;
            if (self.matchChar(':')) {
                self.skipWhitespace();
                const label_start = self.pos;
                while (!self.isAtEnd() and self.current() != '\n') {
                    self.advance();
                }
                label = std.mem.trimRight(u8, self.source[label_start..self.pos], " \t\r");
            }

            try self.ensureClass(diagram, first_name);
            try self.ensureClass(diagram, second_name);

            try diagram.addRelation(.{
                .from = first_name,
                .to = second_name,
                .relation_type = relation_type,
                .label = label,
            });

            self.skipToNextLine();
            return true;
        }

        self.pos = start_pos;
        return false;
    }

    fn parseClassName(self: *Parser) []const u8 {
        const start = self.pos;
        while (!self.isAtEnd()) {
            const c = self.current();
            if (self.isIdChar(c) or c == '-') {
                self.advance();
            } else {
                break;
            }
        }
        return self.source[start..self.pos];
    }

    fn parseClassRelation(self: *Parser) ?ClassRelationType {
        if (self.matchString("<|--")) return .inheritance;
        if (self.matchString("--|>")) return .inheritance;
        if (self.matchString("..|>")) return .realization;
        if (self.matchString("<|..")) return .realization;
        if (self.matchString("*--")) return .composition;
        if (self.matchString("--*")) return .composition;
        if (self.matchString("o--")) return .aggregation;
        if (self.matchString("--o")) return .aggregation;
        if (self.matchString("..>")) return .dependency;
        if (self.matchString("<..")) return .dependency;
        if (self.matchString("-->")) return .association;
        if (self.matchString("<--")) return .association;
        if (self.matchString("--")) return .link;
        if (self.matchString("..")) return .dependency;

        return null;
    }

    fn parseClassMember(self: *Parser, diagram: *ClassDiagram, class_name: []const u8) !void {
        try self.ensureClass(diagram, class_name);

        const class = diagram.getClassMut(class_name) orelse return;

        var visibility: Visibility = .none;
        const first_char = self.current();
        if (first_char == '+' or first_char == '-' or first_char == '#' or first_char == '~') {
            visibility = Visibility.fromChar(first_char);
            self.advance();
        }

        const member_start = self.pos;
        while (!self.isAtEnd() and self.current() != '\n') {
            self.advance();
        }
        const member_text = std.mem.trimRight(u8, self.source[member_start..self.pos], " \t\r");

        if (member_text.len == 0) return;

        const is_method = std.mem.indexOf(u8, member_text, "(") != null;

        var member_type: []const u8 = "";
        var name: []const u8 = member_text;

        if (std.mem.indexOf(u8, member_text, " ")) |space_idx| {
            if (!is_method) {
                member_type = member_text[0..space_idx];
                name = member_text[space_idx + 1 ..];
            }
        }

        try class.addMember(.{
            .name = name,
            .member_type = member_type,
            .visibility = visibility,
            .is_method = is_method,
        });

        self.skipToNextLine();
    }

    fn ensureClass(self: *Parser, diagram: *ClassDiagram, name: []const u8) !void {
        const result = try diagram.classes.getOrPut(name);
        if (!result.found_existing) {
            result.value_ptr.* = Class.init(self.allocator, name);
            try diagram.class_order.append(self.allocator, name);
        }
    }

    pub fn parseERDiagram(allocator: Allocator, source: []const u8) !ERDiagram {
        var parser = Parser.init(allocator, source);
        return parser.parseERDiagramInternal();
    }

    fn parseERDiagramInternal(self: *Parser) !ERDiagram {
        var diagram = ERDiagram.init(self.allocator);
        errdefer diagram.deinit();

        self.skipWhitespaceAndComments();

        _ = self.consumeKeyword("erDiagram");
        self.skipToNextLine();

        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;

            const parsed = try self.parseERStatement(&diagram);
            if (!parsed) {
                self.skipToNextLine();
            }
        }

        return diagram;
    }

    fn parseERStatement(self: *Parser, diagram: *ERDiagram) !bool {
        const start_pos = self.pos;

        const first_name = self.parseEntityName();
        if (first_name.len == 0) {
            self.pos = start_pos;
            return false;
        }

        self.skipWhitespace();

        const rel = self.parseERRelation();
        if (rel) |relation| {
            self.skipWhitespace();

            const second_name = self.parseEntityName();
            if (second_name.len == 0) {
                self.pos = start_pos;
                return false;
            }

            self.skipWhitespace();
            var label: ?[]const u8 = null;
            if (self.matchChar(':')) {
                self.skipWhitespace();
                const label_start = self.pos;
                while (!self.isAtEnd() and self.current() != '\n') {
                    self.advance();
                }
                label = std.mem.trimRight(u8, self.source[label_start..self.pos], " \t\r");
            }

            try self.ensureEntity(diagram, first_name);
            try self.ensureEntity(diagram, second_name);

            try diagram.addRelation(.{
                .from = first_name,
                .to = second_name,
                .from_cardinality = relation.left,
                .to_cardinality = relation.right,
                .label = label,
            });

            self.skipToNextLine();
            return true;
        }

        if (first_name.len > 0) {
            try self.ensureEntity(diagram, first_name);
            self.skipToNextLine();
            return true;
        }

        self.pos = start_pos;
        return false;
    }

    fn parseEntityName(self: *Parser) []const u8 {
        const start = self.pos;
        while (!self.isAtEnd()) {
            const c = self.current();
            if (self.isIdChar(c) or c == '-') {
                self.advance();
            } else {
                break;
            }
        }
        return self.source[start..self.pos];
    }

    const ERRelationResult = struct {
        left: Cardinality,
        right: Cardinality,
    };

    fn parseERRelation(self: *Parser) ?ERRelationResult {
        var left: Cardinality = .exactly_one;
        var right: Cardinality = .exactly_one;

        if (self.matchString("||")) {
            left = .exactly_one;
        } else if (self.matchString("|o")) {
            left = .zero_or_one;
        } else if (self.matchString("}|")) {
            left = .one_or_more;
        } else if (self.matchString("}o")) {
            left = .zero_or_more;
        } else {
            return null;
        }

        if (!self.matchString("--") and !self.matchString("..")) {
            return null;
        }

        if (self.matchString("||")) {
            right = .exactly_one;
        } else if (self.matchString("o|")) {
            right = .zero_or_one;
        } else if (self.matchString("|{")) {
            right = .one_or_more;
        } else if (self.matchString("o{")) {
            right = .zero_or_more;
        } else {
            return null;
        }

        return .{
            .left = left,
            .right = right,
        };
    }

    fn ensureEntity(self: *Parser, diagram: *ERDiagram, name: []const u8) !void {
        const result = try diagram.entities.getOrPut(name);
        if (!result.found_existing) {
            result.value_ptr.* = Entity.init(self.allocator, name);
            try diagram.entity_order.append(self.allocator, name);
        }
    }

    pub fn parseStateDiagram(allocator: Allocator, source: []const u8) !StateDiagram {
        var parser = Parser.init(allocator, source);
        return parser.parseStateDiagramImpl();
    }

    fn parseStateDiagramImpl(self: *Parser) !StateDiagram {
        var diagram = StateDiagram.init(self.allocator);
        errdefer diagram.deinit();

        self.skipWhitespaceAndComments();

        if (self.consumeKeyword("stateDiagram-v2") or self.consumeKeyword("stateDiagram")) {
            self.skipWhitespace();
            if (self.consumeKeyword("direction")) {
                self.skipWhitespace();
                diagram.direction = self.parseDirection();
            }
        }
        self.skipToNextLine();

        var start_count: u32 = 0;
        var end_count: u32 = 0;

        try self.parseStateDiagramBody(&diagram, null, &start_count, &end_count);

        return diagram;
    }

    fn parseStateDiagramBody(
        self: *Parser,
        diagram: *StateDiagram,
        parent_id: ?[]const u8,
        start_count: *u32,
        end_count: *u32,
    ) Allocator.Error!void {
        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;

            if (self.peekKeyword("end") or self.current() == '}') {
                break;
            }

            if (self.consumeKeyword("direction")) {
                self.skipWhitespace();
                diagram.direction = self.parseDirection();
                self.skipToNextLine();
                continue;
            }

            if (self.consumeKeyword("state")) {
                try self.parseStateDeclaration(diagram, parent_id, start_count, end_count);
                continue;
            }

            if (self.consumeKeyword("note") or self.consumeKeyword("Note")) {
                try self.parseStateNote(diagram);
                continue;
            }

            try self.parseStateStatement(diagram, parent_id, start_count, end_count);
        }
    }

    fn parseStateDeclaration(
        self: *Parser,
        diagram: *StateDiagram,
        parent_id: ?[]const u8,
        start_count: *u32,
        end_count: *u32,
    ) Allocator.Error!void {
        self.skipWhitespace();

        const id = self.parseStateId();
        if (id.len == 0) {
            self.skipToNextLine();
            return;
        }

        self.skipWhitespace();

        var state_type: types.StateType = .regular;
        if (self.matchString("<<choice>>")) {
            state_type = .choice;
        } else if (self.matchString("<<fork>>")) {
            state_type = .fork;
        } else if (self.matchString("<<join>>")) {
            state_type = .join;
        }

        self.skipWhitespace();

        var label: ?[]const u8 = null;
        if (self.matchChar(':')) {
            self.skipWhitespace();
            const label_start = self.pos;
            while (!self.isAtEnd() and self.current() != '\n' and self.current() != '{') {
                self.advance();
            }
            label = std.mem.trimRight(u8, self.source[label_start..self.pos], " \t\r");
            if (label.?.len == 0) label = null;
        }

        self.skipWhitespace();

        const is_composite = self.matchChar('{');

        try diagram.addState(.{
            .id = id,
            .label = label,
            .state_type = state_type,
            .is_composite = is_composite,
            .parent_id = parent_id,
        });

        if (is_composite) {
            self.skipToNextLine();
            try self.parseStateDiagramBody(diagram, id, start_count, end_count);
            self.skipWhitespaceAndComments();
            _ = self.matchChar('}') or self.consumeKeyword("end");
        }

        self.skipToNextLine();
    }

    fn parseStateStatement(
        self: *Parser,
        diagram: *StateDiagram,
        parent_id: ?[]const u8,
        start_count: *u32,
        end_count: *u32,
    ) Allocator.Error!void {
        self.skipWhitespace();
        if (self.isAtEnd() or self.current() == '\n') {
            self.skipToNextLine();
            return;
        }

        const first_state = try self.parseStateReference(diagram, parent_id, start_count, end_count, true);
        if (first_state.len == 0) {
            self.skipToNextLine();
            return;
        }

        self.skipWhitespace();

        if (self.matchString("-->")) {
            self.skipWhitespace();

            var label: ?[]const u8 = null;

            const second_state = try self.parseStateReference(diagram, parent_id, start_count, end_count, false);

            self.skipWhitespace();
            if (self.matchChar(':')) {
                self.skipWhitespace();
                const label_start = self.pos;
                while (!self.isAtEnd() and self.current() != '\n') {
                    self.advance();
                }
                label = std.mem.trimRight(u8, self.source[label_start..self.pos], " \t\r");
                if (label.?.len == 0) label = null;
            }

            try diagram.addTransition(.{
                .from = first_state,
                .to = second_state,
                .label = label,
            });
        } else if (self.matchChar(':')) {
            self.skipWhitespace();
            const label_start = self.pos;
            while (!self.isAtEnd() and self.current() != '\n') {
                self.advance();
            }
            const label = std.mem.trimRight(u8, self.source[label_start..self.pos], " \t\r");

            if (diagram.getStateMut(first_state)) |state| {
                if (state.label == null and label.len > 0) {
                    state.label = label;
                }
            }
        }

        self.skipToNextLine();
    }

    fn parseStateReference(
        self: *Parser,
        diagram: *StateDiagram,
        parent_id: ?[]const u8,
        start_count: *u32,
        end_count: *u32,
        is_source: bool,
    ) Allocator.Error![]const u8 {
        self.skipWhitespace();

        if (self.matchString("[*]")) {
            if (is_source) {
                const id = try self.makeStartId(start_count);
                try diagram.trackAllocatedId(id);
                try diagram.addState(.{
                    .id = id,
                    .state_type = .start,
                    .parent_id = parent_id,
                });
                return id;
            } else {
                for (diagram.state_order.items) |existing_id| {
                    if (diagram.getState(existing_id)) |existing_state| {
                        if (existing_state.state_type == .end) {
                            const existing_parent = existing_state.parent_id;
                            const parents_match = if (parent_id) |p|
                                (existing_parent != null and std.mem.eql(u8, existing_parent.?, p))
                            else
                                (existing_parent == null);
                            if (parents_match) {
                                return existing_id;
                            }
                        }
                    }
                }
                const id = try self.makeEndId(end_count);
                try diagram.trackAllocatedId(id);
                try diagram.addState(.{
                    .id = id,
                    .state_type = .end,
                    .parent_id = parent_id,
                });
                return id;
            }
        }

        const id = self.parseStateId();
        if (id.len > 0) {
            const result = try diagram.states.getOrPut(id);
            if (!result.found_existing) {
                result.value_ptr.* = .{
                    .id = id,
                    .parent_id = parent_id,
                };
                try diagram.state_order.append(self.allocator, id);
            }
        }
        return id;
    }

    fn parseStateId(self: *Parser) []const u8 {
        const start = self.pos;
        while (!self.isAtEnd()) {
            const c = self.current();
            if (self.isIdChar(c)) {
                self.advance();
            } else {
                break;
            }
        }
        return self.source[start..self.pos];
    }

    fn makeStartId(self: *Parser, count: *u32) Allocator.Error![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "[*]_start_{d}", .{count.*});
        count.* += 1;
        return id;
    }

    fn makeEndId(self: *Parser, count: *u32) Allocator.Error![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "[*]_end_{d}", .{count.*});
        count.* += 1;
        return id;
    }

    fn parseStateNote(self: *Parser, diagram: *StateDiagram) !void {
        self.skipWhitespace();

        var position: types.NotePosition = .right_of;
        if (self.consumeKeyword("left")) {
            self.skipWhitespace();
            _ = self.consumeKeyword("of");
            position = .left_of;
        } else if (self.consumeKeyword("right")) {
            self.skipWhitespace();
            _ = self.consumeKeyword("of");
            position = .right_of;
        }

        self.skipWhitespace();

        const state_id = self.parseStateId();
        if (state_id.len == 0) {
            self.skipToNextLine();
            return;
        }

        self.skipWhitespace();

        if (!self.matchChar(':')) {
            self.skipToNextLine();
            return;
        }

        self.skipWhitespace();
        const text_start = self.pos;
        while (!self.isAtEnd() and self.current() != '\n') {
            self.advance();
        }
        const text = std.mem.trimRight(u8, self.source[text_start..self.pos], " \t\r");

        try diagram.addNote(.{
            .state_id = state_id,
            .text = text,
            .position = position,
        });

        self.skipToNextLine();
    }
};

test "parse simple flowchart" {
    const testing = std.testing;

    const source =
        \\graph LR
        \\    A[Start] --> B[End]
    ;

    var graph = try Parser.parse(testing.allocator, source);
    defer graph.deinit();

    try testing.expectEqual(DiagramType.flowchart, graph.diagram_type);
    try testing.expectEqual(Direction.LR, graph.direction);
    try testing.expectEqual(@as(usize, 2), graph.node_order.items.len);
    try testing.expectEqual(@as(usize, 1), graph.edges.items.len);

    const node_a = graph.getNode("A").?;
    try testing.expectEqualStrings("Start", node_a.label);

    const node_b = graph.getNode("B").?;
    try testing.expectEqualStrings("End", node_b.label);
}

test "parse node shapes" {
    const testing = std.testing;

    const source =
        \\graph TD
        \\    A[Rectangle]
        \\    B(Rounded)
        \\    C{Diamond}
        \\    D([Stadium])
        \\    E((Circle))
        \\    F{{Hexagon}}
    ;

    var graph = try Parser.parse(testing.allocator, source);
    defer graph.deinit();

    try testing.expectEqual(NodeShape.rectangle, graph.getNode("A").?.shape);
    try testing.expectEqual(NodeShape.rounded, graph.getNode("B").?.shape);
    try testing.expectEqual(NodeShape.diamond, graph.getNode("C").?.shape);
    try testing.expectEqual(NodeShape.stadium, graph.getNode("D").?.shape);
    try testing.expectEqual(NodeShape.circle, graph.getNode("E").?.shape);
    try testing.expectEqual(NodeShape.hexagon, graph.getNode("F").?.shape);
}

test "parse edge styles" {
    const testing = std.testing;

    const source =
        \\graph LR
        \\    A --> B
        \\    B --- C
        \\    C -.-> D
        \\    D ==> E
    ;

    var graph = try Parser.parse(testing.allocator, source);
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 4), graph.edges.items.len);
    try testing.expectEqual(EdgeStyle.solid, graph.edges.items[0].style);
    try testing.expectEqual(ArrowHead.arrow, graph.edges.items[0].arrow_end);
    try testing.expectEqual(EdgeStyle.solid, graph.edges.items[1].style);
    try testing.expectEqual(ArrowHead.none, graph.edges.items[1].arrow_end);
    try testing.expectEqual(EdgeStyle.dotted, graph.edges.items[2].style);
    try testing.expectEqual(EdgeStyle.thick, graph.edges.items[3].style);
}

test "parse edge labels" {
    const testing = std.testing;

    const source =
        \\graph LR
        \\    A -->|Yes| B
        \\    A -->|No| C
    ;

    var graph = try Parser.parse(testing.allocator, source);
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 2), graph.edges.items.len);
    try testing.expectEqualStrings("Yes", graph.edges.items[0].label.?);
    try testing.expectEqualStrings("No", graph.edges.items[1].label.?);
}

test "parse subgraph" {
    const testing = std.testing;

    const source =
        \\graph LR
        \\    subgraph sg1[Group One]
        \\        A --> B
        \\    end
        \\    C --> A
    ;

    var graph = try Parser.parse(testing.allocator, source);
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 1), graph.subgraphs.items.len);
    try testing.expectEqualStrings("sg1", graph.subgraphs.items[0].id);
    try testing.expectEqualStrings("Group One", graph.subgraphs.items[0].label.?);
    try testing.expectEqual(@as(usize, 2), graph.subgraphs.items[0].node_ids.items.len);
}

test "parse subgraph preserves node labels" {
    const testing = std.testing;

    const source =
        \\graph LR
        \\    subgraph Group1
        \\        A[Node A]
        \\        B[Node B]
        \\        A --> B
        \\    end
    ;

    var graph = try Parser.parse(testing.allocator, source);
    defer graph.deinit();

    const node_a = graph.getNode("A").?;
    const node_b = graph.getNode("B").?;
    try testing.expectEqualStrings("Node A", node_a.label);
    try testing.expectEqualStrings("Node B", node_b.label);
}

test "parse simple sequence diagram" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    Alice->>Bob: Hello Bob
        \\    Bob-->>Alice: Hi Alice
    ;

    var diagram = try Parser.parseSequence(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.participants.items.len);
    try testing.expectEqual(@as(usize, 2), diagram.messages.items.len);

    try testing.expectEqualStrings("Alice", diagram.participants.items[0].id);
    try testing.expectEqualStrings("Bob", diagram.participants.items[1].id);

    try testing.expectEqualStrings("Alice", diagram.messages.items[0].from);
    try testing.expectEqualStrings("Bob", diagram.messages.items[0].to);
    try testing.expectEqualStrings("Hello Bob", diagram.messages.items[0].text);
    try testing.expectEqual(SequenceArrowType.solid_arrow, diagram.messages.items[0].arrow_type);

    try testing.expectEqual(SequenceArrowType.dashed_arrow, diagram.messages.items[1].arrow_type);
}

test "parse sequence with explicit participants" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    participant A as Alice
        \\    participant B as Bob
        \\    A->>B: Hello
    ;

    var diagram = try Parser.parseSequence(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.participants.items.len);
    try testing.expectEqualStrings("A", diagram.participants.items[0].id);
    try testing.expectEqualStrings("Alice", diagram.participants.items[0].alias.?);
    try testing.expectEqualStrings("B", diagram.participants.items[1].id);
    try testing.expectEqualStrings("Bob", diagram.participants.items[1].alias.?);
}

test "parse sequence arrow types" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    A->>B: solid arrow
        \\    A-->>B: dashed arrow
        \\    A->B: solid line
        \\    A-->B: dashed line
        \\    A-xB: solid cross
        \\    A--xB: dashed cross
    ;

    var diagram = try Parser.parseSequence(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 6), diagram.messages.items.len);
    try testing.expectEqual(SequenceArrowType.solid_arrow, diagram.messages.items[0].arrow_type);
    try testing.expectEqual(SequenceArrowType.dashed_arrow, diagram.messages.items[1].arrow_type);
    try testing.expectEqual(SequenceArrowType.solid_line, diagram.messages.items[2].arrow_type);
    try testing.expectEqual(SequenceArrowType.dashed_line, diagram.messages.items[3].arrow_type);
    try testing.expectEqual(SequenceArrowType.solid_cross, diagram.messages.items[4].arrow_type);
    try testing.expectEqual(SequenceArrowType.dashed_cross, diagram.messages.items[5].arrow_type);
}

test "parse self message" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    Alice->>Alice: Talk to self
    ;

    var diagram = try Parser.parseSequence(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 1), diagram.messages.items.len);
    try testing.expect(diagram.messages.items[0].is_self_message);
}

test "parse complex label with special chars" {
    const testing = std.testing;

    const source =
        \\flowchart TB
        \\    subgraph Browser["Browser (localhost)"]
        \\        FE["Neo Frontend<br/>:9001"]
        \\        LP["OIDC Login Page<br/>:9002/interaction/*"]
        \\    end
    ;

    var graph = try Parser.parse(testing.allocator, source);
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 2), graph.node_order.items.len);
    const fe = graph.getNode("FE").?;
    try testing.expectEqualStrings("Neo Frontend<br/>:9001", fe.label);
}

test "parse sequence diagram with notes" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    Alice->>Bob: Hello
        \\    Note right of Bob: Bob thinks
        \\    Bob-->>Alice: Hi
        \\    Note over Alice,Bob: They greet
    ;

    var diagram = try Parser.parseSequence(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.participants.items.len);
    try testing.expectEqual(@as(usize, 2), diagram.messages.items.len);
    try testing.expectEqual(@as(usize, 2), diagram.notes.items.len);

    try testing.expectEqual(types.NotePosition.right_of, diagram.notes.items[0].position);
    try testing.expectEqualStrings("Bob", diagram.notes.items[0].participant1);
    try testing.expectEqualStrings("Bob thinks", diagram.notes.items[0].text);

    try testing.expectEqual(types.NotePosition.over, diagram.notes.items[1].position);
    try testing.expectEqualStrings("Alice", diagram.notes.items[1].participant1);
    try testing.expectEqualStrings("Bob", diagram.notes.items[1].participant2.?);
    try testing.expectEqualStrings("They greet", diagram.notes.items[1].text);
}

test "parse sequence diagram direction" {
    const testing = std.testing;

    const source =
        \\sequenceDiagram
        \\    direction LR
        \\    Alice->>Bob: Hello
    ;

    var diagram = try Parser.parseSequence(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(Direction.LR, diagram.direction);
}

test "parse simple class diagram" {
    const testing = std.testing;

    const source =
        \\classDiagram
        \\    Animal <|-- Duck
        \\    Animal : +int age
        \\    Animal : +String gender
        \\    Duck : +swim()
    ;

    var diagram = try Parser.parseClassDiagram(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.class_order.items.len);
    try testing.expectEqual(@as(usize, 1), diagram.relations.items.len);

    try testing.expect(diagram.getClass("Animal") != null);
    try testing.expect(diagram.getClass("Duck") != null);

    const rel = diagram.relations.items[0];
    try testing.expectEqualStrings("Animal", rel.from);
    try testing.expectEqualStrings("Duck", rel.to);
    try testing.expectEqual(ClassRelationType.inheritance, rel.relation_type);

    const animal = diagram.getClass("Animal").?;
    try testing.expectEqual(@as(usize, 2), animal.members.items.len);

    const duck = diagram.getClass("Duck").?;
    try testing.expectEqual(@as(usize, 1), duck.members.items.len);
    try testing.expect(duck.members.items[0].is_method);
}

test "parse class diagram with various relations" {
    const testing = std.testing;

    const source =
        \\classDiagram
        \\    A <|-- B
        \\    C *-- D
        \\    E o-- F
        \\    G --> H
    ;

    var diagram = try Parser.parseClassDiagram(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 4), diagram.relations.items.len);
    try testing.expectEqual(ClassRelationType.inheritance, diagram.relations.items[0].relation_type);
    try testing.expectEqual(ClassRelationType.composition, diagram.relations.items[1].relation_type);
    try testing.expectEqual(ClassRelationType.aggregation, diagram.relations.items[2].relation_type);
    try testing.expectEqual(ClassRelationType.association, diagram.relations.items[3].relation_type);
}

test "parse simple ER diagram" {
    const testing = std.testing;

    const source =
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
        \\    ORDER ||--|{ LINE-ITEM : contains
    ;

    var diagram = try Parser.parseERDiagram(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 3), diagram.entity_order.items.len);
    try testing.expectEqual(@as(usize, 2), diagram.relations.items.len);

    try testing.expect(diagram.getEntity("CUSTOMER") != null);
    try testing.expect(diagram.getEntity("ORDER") != null);
    try testing.expect(diagram.getEntity("LINE-ITEM") != null);

    const rel1 = diagram.relations.items[0];
    try testing.expectEqualStrings("CUSTOMER", rel1.from);
    try testing.expectEqualStrings("ORDER", rel1.to);
    try testing.expectEqual(Cardinality.exactly_one, rel1.from_cardinality);
    try testing.expectEqual(Cardinality.zero_or_more, rel1.to_cardinality);
    try testing.expectEqualStrings("places", rel1.label.?);

    const rel2 = diagram.relations.items[1];
    try testing.expectEqualStrings("ORDER", rel2.from);
    try testing.expectEqualStrings("LINE-ITEM", rel2.to);
    try testing.expectEqual(Cardinality.exactly_one, rel2.from_cardinality);
    try testing.expectEqual(Cardinality.one_or_more, rel2.to_cardinality);
}

test "parse simple state diagram" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    [*] --> Still
        \\    Still --> [*]
        \\    Still --> Moving
        \\    Moving --> Still
        \\    Moving --> Crash
        \\    Crash --> [*]
    ;

    var diagram = try Parser.parseStateDiagram(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 5), diagram.state_order.items.len);
    try testing.expectEqual(@as(usize, 6), diagram.transitions.items.len);

    try testing.expect(diagram.getState("Still") != null);
    try testing.expect(diagram.getState("Moving") != null);
    try testing.expect(diagram.getState("Crash") != null);

    try testing.expect(diagram.getState("[*]_start_0") != null);
    try testing.expectEqual(StateType.start, diagram.getState("[*]_start_0").?.state_type);

    try testing.expect(diagram.getState("[*]_end_0") != null);
    try testing.expectEqual(StateType.end, diagram.getState("[*]_end_0").?.state_type);
}

test "parse state diagram with descriptions" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    s1 : This is state 1
        \\    s2 : This is state 2
        \\    s1 --> s2
    ;

    var diagram = try Parser.parseStateDiagram(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.state_order.items.len);

    const s1 = diagram.getState("s1").?;
    try testing.expectEqualStrings("This is state 1", s1.label.?);

    const s2 = diagram.getState("s2").?;
    try testing.expectEqualStrings("This is state 2", s2.label.?);
}

test "parse state diagram with transition labels" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    s1 --> s2 : go forward
        \\    s2 --> s1 : go back
    ;

    var diagram = try Parser.parseStateDiagram(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.transitions.items.len);
    try testing.expectEqualStrings("go forward", diagram.transitions.items[0].label.?);
    try testing.expectEqualStrings("go back", diagram.transitions.items[1].label.?);
}

test "parse state diagram with composite state" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    [*] --> First
        \\    state First {
        \\        [*] --> second
        \\        second --> [*]
        \\    }
    ;

    var diagram = try Parser.parseStateDiagram(testing.allocator, source);
    defer diagram.deinit();

    const first = diagram.getState("First").?;
    try testing.expect(first.is_composite);

    const second = diagram.getState("second").?;
    try testing.expect(second.parent_id != null);
    try testing.expectEqualStrings("First", second.parent_id.?);
}

test "parse state diagram with choice" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    state if_state <<choice>>
        \\    [*] --> IsPositive
        \\    IsPositive --> if_state
        \\    if_state --> False : if n < 0
        \\    if_state --> True : if n >= 0
    ;

    var diagram = try Parser.parseStateDiagram(testing.allocator, source);
    defer diagram.deinit();

    const choice = diagram.getState("if_state").?;
    try testing.expectEqual(StateType.choice, choice.state_type);
}

test "parse state diagram direction" {
    const testing = std.testing;

    const source =
        \\stateDiagram-v2
        \\    direction LR
        \\    [*] --> A
        \\    A --> [*]
    ;

    var diagram = try Parser.parseStateDiagram(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(Direction.LR, diagram.direction);
}

test "parse subgraph-level edges" {
    const testing = std.testing;

    const source =
        \\flowchart TB
        \\    subgraph one
        \\    a1-->a2
        \\    end
        \\    subgraph two
        \\    b1-->b2
        \\    end
        \\    one --> two
    ;

    var graph = try Parser.parse(testing.allocator, source);
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 4), graph.node_order.items.len);
    try testing.expect(graph.nodes.get("one") == null);
    try testing.expect(graph.nodes.get("two") == null);

    try testing.expectEqual(@as(usize, 3), graph.edges.items.len);

    var found_sg_edge = false;
    for (graph.edges.items) |e| {
        if (std.mem.eql(u8, e.from, "one") and std.mem.eql(u8, e.to, "two")) {
            try testing.expect(e.from_is_subgraph);
            try testing.expect(e.to_is_subgraph);
            found_sg_edge = true;
        }
    }
    try testing.expect(found_sg_edge);
}

test "parse subgraph-level edges fixture" {
    const testing = std.testing;

    const source =
        \\flowchart TB
        \\    c1-->a2
        \\    subgraph one
        \\    a1-->a2
        \\    end
        \\    subgraph two
        \\    b1-->b2
        \\    end
        \\    subgraph three
        \\    c1-->c2
        \\    end
        \\    one --> two
        \\    three --> two
        \\    two --> c2
    ;

    var graph = try Parser.parse(testing.allocator, source);
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 6), graph.node_order.items.len);
    try testing.expect(graph.nodes.get("one") == null);
    try testing.expect(graph.nodes.get("two") == null);
    try testing.expect(graph.nodes.get("three") == null);

    var sg_edge_count: usize = 0;
    for (graph.edges.items) |e| {
        if (e.from_is_subgraph or e.to_is_subgraph) {
            sg_edge_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), sg_edge_count);
}
