const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");

const Direction = types.Direction;
const NotePosition = types.NotePosition;

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

    pub fn displayName(self: *const Participant) []const u8 {
        return self.alias orelse self.id;
    }
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

pub const Activation = struct {
    participant: []const u8,
    is_activate: bool,
};

pub const FragmentKind = enum {
    loop,
    alt,
    opt,
    par,
    critical,
    break_,

    pub fn word(self: FragmentKind) []const u8 {
        return switch (self) {
            .break_ => "break",
            else => @tagName(self),
        };
    }

    /// The keyword that opens a later operand of this kind, if it has one.
    pub fn dividerWord(self: FragmentKind) ?[]const u8 {
        return switch (self) {
            .alt => "else",
            .par => "and",
            .critical => "option",
            else => null,
        };
    }
};

pub const FragmentOpen = struct { kind: FragmentKind, guard: []const u8 };

pub const FragmentDivider = struct { guard: []const u8 };

pub const SequenceElement = union(enum) {
    message: Message,
    note: SequenceNote,
    activation: Activation,
    fragment_open: FragmentOpen,
    fragment_divider: FragmentDivider,
    fragment_close,
};

pub const SequenceDiagram = struct {
    allocator: Allocator,
    participants: std.ArrayList(Participant),
    elements: std.ArrayList(SequenceElement),
    direction: Direction = .TB,
    direction_explicit: bool = false,

    pub fn init(allocator: Allocator) SequenceDiagram {
        return .{
            .allocator = allocator,
            .participants = .empty,
            .elements = .empty,
        };
    }

    pub fn deinit(self: *SequenceDiagram) void {
        self.participants.deinit(self.allocator);
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
        try self.elements.append(self.allocator, .{ .message = message });
    }

    pub fn addNote(self: *SequenceDiagram, note: SequenceNote) !void {
        try self.elements.append(self.allocator, .{ .note = note });
    }

    pub fn addActivation(self: *SequenceDiagram, activation: Activation) !void {
        try self.elements.append(self.allocator, .{ .activation = activation });
    }

    pub fn addElement(self: *SequenceDiagram, element: SequenceElement) !void {
        try self.elements.append(self.allocator, element);
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
