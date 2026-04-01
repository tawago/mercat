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

/// Parser for mermaid diagram syntax
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

    /// Parse the source into a Graph
    pub fn parse(allocator: Allocator, source: []const u8) !Graph {
        var parser = Parser.init(allocator, source);
        return parser.parseGraph();
    }

    fn parseGraph(self: *Parser) !Graph {
        var graph = Graph.init(self.allocator);
        errdefer graph.deinit();

        self.skipWhitespaceAndComments();

        // Parse diagram type and direction
        const diagram_type = DiagramType.fromSource(self.source[self.pos..]);
        graph.diagram_type = diagram_type;

        if (diagram_type == .flowchart) {
            // Parse "graph" or "flowchart" keyword
            if (self.consumeKeyword("graph") or self.consumeKeyword("flowchart")) {
                self.skipWhitespace();
                graph.direction = self.parseDirection();
            }
        } else if (diagram_type == .sequence) {
            _ = self.consumeKeyword("sequenceDiagram");
        }

        self.skipToNextLine();

        // Parse body
        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;

            // Check for subgraph
            if (self.consumeKeyword("subgraph")) {
                try self.parseSubgraph(&graph);
                continue;
            }

            // Check for end keyword
            if (self.consumeKeyword("end")) {
                self.skipToNextLine();
                continue;
            }

            // Check for style/class definitions (skip them)
            if (self.consumeKeyword("style") or
                self.consumeKeyword("classDef") or
                self.consumeKeyword("class") or
                self.consumeKeyword("linkStyle"))
            {
                self.skipToNextLine();
                continue;
            }

            // Try to parse a node/edge statement
            try self.parseStatement(&graph);
        }

        return graph;
    }

    fn parseDirection(self: *Parser) Direction {
        if (self.consumeKeyword("LR")) return .LR;
        if (self.consumeKeyword("RL")) return .RL;
        if (self.consumeKeyword("TD")) return .TD;
        if (self.consumeKeyword("TB")) return .TB;
        if (self.consumeKeyword("BT")) return .BT;
        return .TD; // Default
    }

    fn parseSubgraph(self: *Parser, graph: *Graph) !void {
        self.skipWhitespace();

        // Parse subgraph ID
        const id_start = self.pos;
        while (!self.isAtEnd() and !self.isWhitespace(self.current()) and self.current() != '[' and self.current() != '\n') {
            self.advance();
        }
        const id = self.source[id_start..self.pos];

        // Parse optional label in brackets
        var label: ?[]const u8 = null;
        self.skipWhitespace();
        if (self.current() == '[') {
            self.advance();
            const label_start = self.pos;
            while (!self.isAtEnd() and self.current() != ']') {
                self.advance();
            }
            var raw_label = self.source[label_start..self.pos];
            // Strip surrounding quotes if present
            if (raw_label.len >= 2) {
                if ((raw_label[0] == '"' and raw_label[raw_label.len - 1] == '"') or
                    (raw_label[0] == '\'' and raw_label[raw_label.len - 1] == '\''))
                {
                    raw_label = raw_label[1 .. raw_label.len - 1];
                }
            }
            label = raw_label;
            if (!self.isAtEnd()) self.advance(); // consume ']'
        }

        var subgraph = Subgraph.init(self.allocator, id, label);
        errdefer subgraph.deinit();

        self.skipToNextLine();

        // Parse subgraph contents until "end"
        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;

            if (self.peekKeyword("end")) break;
            if (self.peekKeyword("subgraph")) {
                // Nested subgraph - for now, skip nested
                try self.parseSubgraph(graph);
                continue;
            }

            // Parse statement and track nodes
            const prev_node_count = graph.node_order.items.len;
            try self.parseStatement(graph);

            // Add new nodes to subgraph
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

        // Parse first node
        const first_node = try self.parseNodeDef();
        try graph.addNode(first_node);

        self.skipWhitespace();

        // Check for edge(s)
        while (!self.isAtEnd() and !self.isLineEnd()) {
            self.skipWhitespace();
            if (self.isLineEnd()) break;

            // Try to parse an edge
            const edge_info = self.parseEdgeOperator() orelse break;

            self.skipWhitespace();

            // Parse edge label if present (|label| syntax)
            var label: ?[]const u8 = null;
            if (self.current() == '|') {
                self.advance();
                const label_start = self.pos;
                while (!self.isAtEnd() and self.current() != '|') {
                    self.advance();
                }
                var raw_label = self.source[label_start..self.pos];
                // Strip surrounding quotes if present
                if (raw_label.len >= 2) {
                    if ((raw_label[0] == '"' and raw_label[raw_label.len - 1] == '"') or
                        (raw_label[0] == '\'' and raw_label[raw_label.len - 1] == '\''))
                    {
                        raw_label = raw_label[1 .. raw_label.len - 1];
                    }
                }
                label = raw_label;
                if (!self.isAtEnd()) self.advance(); // consume '|'
                self.skipWhitespace();
            }

            // Parse target node
            const target_node = try self.parseNodeDef();
            try graph.addNode(target_node);

            // Add edge
            try graph.addEdge(.{
                .from = first_node.id,
                .to = target_node.id,
                .label = label,
                .style = edge_info.style,
                .arrow_start = edge_info.arrow_start,
                .arrow_end = edge_info.arrow_end,
            });
        }

        self.skipToNextLine();
    }

    const EdgeInfo = struct {
        style: EdgeStyle,
        arrow_start: ArrowHead,
        arrow_end: ArrowHead,
    };

    fn parseEdgeOperator(self: *Parser) ?EdgeInfo {
        const start = self.pos;

        // Check for various edge patterns
        // --> solid arrow
        // --- solid line
        // -.-> dotted arrow
        // -.- dotted line
        // ==> thick arrow
        // === thick line
        // <--> bidirectional
        // o--o circles
        // x--x crosses

        var arrow_start: ArrowHead = .none;
        var arrow_end: ArrowHead = .none;
        var style: EdgeStyle = .solid;

        // Check start arrow/modifier
        if (self.matchChar('<')) {
            arrow_start = .arrow;
        } else if (self.matchChar('o')) {
            arrow_start = .circle;
        } else if (self.matchChar('x')) {
            arrow_start = .cross;
        }

        // Parse line style
        if (self.matchString("==")) {
            style = .thick;
            // Consume remaining = chars
            while (self.matchChar('=')) {}
        } else if (self.matchString("-.")) {
            style = .dotted;
            // Consume middle dots
            while (self.matchChar('.') or self.matchChar('-')) {}
        } else if (self.matchChar('-')) {
            style = .solid;
            // Consume remaining - chars
            while (self.matchChar('-')) {}
        } else {
            // Not an edge operator
            self.pos = start;
            return null;
        }

        // Check end arrow/modifier
        if (self.matchChar('>')) {
            arrow_end = .arrow;
        } else if (self.matchChar('o')) {
            arrow_end = .circle;
        } else if (self.matchChar('x')) {
            arrow_end = .cross;
        }

        // Verify we consumed something that looks like an edge
        if (self.pos == start) {
            return null;
        }

        return .{
            .style = style,
            .arrow_start = arrow_start,
            .arrow_end = arrow_end,
        };
    }

    fn parseNodeDef(self: *Parser) !Node {
        self.skipWhitespace();

        // Parse node ID (alphanumeric + underscore)
        const id_start = self.pos;
        while (!self.isAtEnd() and self.isIdChar(self.current())) {
            self.advance();
        }
        const id = self.source[id_start..self.pos];

        if (id.len == 0) {
            return ParseError.InvalidSyntax;
        }

        // Check for shape definition
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

        // [text] rectangle variants
        if (c == '[') {
            self.advance();

            // Check for special shapes
            if (self.matchChar('[')) {
                // [[text]] subroutine
                const label = self.readUntilClose("]]");
                return .{ .shape = .subroutine, .label = label };
            }
            if (self.matchChar('(')) {
                // [(text)] cylinder
                const label = self.readUntilClose(")]");
                return .{ .shape = .cylinder, .label = label };
            }
            if (self.matchChar('/')) {
                // [/text/] or [/text\] parallelogram/trapezoid
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
                // [\text\] or [\text/]
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

            // [text] plain rectangle
            const label = self.readUntilClose("]");
            return .{ .shape = .rectangle, .label = label };
        }

        // (text) rounded variants
        if (c == '(') {
            self.advance();

            if (self.matchChar('[')) {
                // ([text]) stadium
                const label = self.readUntilClose("])");
                return .{ .shape = .stadium, .label = label };
            }
            if (self.matchChar('(')) {
                // ((text)) circle
                const label = self.readUntilClose("))");
                return .{ .shape = .circle, .label = label };
            }

            // (text) rounded
            const label = self.readUntilClose(")");
            return .{ .shape = .rounded, .label = label };
        }

        // {text} diamond variants
        if (c == '{') {
            self.advance();

            if (self.matchChar('{')) {
                // {{text}} hexagon
                const label = self.readUntilClose("}}");
                return .{ .shape = .hexagon, .label = label };
            }

            // {text} diamond
            const label = self.readUntilClose("}");
            return .{ .shape = .diamond, .label = label };
        }

        // >text] asymmetric
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

    /// Strip surrounding quotes from a label
    fn stripQuotes(label: []const u8) []const u8 {
        if (label.len < 2) return label;
        const first = label[0];
        const last = label[label.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return label[1 .. label.len - 1];
        }
        return label;
    }

    // Helper methods
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
            // Skip %% comments
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
            self.advance(); // consume newline
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

        // Make sure it's a complete keyword (not a prefix of something else)
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

    // =====================================================
    // Sequence Diagram Parsing
    // =====================================================

    /// Parse a sequence diagram
    pub fn parseSequence(allocator: Allocator, source: []const u8) !SequenceDiagram {
        var parser = Parser.init(allocator, source);
        return parser.parseSequenceDiagram();
    }

    fn parseSequenceDiagram(self: *Parser) !SequenceDiagram {
        var diagram = SequenceDiagram.init(self.allocator);
        errdefer diagram.deinit();

        self.skipWhitespaceAndComments();

        // Skip "sequenceDiagram" keyword
        _ = self.consumeKeyword("sequenceDiagram");
        self.skipWhitespace();
        if (self.consumeKeyword("direction")) {
            self.skipWhitespace();
            diagram.direction = self.parseDirection();
            diagram.direction_explicit = true;
        }
        self.skipToNextLine();

        // Parse body
        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;

            // Parse different statement types
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
                // Skip control flow keywords for now
                self.skipToNextLine();
                continue;
            }

            // Try to parse a message
            const msg_result = try self.parseSequenceMessage(&diagram);
            if (!msg_result) {
                // Unknown line, skip it
                self.skipToNextLine();
            }
        }

        return diagram;
    }

    fn parseParticipantDecl(self: *Parser, diagram: *SequenceDiagram, ptype: ParticipantType) !void {
        self.skipWhitespace();

        // Parse participant ID
        const id_start = self.pos;
        while (!self.isAtEnd() and (self.isIdChar(self.current()) or self.current() == '_')) {
            self.advance();
        }
        const id = self.source[id_start..self.pos];

        if (id.len == 0) {
            self.skipToNextLine();
            return;
        }

        // Check for "as" alias
        self.skipWhitespace();
        var alias: ?[]const u8 = null;
        if (self.consumeKeyword("as")) {
            self.skipWhitespace();
            // Alias can be quoted or unquoted
            if (self.current() == '"' or self.current() == '\'') {
                const quote = self.current();
                self.advance();
                const alias_start = self.pos;
                while (!self.isAtEnd() and self.current() != quote) {
                    self.advance();
                }
                alias = self.source[alias_start..self.pos];
                if (!self.isAtEnd()) self.advance(); // consume closing quote
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

        // Parse "from" participant
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

        // Parse arrow type
        const arrow = self.parseSequenceArrow() orelse {
            self.pos = start_pos;
            return false;
        };

        self.skipWhitespace();

        // Parse "to" participant
        const to_start = self.pos;
        while (!self.isAtEnd() and self.isIdChar(self.current())) {
            self.advance();
        }
        const to = self.source[to_start..self.pos];

        if (to.len == 0) {
            self.pos = start_pos;
            return false;
        }

        // Parse message text (after colon)
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

        // Auto-create participants if they don't exist
        try diagram.addParticipant(.{ .id = from });
        try diagram.addParticipant(.{ .id = to });

        // Add message
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
        // Order matters - check longer patterns first
        // -->>  dashed with arrowhead
        if (self.matchString("-->>")) return .dashed_arrow;
        // ->>   solid with arrowhead
        if (self.matchString("->>")) return .solid_arrow;
        // --x   dashed with cross
        if (self.matchString("--x")) return .dashed_cross;
        // -x    solid with cross
        if (self.matchString("-x")) return .solid_cross;
        // --)   dashed async (open)
        if (self.matchString("--)")) return .dashed_open;
        // -)    solid async (open)
        if (self.matchString("-)")) return .solid_open;
        // -->   dashed line
        if (self.matchString("-->")) return .dashed_line;
        // ->    solid line
        if (self.matchString("->")) return .solid_line;

        return null;
    }

    fn parseSequenceNote(self: *Parser, diagram: *SequenceDiagram) !void {
        self.skipWhitespace();

        // Parse note position: "right of", "left of", or "over"
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

        // Parse first participant
        const p1_start = self.pos;
        while (!self.isAtEnd() and self.isIdChar(self.current())) {
            self.advance();
        }
        participant1 = self.source[p1_start..self.pos];

        // Check for second participant (for "over A,B")
        self.skipWhitespace();
        if (self.matchChar(',')) {
            self.skipWhitespace();
            const p2_start = self.pos;
            while (!self.isAtEnd() and self.isIdChar(self.current())) {
                self.advance();
            }
            participant2 = self.source[p2_start..self.pos];
        }

        // Parse note text (after colon)
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

        // Store note
        if (participant1) |p1| {
            if (p1.len > 0) {
                // Ensure participants exist
                try diagram.addParticipant(.{ .id = p1 });
                if (participant2) |p2| {
                    if (p2.len > 0) {
                        try diagram.addParticipant(.{ .id = p2 });
                    }
                }

                // Add note
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

        // Parse participant ID
        const id_start = self.pos;
        while (!self.isAtEnd() and (self.isIdChar(self.current()) or self.current() == '_')) {
            self.advance();
        }
        const participant_id = self.source[id_start..self.pos];

        if (participant_id.len > 0) {
            // Ensure participant exists
            try diagram.addParticipant(.{ .id = participant_id });

            // Add activation element
            try diagram.addActivation(.{
                .participant = participant_id,
                .is_activate = is_activate,
            });
        }

        self.skipToNextLine();
    }

    // =====================================================
    // Class Diagram Parsing
    // =====================================================

    /// Parse a class diagram
    pub fn parseClassDiagram(allocator: Allocator, source: []const u8) !ClassDiagram {
        var parser = Parser.init(allocator, source);
        return parser.parseClassDiagramInternal();
    }

    fn parseClassDiagramInternal(self: *Parser) !ClassDiagram {
        var diagram = ClassDiagram.init(self.allocator);
        errdefer diagram.deinit();

        self.skipWhitespaceAndComments();

        // Skip "classDiagram" keyword
        _ = self.consumeKeyword("classDiagram");
        self.skipToNextLine();

        // Parse body
        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;

            // Skip known keywords that we don't handle
            if (self.consumeKeyword("direction") or
                self.consumeKeyword("note") or
                self.consumeKeyword("callback") or
                self.consumeKeyword("link") or
                self.consumeKeyword("cssClass"))
            {
                self.skipToNextLine();
                continue;
            }

            // Handle "class ClassName" definition
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

            // Try to parse a relationship or member definition
            const parsed = try self.parseClassStatement(&diagram);
            if (!parsed) {
                self.skipToNextLine();
            }
        }

        return diagram;
    }

    fn parseClassStatement(self: *Parser, diagram: *ClassDiagram) !bool {
        const start_pos = self.pos;

        // Parse first identifier (class name)
        const first_name = self.parseClassName();
        if (first_name.len == 0) {
            self.pos = start_pos;
            return false;
        }

        self.skipWhitespace();

        // Check for member definition: ClassName : member
        if (self.matchChar(':')) {
            self.skipWhitespace();
            try self.parseClassMember(diagram, first_name);
            return true;
        }

        // Check for relationship
        const rel_type = self.parseClassRelation();
        if (rel_type) |relation_type| {
            self.skipWhitespace();

            // Parse second class name
            const second_name = self.parseClassName();
            if (second_name.len == 0) {
                self.pos = start_pos;
                return false;
            }

            // Parse optional label after colon
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

            // Ensure both classes exist
            try self.ensureClass(diagram, first_name);
            try self.ensureClass(diagram, second_name);

            // Add the relation
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
        // Class names can have hyphens and underscores
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
        // Order matters - check longer patterns first
        // <|-- inheritance (extends)
        if (self.matchString("<|--")) return .inheritance;
        if (self.matchString("--|>")) return .inheritance;
        // ..|> realization (implements)
        if (self.matchString("..|>")) return .realization;
        if (self.matchString("<|..")) return .realization;
        // *-- composition
        if (self.matchString("*--")) return .composition;
        if (self.matchString("--*")) return .composition;
        // o-- aggregation
        if (self.matchString("o--")) return .aggregation;
        if (self.matchString("--o")) return .aggregation;
        // ..> dependency
        if (self.matchString("..>")) return .dependency;
        if (self.matchString("<..")) return .dependency;
        // --> association
        if (self.matchString("-->")) return .association;
        if (self.matchString("<--")) return .association;
        // -- link
        if (self.matchString("--")) return .link;
        // .. dotted link (treat as dependency)
        if (self.matchString("..")) return .dependency;

        return null;
    }

    fn parseClassMember(self: *Parser, diagram: *ClassDiagram, class_name: []const u8) !void {
        // Ensure the class exists
        try self.ensureClass(diagram, class_name);

        // Get the class to add member to
        const class = diagram.getClassMut(class_name) orelse return;

        // Parse visibility
        var visibility: Visibility = .none;
        const first_char = self.current();
        if (first_char == '+' or first_char == '-' or first_char == '#' or first_char == '~') {
            visibility = Visibility.fromChar(first_char);
            self.advance();
        }

        // Parse the rest of the member definition
        const member_start = self.pos;
        while (!self.isAtEnd() and self.current() != '\n') {
            self.advance();
        }
        const member_text = std.mem.trimRight(u8, self.source[member_start..self.pos], " \t\r");

        if (member_text.len == 0) return;

        // Check if it's a method (contains parentheses)
        const is_method = std.mem.indexOf(u8, member_text, "(") != null;

        // Parse type and name
        var member_type: []const u8 = "";
        var name: []const u8 = member_text;

        // For "Type name" or "name Type" patterns
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

    // =====================================================
    // ER Diagram Parsing
    // =====================================================

    /// Parse an ER diagram
    pub fn parseERDiagram(allocator: Allocator, source: []const u8) !ERDiagram {
        var parser = Parser.init(allocator, source);
        return parser.parseERDiagramInternal();
    }

    fn parseERDiagramInternal(self: *Parser) !ERDiagram {
        var diagram = ERDiagram.init(self.allocator);
        errdefer diagram.deinit();

        self.skipWhitespaceAndComments();

        // Skip "erDiagram" keyword
        _ = self.consumeKeyword("erDiagram");
        self.skipToNextLine();

        // Parse body
        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;

            // Try to parse a relationship
            const parsed = try self.parseERStatement(&diagram);
            if (!parsed) {
                self.skipToNextLine();
            }
        }

        return diagram;
    }

    fn parseERStatement(self: *Parser, diagram: *ERDiagram) !bool {
        const start_pos = self.pos;

        // Parse first entity name
        const first_name = self.parseEntityName();
        if (first_name.len == 0) {
            self.pos = start_pos;
            return false;
        }

        self.skipWhitespace();

        // Check for relationship
        const rel = self.parseERRelation();
        if (rel) |relation| {
            self.skipWhitespace();

            // Parse second entity name
            const second_name = self.parseEntityName();
            if (second_name.len == 0) {
                self.pos = start_pos;
                return false;
            }

            // Parse optional label after colon
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

            // Ensure both entities exist
            try self.ensureEntity(diagram, first_name);
            try self.ensureEntity(diagram, second_name);

            // Add the relation
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

        // Could be entity definition with attributes (ENTITY { ... })
        // For now, just ensure the entity exists
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
        // Entity names can have hyphens and underscores
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
        // Parse left cardinality
        var left: Cardinality = .exactly_one;
        var right: Cardinality = .exactly_one;

        // Left side: ||, |o, }|, }o
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

        // Middle: -- or ..
        if (!self.matchString("--") and !self.matchString("..")) {
            return null;
        }

        // Right side: ||, o|, |{, o{
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

    // =====================================================
    // State Diagram Parsing
    // =====================================================

    /// Parse a state diagram
    pub fn parseStateDiagram(allocator: Allocator, source: []const u8) !StateDiagram {
        var parser = Parser.init(allocator, source);
        return parser.parseStateDiagramImpl();
    }

    fn parseStateDiagramImpl(self: *Parser) !StateDiagram {
        var diagram = StateDiagram.init(self.allocator);
        errdefer diagram.deinit();

        self.skipWhitespaceAndComments();

        // Skip "stateDiagram" or "stateDiagram-v2" keyword
        if (self.consumeKeyword("stateDiagram-v2") or self.consumeKeyword("stateDiagram")) {
            // Check for direction
            self.skipWhitespace();
            if (self.consumeKeyword("direction")) {
                self.skipWhitespace();
                diagram.direction = self.parseDirection();
            }
        }
        self.skipToNextLine();

        // Track start/end state counters for unique IDs
        var start_count: u32 = 0;
        var end_count: u32 = 0;

        // Parse body at top level (no parent)
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

            // Check for end of composite state
            if (self.peekKeyword("end") or self.current() == '}') {
                break;
            }

            // Check for direction directive
            if (self.consumeKeyword("direction")) {
                self.skipWhitespace();
                diagram.direction = self.parseDirection();
                self.skipToNextLine();
                continue;
            }

            // Check for state declaration with composite body
            if (self.consumeKeyword("state")) {
                try self.parseStateDeclaration(diagram, parent_id, start_count, end_count);
                continue;
            }

            // Check for note
            if (self.consumeKeyword("note") or self.consumeKeyword("Note")) {
                try self.parseStateNote(diagram);
                continue;
            }

            // Try to parse a transition or state reference
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

        // Parse state ID
        const id = self.parseStateId();
        if (id.len == 0) {
            self.skipToNextLine();
            return;
        }

        self.skipWhitespace();

        // Check for <<choice>>, <<fork>>, <<join>>
        var state_type: types.StateType = .regular;
        if (self.matchString("<<choice>>")) {
            state_type = .choice;
        } else if (self.matchString("<<fork>>")) {
            state_type = .fork;
        } else if (self.matchString("<<join>>")) {
            state_type = .join;
        }

        self.skipWhitespace();

        // Check for description after colon
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

        // Check for composite state body
        const is_composite = self.matchChar('{');

        // Add the state
        try diagram.addState(.{
            .id = id,
            .label = label,
            .state_type = state_type,
            .is_composite = is_composite,
            .parent_id = parent_id,
        });

        if (is_composite) {
            self.skipToNextLine();
            // Parse nested body
            try self.parseStateDiagramBody(diagram, id, start_count, end_count);
            // Consume closing brace or 'end'
            self.skipWhitespaceAndComments();
            if (self.matchChar('}')) {
                // OK
            } else if (self.consumeKeyword("end")) {
                // OK
            }
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

        // Parse first state reference (could be [*] or state ID)
        const first_state = try self.parseStateReference(diagram, parent_id, start_count, end_count, true);
        if (first_state.len == 0) {
            self.skipToNextLine();
            return;
        }

        self.skipWhitespace();

        // Check for transition arrow -->
        if (self.matchString("-->")) {
            self.skipWhitespace();

            // Parse optional label after :
            var label: ?[]const u8 = null;

            // Parse target state
            const second_state = try self.parseStateReference(diagram, parent_id, start_count, end_count, false);

            // Check for label after target with :
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

            // Add the transition
            try diagram.addTransition(.{
                .from = first_state,
                .to = second_state,
                .label = label,
            });
        } else if (self.matchChar(':')) {
            // State description: "StateId : description"
            self.skipWhitespace();
            const label_start = self.pos;
            while (!self.isAtEnd() and self.current() != '\n') {
                self.advance();
            }
            const label = std.mem.trimRight(u8, self.source[label_start..self.pos], " \t\r");

            // Update state with label
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

        // Check for [*] - start or end state
        if (self.matchString("[*]")) {
            // Determine if this is start or end based on position
            // [*] --> X means [*] is start
            // X --> [*] means [*] is end
            if (is_source) {
                // This is a start state
                const id = try self.makeStartId(start_count);
                try diagram.trackAllocatedId(id);
                try diagram.addState(.{
                    .id = id,
                    .state_type = .start,
                    .parent_id = parent_id,
                });
                return id;
            } else {
                // This is an end state - reuse existing end state at same scope if available
                // Search for existing end state with same parent
                for (diagram.state_order.items) |existing_id| {
                    if (diagram.getState(existing_id)) |existing_state| {
                        if (existing_state.state_type == .end) {
                            // Check if parent matches
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
                // No existing end state found, create new one
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

        // Parse regular state ID
        const id = self.parseStateId();
        if (id.len > 0) {
            // Ensure state exists
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
        // State IDs can contain letters, digits, underscores
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
        // Generate unique start state ID
        // We use a simple scheme: [*]_start_0, [*]_start_1, etc.
        const id = try std.fmt.allocPrint(self.allocator, "[*]_start_{d}", .{count.*});
        count.* += 1;
        return id;
    }

    fn makeEndId(self: *Parser, count: *u32) Allocator.Error![]const u8 {
        // Generate unique end state ID
        const id = try std.fmt.allocPrint(self.allocator, "[*]_end_{d}", .{count.*});
        count.* += 1;
        return id;
    }

    fn parseStateNote(self: *Parser, diagram: *StateDiagram) !void {
        self.skipWhitespace();

        // Parse position: "left of", "right of"
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

        // Parse state ID
        const state_id = self.parseStateId();
        if (state_id.len == 0) {
            self.skipToNextLine();
            return;
        }

        self.skipWhitespace();

        // Parse note text after colon
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

    // Both nodes should have their full labels
    const node_a = graph.getNode("A").?;
    const node_b = graph.getNode("B").?;
    try testing.expectEqualStrings("Node A", node_a.label);
    try testing.expectEqualStrings("Node B", node_b.label);
}

// =====================================================
// Sequence Diagram Tests
// =====================================================

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
    // Verify quotes are stripped from labels
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

    // Check first note
    try testing.expectEqual(types.NotePosition.right_of, diagram.notes.items[0].position);
    try testing.expectEqualStrings("Bob", diagram.notes.items[0].participant1);
    try testing.expectEqualStrings("Bob thinks", diagram.notes.items[0].text);

    // Check second note
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

// =====================================================
// Class Diagram Tests
// =====================================================

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

    // Check classes exist
    try testing.expect(diagram.getClass("Animal") != null);
    try testing.expect(diagram.getClass("Duck") != null);

    // Check relation
    const rel = diagram.relations.items[0];
    try testing.expectEqualStrings("Animal", rel.from);
    try testing.expectEqualStrings("Duck", rel.to);
    try testing.expectEqual(ClassRelationType.inheritance, rel.relation_type);

    // Check members
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

// =====================================================
// ER Diagram Tests
// =====================================================

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

    // Check entities exist
    try testing.expect(diagram.getEntity("CUSTOMER") != null);
    try testing.expect(diagram.getEntity("ORDER") != null);
    try testing.expect(diagram.getEntity("LINE-ITEM") != null);

    // Check first relation
    const rel1 = diagram.relations.items[0];
    try testing.expectEqualStrings("CUSTOMER", rel1.from);
    try testing.expectEqualStrings("ORDER", rel1.to);
    try testing.expectEqual(Cardinality.exactly_one, rel1.from_cardinality);
    try testing.expectEqual(Cardinality.zero_or_more, rel1.to_cardinality);
    try testing.expectEqualStrings("places", rel1.label.?);

    // Check second relation
    const rel2 = diagram.relations.items[1];
    try testing.expectEqualStrings("ORDER", rel2.from);
    try testing.expectEqualStrings("LINE-ITEM", rel2.to);
    try testing.expectEqual(Cardinality.exactly_one, rel2.from_cardinality);
    try testing.expectEqual(Cardinality.one_or_more, rel2.to_cardinality);
}

// =====================================================
// State Diagram Tests
// =====================================================

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

    // Should have: 1 start, 1 end (reused), 3 regular states = 5 total
    try testing.expectEqual(@as(usize, 5), diagram.state_order.items.len);
    try testing.expectEqual(@as(usize, 6), diagram.transitions.items.len);

    // Check states exist
    try testing.expect(diagram.getState("Still") != null);
    try testing.expect(diagram.getState("Moving") != null);
    try testing.expect(diagram.getState("Crash") != null);

    // Check start state
    try testing.expect(diagram.getState("[*]_start_0") != null);
    try testing.expectEqual(StateType.start, diagram.getState("[*]_start_0").?.state_type);

    // Check end states - there's only one end state (multiple transitions go to it)
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

    // Check First is composite
    const first = diagram.getState("First").?;
    try testing.expect(first.is_composite);

    // Check second is inside First
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

    // Check choice state
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
