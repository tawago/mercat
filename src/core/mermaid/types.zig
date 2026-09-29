const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text");

pub const DiagramType = enum {
    flowchart,
    sequence,
    class_diagram,
    state,
    er,
    unsupported,

    pub fn fromSource(source: []const u8) DiagramType {
        const trimmed = text.firstMeaningfulLine(source, "%%");
        if (std.mem.startsWith(u8, trimmed, "graph") or
            std.mem.startsWith(u8, trimmed, "flowchart"))
        {
            return .flowchart;
        }
        if (std.mem.startsWith(u8, trimmed, "sequenceDiagram")) return .sequence;
        if (std.mem.startsWith(u8, trimmed, "classDiagram")) return .class_diagram;
        if (std.mem.startsWith(u8, trimmed, "stateDiagram")) return .state;
        if (std.mem.startsWith(u8, trimmed, "erDiagram")) return .er;
        return .unsupported;
    }
};

pub const Direction = enum {
    LR,
    RL,
    TD,
    TB,
    BT,
};

pub const BoxChars = struct {
    top_left: u21,
    top_right: u21,
    bottom_left: u21,
    bottom_right: u21,
    horizontal: u21,
    vertical: u21,
};

pub const unicode_square: BoxChars = .{
    .top_left = 0x250C,
    .top_right = 0x2510,
    .bottom_left = 0x2514,
    .bottom_right = 0x2518,
    .horizontal = 0x2500,
    .vertical = 0x2502,
};

pub const unicode_rounded: BoxChars = .{
    .top_left = 0x256D,
    .top_right = 0x256E,
    .bottom_left = 0x2570,
    .bottom_right = 0x256F,
    .horizontal = 0x2500,
    .vertical = 0x2502,
};

pub const ascii_box: BoxChars = .{
    .top_left = '+',
    .top_right = '+',
    .bottom_left = '+',
    .bottom_right = '+',
    .horizontal = '-',
    .vertical = '|',
};

pub const BoxDrawingStyle = enum {
    standard,
    rounded,
    heavy,
    double,
    ascii,
};

pub const Arrows = struct {
    pub const right: u21 = 0x25B6;
    pub const left: u21 = 0x25C0;
    pub const up: u21 = 0x25B2;
    pub const down: u21 = 0x25BC;

    pub const right_thin: u21 = 0x25BA;
    pub const left_thin: u21 = 0x25C4;
    pub const up_thin: u21 = 0x25B2;
    pub const down_thin: u21 = 0x25BC;

    pub const right_ascii: u21 = '>';
    pub const left_ascii: u21 = '<';
    pub const up_ascii: u21 = '^';
    pub const down_ascii: u21 = 'v';
};

pub const LineChars = struct {
    pub const horizontal: u21 = 0x2500;
    pub const vertical: u21 = 0x2502;
    pub const corner_ne: u21 = 0x2514;
    pub const corner_nw: u21 = 0x2518;
    pub const corner_se: u21 = 0x250C;
    pub const corner_sw: u21 = 0x2510;
    pub const tee_left: u21 = 0x2524;
    pub const tee_right: u21 = 0x251C;
    pub const tee_up: u21 = 0x2534;
    pub const tee_down: u21 = 0x252C;
    pub const cross: u21 = 0x253C;

    pub const horizontal_dotted: u21 = 0x2504;
    pub const vertical_dotted: u21 = 0x2506;

    pub const horizontal_dashed: u21 = 0x2508;
    pub const vertical_dashed: u21 = 0x250A;

    pub const tee_down_double: u21 = 0x2565;

    pub const horizontal_thick: u21 = 0x2501;
    pub const vertical_thick: u21 = 0x2503;
};

pub const Point = struct {
    x: i32,
    y: i32,

    pub fn eql(self: Point, other: Point) bool {
        return self.x == other.x and self.y == other.y;
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and
            p.x < self.x + @as(i32, @intCast(self.width)) and
            p.y >= self.y and
            p.y < self.y + @as(i32, @intCast(self.height));
    }

    pub fn right(self: Rect) i32 {
        return self.x + @as(i32, @intCast(self.width));
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + @as(i32, @intCast(self.height));
    }
};

pub const CrossingReductionHeuristic = enum {
    median,
    barycenter,
};

pub const ForceLayout = enum {
    auto,
    sugiyama,
    tree,
    force,

    pub fn displayName(self: ForceLayout) []const u8 {
        return switch (self) {
            .auto => "auto",
            .sugiyama => "sugiyama",
            .tree => "tree",
            .force => "force",
        };
    }

    pub fn next(self: ForceLayout) ForceLayout {
        return switch (self) {
            .auto => .sugiyama,
            .sugiyama => .tree,
            .tree => .force,
            .force => .auto,
        };
    }
};

pub const LayoutAlgorithm = enum {
    sugiyama,
    reingold_tilford,
    fruchterman_reingold,
    kamada_kawai,
    stress_majorization,
    dominance_drawing,
    layered_bfs,
    unknown,
};

pub const FitStage = enum {
    natural,
    label_wrap,
    direction_switch,
    spacing_compress,
    label_truncate,
    overflow,

    pub fn description(self: FitStage) []const u8 {
        return switch (self) {
            .natural => "natural fit",
            .label_wrap => "labels wrapped",
            .direction_switch => "direction switched",
            .spacing_compress => "spacing compressed",
            .label_truncate => "labels truncated",
            .overflow => "overflow (fallback)",
        };
    }
};

pub const RenderOptions = struct {
    max_width: u32 = 120,
    unicode_mode: bool = true,
    node_padding: u32 = 1,
    horizontal_spacing: u32 = 8,
    vertical_spacing: u32 = 3,
    max_label_width: ?u32 = null,
    crossing_reduction_heuristic: CrossingReductionHeuristic = .median,
    box_drawing_style: BoxDrawingStyle = .standard,
    force_layout: ForceLayout = .auto,
    subgraph_edges: @import("prim").SubgraphEdges = .bridge,
    aspect_ratio_x: f32 = 1.0,
    aspect_ratio_y: f32 = 1.0,
    debug_mermaid: bool = false,
};

pub const CompactionLevel = enum {
    default,
    reduced,
    tight,
    direction_switch,
};

pub const CompactionHints = struct {
    level: CompactionLevel,
    render_options: RenderOptions,
    sequence_participant_spacing: u32 = 8,
    sequence_padding: u32 = 2,
    sequence_direction: ?Direction = null,
};

pub const RenderResult = struct {
    output: []const u8,
    width: u32,
    height: u32,
    is_fallback: bool = false,
    fallback_reason: ?[]const u8 = null,
    algorithm_used: LayoutAlgorithm = .unknown,
    node_count: u32 = 0,
    edge_count: u32 = 0,
    is_tree: bool = false,
    is_cyclic: bool = false,
    width_constraint_triggered: bool = false,
    crossing_reduction_iterations: u32 = 0,
    fit_stage: FitStage = .natural,
    original_direction: ?Direction = null,
};

pub const SequenceArrowType = enum {
    solid_arrow,
    solid_line,
    dashed_arrow,
    dashed_line,
    solid_cross,
    dashed_cross,
    solid_open,
    dashed_open,

    pub fn isDashed(self: SequenceArrowType) bool {
        return switch (self) {
            .dashed_arrow, .dashed_line, .dashed_cross, .dashed_open => true,
            else => false,
        };
    }

    pub fn hasArrowhead(self: SequenceArrowType) bool {
        return switch (self) {
            .solid_arrow, .dashed_arrow, .solid_open, .dashed_open => true,
            else => false,
        };
    }
};

pub const Participant = struct {
    id: []const u8,
    alias: ?[]const u8 = null,
    participant_type: ParticipantType = .participant,
    x: ?i32 = null,
    y: ?i32 = null,
    box_width: u32 = 0,

    pub fn displayName(self: *const Participant) []const u8 {
        return self.alias orelse self.id;
    }
};

pub const ParticipantType = enum {
    participant,
    actor,
};

pub const Message = struct {
    from: []const u8,
    to: []const u8,
    text: []const u8,
    arrow_type: SequenceArrowType = .solid_arrow,
    is_self_message: bool = false,
};

pub const SequenceNote = struct {
    position: NotePosition,
    participant1: []const u8,
    participant2: ?[]const u8 = null,
    text: []const u8,
};

pub const NotePosition = enum {
    left_of,
    right_of,
    over,
};

pub const Activation = struct {
    participant: []const u8,
    is_activate: bool,
};

pub const SequenceElement = union(enum) {
    message: Message,
    note: SequenceNote,
    activation: Activation,
};

pub const SequenceDiagram = struct {
    allocator: Allocator,
    participants: std.ArrayList(Participant),
    messages: std.ArrayList(Message),
    notes: std.ArrayList(SequenceNote),
    elements: std.ArrayList(SequenceElement),
    direction: Direction = .TB,
    direction_explicit: bool = false,
    auto_number: bool = false,

    pub fn init(allocator: Allocator) SequenceDiagram {
        return .{
            .allocator = allocator,
            .participants = .empty,
            .messages = .empty,
            .notes = .empty,
            .elements = .empty,
        };
    }

    pub fn deinit(self: *SequenceDiagram) void {
        self.participants.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.notes.deinit(self.allocator);
        self.elements.deinit(self.allocator);
    }

    pub fn addParticipant(self: *SequenceDiagram, participant: Participant) !void {
        for (self.participants.items) |p| {
            if (std.mem.eql(u8, p.id, participant.id)) {
                return;
            }
        }
        try self.participants.append(self.allocator, participant);
    }

    pub fn addMessage(self: *SequenceDiagram, message: Message) !void {
        try self.messages.append(self.allocator, message);
        try self.elements.append(self.allocator, .{ .message = message });
    }

    pub fn addNote(self: *SequenceDiagram, note: SequenceNote) !void {
        try self.notes.append(self.allocator, note);
        try self.elements.append(self.allocator, .{ .note = note });
    }

    pub fn addActivation(self: *SequenceDiagram, activation: Activation) !void {
        try self.elements.append(self.allocator, .{ .activation = activation });
    }

    pub fn getParticipant(self: *const SequenceDiagram, id: []const u8) ?*const Participant {
        for (self.participants.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) {
                return p;
            }
        }
        return null;
    }

    pub fn getParticipantIndex(self: *const SequenceDiagram, id: []const u8) ?usize {
        for (self.participants.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.id, id)) {
                return i;
            }
        }
        return null;
    }
};

pub const Visibility = enum {
    public,
    private,
    protected,
    package,
    none,

    pub fn toChar(self: Visibility) ?u8 {
        return switch (self) {
            .public => '+',
            .private => '-',
            .protected => '#',
            .package => '~',
            .none => null,
        };
    }

    pub fn fromChar(c: u8) Visibility {
        return switch (c) {
            '+' => .public,
            '-' => .private,
            '#' => .protected,
            '~' => .package,
            else => .none,
        };
    }
};

pub const ClassMember = struct {
    name: []const u8,
    member_type: []const u8,
    visibility: Visibility = .none,
    is_method: bool = false,
    is_static: bool = false,
    is_abstract: bool = false,
};

pub const ClassRelationType = enum {
    inheritance,
    composition,
    aggregation,
    association,
    dependency,
    realization,
    link,

    pub fn getArrowChars(self: ClassRelationType, unicode_mode: bool) struct { start: []const u8, end: []const u8, line: u21 } {
        if (!unicode_mode) {
            return switch (self) {
                .inheritance => .{ .start = "", .end = "<|", .line = '-' },
                .composition => .{ .start = "*", .end = "", .line = '-' },
                .aggregation => .{ .start = "o", .end = "", .line = '-' },
                .association => .{ .start = "", .end = ">", .line = '-' },
                .dependency => .{ .start = "", .end = ">", .line = '.' },
                .realization => .{ .start = "", .end = "|>", .line = '.' },
                .link => .{ .start = "", .end = "", .line = '-' },
            };
        }
        return switch (self) {
            .inheritance => .{ .start = "", .end = "◁", .line = 0x2500 },
            .composition => .{ .start = "◆", .end = "", .line = 0x2500 },
            .aggregation => .{ .start = "◇", .end = "", .line = 0x2500 },
            .association => .{ .start = "", .end = "▶", .line = 0x2500 },
            .dependency => .{ .start = "", .end = "▶", .line = 0x2504 },
            .realization => .{ .start = "", .end = "◁", .line = 0x2504 },
            .link => .{ .start = "", .end = "", .line = 0x2500 },
        };
    }
};

pub const Class = struct {
    name: []const u8,
    members: std.ArrayList(ClassMember),
    allocator: Allocator,
    x: ?i32 = null,
    y: ?i32 = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(allocator: Allocator, name: []const u8) Class {
        return .{
            .name = name,
            .members = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Class) void {
        self.members.deinit(self.allocator);
    }

    pub fn addMember(self: *Class, member: ClassMember) !void {
        try self.members.append(self.allocator, member);
    }
};

pub const ClassRelation = struct {
    from: []const u8,
    to: []const u8,
    relation_type: ClassRelationType = .association,
    label: ?[]const u8 = null,
    from_cardinality: ?[]const u8 = null,
    to_cardinality: ?[]const u8 = null,
};

pub const ClassDiagram = struct {
    allocator: Allocator,
    classes: std.StringHashMap(Class),
    relations: std.ArrayList(ClassRelation),
    class_order: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) ClassDiagram {
        return .{
            .allocator = allocator,
            .classes = std.StringHashMap(Class).init(allocator),
            .relations = .empty,
            .class_order = .empty,
        };
    }

    pub fn deinit(self: *ClassDiagram) void {
        var it = self.classes.valueIterator();
        while (it.next()) |class| {
            @constCast(class).deinit();
        }
        self.classes.deinit();
        self.relations.deinit(self.allocator);
        self.class_order.deinit(self.allocator);
    }

    pub fn getClass(self: *const ClassDiagram, name: []const u8) ?*const Class {
        return self.classes.getPtr(name);
    }

    pub fn getClassMut(self: *ClassDiagram, name: []const u8) ?*Class {
        return self.classes.getPtr(name);
    }

    pub fn addRelation(self: *ClassDiagram, relation: ClassRelation) !void {
        try self.relations.append(self.allocator, relation);
    }
};

pub const Cardinality = enum {
    zero_or_one,
    exactly_one,
    zero_or_more,
    one_or_more,

    pub fn toStringLeft(self: Cardinality, unicode_mode: bool) []const u8 {
        _ = unicode_mode;
        return switch (self) {
            .zero_or_one => "o|",
            .exactly_one => "||",
            .zero_or_more => "}o",
            .one_or_more => "}|",
        };
    }

    pub fn toStringRight(self: Cardinality, unicode_mode: bool) []const u8 {
        _ = unicode_mode;
        return switch (self) {
            .zero_or_one => "|o",
            .exactly_one => "||",
            .zero_or_more => "o{",
            .one_or_more => "|{",
        };
    }
};

pub const Entity = struct {
    name: []const u8,
    attributes: std.ArrayList(EntityAttribute),
    allocator: Allocator,
    x: ?i32 = null,
    y: ?i32 = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(allocator: Allocator, name: []const u8) Entity {
        return .{
            .name = name,
            .attributes = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Entity) void {
        self.attributes.deinit(self.allocator);
    }
};

pub const EntityAttribute = struct {
    name: []const u8,
    attr_type: []const u8,
    is_primary_key: bool = false,
    is_foreign_key: bool = false,
};

pub const ERRelation = struct {
    from: []const u8,
    to: []const u8,
    from_cardinality: Cardinality = .exactly_one,
    to_cardinality: Cardinality = .exactly_one,
    label: ?[]const u8 = null,
};

pub const ERDiagram = struct {
    allocator: Allocator,
    entities: std.StringHashMap(Entity),
    relations: std.ArrayList(ERRelation),
    entity_order: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) ERDiagram {
        return .{
            .allocator = allocator,
            .entities = std.StringHashMap(Entity).init(allocator),
            .relations = .empty,
            .entity_order = .empty,
        };
    }

    pub fn deinit(self: *ERDiagram) void {
        var it = self.entities.valueIterator();
        while (it.next()) |entity| {
            @constCast(entity).deinit();
        }
        self.entities.deinit();
        self.relations.deinit(self.allocator);
        self.entity_order.deinit(self.allocator);
    }

    pub fn getEntity(self: *const ERDiagram, name: []const u8) ?*const Entity {
        return self.entities.getPtr(name);
    }

    pub fn getEntityMut(self: *ERDiagram, name: []const u8) ?*Entity {
        return self.entities.getPtr(name);
    }

    pub fn addRelation(self: *ERDiagram, relation: ERRelation) !void {
        try self.relations.append(self.allocator, relation);
    }
};

pub const StateType = enum {
    start,
    end,
    regular,
    choice,
    fork,
    join,
    composite,
};

pub const State = struct {
    id: []const u8,
    label: ?[]const u8 = null,
    state_type: StateType = .regular,
    is_composite: bool = false,
    parent_id: ?[]const u8 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    width: u32 = 0,
    height: u32 = 0,
    layer: ?u32 = null,

    pub fn displayName(self: *const State) []const u8 {
        if (self.state_type == .start) return "[*]";
        if (self.state_type == .end) return "[*]";
        return self.label orelse self.id;
    }
};

pub const StateTransition = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8 = null,
};

pub const StateNote = struct {
    state_id: []const u8,
    text: []const u8,
    position: NotePosition = .right_of,
};

pub const StateDiagram = struct {
    allocator: Allocator,
    states: std.StringHashMap(State),
    transitions: std.ArrayList(StateTransition),
    notes: std.ArrayList(StateNote),
    state_order: std.ArrayList([]const u8),
    allocated_ids: std.ArrayList([]const u8),
    direction: Direction = .TD,

    pub fn init(allocator: Allocator) StateDiagram {
        return .{
            .allocator = allocator,
            .states = std.StringHashMap(State).init(allocator),
            .transitions = .empty,
            .notes = .empty,
            .state_order = .empty,
            .allocated_ids = .empty,
        };
    }

    pub fn deinit(self: *StateDiagram) void {
        for (self.allocated_ids.items) |id| {
            self.allocator.free(id);
        }
        self.allocated_ids.deinit(self.allocator);
        self.states.deinit();
        self.transitions.deinit(self.allocator);
        self.notes.deinit(self.allocator);
        self.state_order.deinit(self.allocator);
    }

    pub fn trackAllocatedId(self: *StateDiagram, id: []const u8) !void {
        try self.allocated_ids.append(self.allocator, id);
    }

    pub fn addState(self: *StateDiagram, state: State) !void {
        const result = try self.states.getOrPut(state.id);
        if (!result.found_existing) {
            result.value_ptr.* = state;
            try self.state_order.append(self.allocator, state.id);
        } else {
            if (state.label != null and result.value_ptr.label == null) {
                result.value_ptr.label = state.label;
            }
            if (state.is_composite) {
                result.value_ptr.is_composite = true;
            }
            if (state.state_type != .regular and result.value_ptr.state_type == .regular) {
                result.value_ptr.state_type = state.state_type;
            }
        }
    }

    pub fn addTransition(self: *StateDiagram, transition: StateTransition) !void {
        try self.transitions.append(self.allocator, transition);
    }

    pub fn addNote(self: *StateDiagram, note: StateNote) !void {
        try self.notes.append(self.allocator, note);
    }

    pub fn getState(self: *const StateDiagram, id: []const u8) ?*const State {
        return self.states.getPtr(id);
    }

    pub fn getStateMut(self: *StateDiagram, id: []const u8) ?*State {
        return self.states.getPtr(id);
    }

    pub fn getLayerCount(self: *const StateDiagram) u32 {
        var max_layer: u32 = 0;
        var it = self.states.valueIterator();
        while (it.next()) |state| {
            if (state.layer) |l| {
                if (l > max_layer) max_layer = l;
            }
        }
        return max_layer + 1;
    }
};

test "DiagramType detection" {
    const testing = std.testing;

    try testing.expectEqual(DiagramType.flowchart, DiagramType.fromSource("graph LR"));
    try testing.expectEqual(DiagramType.flowchart, DiagramType.fromSource("flowchart TD"));
    try testing.expectEqual(DiagramType.flowchart, DiagramType.fromSource("  graph LR\n  A --> B"));
    try testing.expectEqual(DiagramType.sequence, DiagramType.fromSource("sequenceDiagram"));
    try testing.expectEqual(DiagramType.class_diagram, DiagramType.fromSource("classDiagram"));
    try testing.expectEqual(DiagramType.state, DiagramType.fromSource("stateDiagram"));
    try testing.expectEqual(DiagramType.state, DiagramType.fromSource("stateDiagram-v2"));
    try testing.expectEqual(DiagramType.er, DiagramType.fromSource("erDiagram"));
    try testing.expectEqual(DiagramType.unsupported, DiagramType.fromSource("pie"));
    try testing.expectEqual(DiagramType.unsupported, DiagramType.fromSource("gantt"));
}

test "StateDiagram basic operations" {
    const testing = std.testing;
    var diagram = StateDiagram.init(testing.allocator);
    defer diagram.deinit();

    try diagram.addState(.{ .id = "s1", .label = "State 1" });
    try diagram.addState(.{ .id = "s2", .label = "State 2" });
    try diagram.addState(.{ .id = "[*]_start", .state_type = .start });
    try diagram.addState(.{ .id = "[*]_end", .state_type = .end });

    try diagram.addTransition(.{ .from = "[*]_start", .to = "s1" });
    try diagram.addTransition(.{ .from = "s1", .to = "s2", .label = "go" });
    try diagram.addTransition(.{ .from = "s2", .to = "[*]_end" });

    try testing.expect(diagram.getState("s1") != null);
    try testing.expect(diagram.getState("s2") != null);
    try testing.expect(diagram.getState("s3") == null);
    try testing.expectEqual(@as(usize, 3), diagram.transitions.items.len);
    try testing.expectEqual(@as(usize, 4), diagram.state_order.items.len);
}
