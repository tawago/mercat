const std = @import("std");
const model = @import("model.zig");

pub const ArrowKind = model.SequenceArrowType;
pub const FragmentKind = model.FragmentKind;
pub const NotePosition = @import("../types.zig").NotePosition;

pub const PartIx = u32;
pub const StepIx = u32;
pub const TextIx = u32;
pub const FragIx = u32;

pub const Message = struct { from: PartIx, to: PartIx, kind: ArrowKind, label: TextIx };

pub const Note = struct { position: NotePosition, first: PartIx, last: PartIx, text: TextIx };

pub const Step = union(enum) {
    message: Message,
    note: Note,

    pub fn isSelf(self: Step) bool {
        return self == .message and self.message.from == self.message.to;
    }
};

pub const Bar = struct { part: PartIx, first: StepIx, last: StepIx, depth: u8, joined: bool = false, engage: u32 = 0, release: u32 = 0 };

pub const Operand = struct { guard: ?TextIx };

pub const Fragment = struct {
    kind: FragmentKind,
    operands: []const Operand,
    parent: ?FragIx,
    depth: u8,
    lo: PartIx,
    hi: PartIx,
};

pub const Item = union(enum) {
    step: StepIx,
    open: FragIx,
    divider: struct { frag: FragIx, operand: u32 },
    close: FragIx,
    engage,
    release,
};

pub const Sequence = struct {
    texts: []const []const u8,
    names: []const TextIx,
    steps: []const Step,
    items: []const Item,
    bars: []const Bar,
    frags: []const Fragment,

    pub fn partCount(self: *const Sequence) usize {
        return self.names.len;
    }

    pub fn hasTopDownOnly(self: *const Sequence) bool {
        if (self.bars.len > 0 or self.frags.len > 0) return true;
        for (self.steps) |step| if (step == .note) return true;
        return false;
    }
};
