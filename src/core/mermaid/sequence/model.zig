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
    x: ?i32 = null,
    y: ?i32 = null,
    box_width: u32 = 0,

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
