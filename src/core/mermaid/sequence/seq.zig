//! The sequence exchange in index form: participants, steps in declared order, activation bars
//! bound to steps, and fragments as a tree over the steps. No geometry.

const std = @import("std");
const model = @import("model.zig");

pub const ArrowKind = model.SequenceArrowType;
pub const FragmentKind = model.FragmentKind;
pub const NotePosition = @import("../types.zig").NotePosition;

pub const PartIx = u32;
pub const StepIx = u32;
pub const TextIx = u32;
pub const FragIx = u32;

/// A message between two participants, or a self message when `from == to`.
pub const Message = struct { from: PartIx, to: PartIx, kind: ArrowKind, label: TextIx };

/// `first == last` unless the note stands over two participants.
pub const Note = struct { position: NotePosition, first: PartIx, last: PartIx, text: TextIx };

pub const Step = union(enum) {
    message: Message,
    note: Note,

    pub fn isSelf(self: Step) bool {
        return self == .message and self.message.from == self.message.to;
    }
};

/// An activation over steps `first` to `last`. `depth` is its rank among the bars open on its
/// participant, 1 for the outermost. A `joined` bar reopens the bar of its participant and depth
/// whose deactivate stands just before its activate. `engage` and `release` are the indices of the
/// items where its activate and deactivate stand.
pub const Bar = struct { part: PartIx, first: StepIx, last: StepIx, depth: u8, joined: bool = false, engage: u32 = 0, release: u32 = 0 };

pub const Operand = struct { guard: ?TextIx };

pub const Fragment = struct {
    kind: FragmentKind,
    operands: []const Operand,
    parent: ?FragIx,
    depth: u8,
    /// The participants its messages and notes touch, nested fragments included.
    lo: PartIx,
    hi: PartIx,
};

pub const Item = union(enum) {
    step: StepIx,
    open: FragIx,
    divider: struct { frag: FragIx, operand: u32 },
    close: FragIx,
    /// An activate: the bars it opens start by the item before it.
    engage,
    /// A deactivate: the bars it closes end on the row placed here.
    release,
};

pub const Sequence = struct {
    /// Raw text by index: participant names, labels, guards (bracketed) and notes.
    texts: []const []const u8,
    names: []const TextIx,
    steps: []const Step,
    items: []const Item,
    bars: []const Bar,
    frags: []const Fragment,

    pub fn partCount(self: *const Sequence) usize {
        return self.names.len;
    }

    /// Activations, fragments or notes: what only the top-down direction draws.
    pub fn hasTopDownOnly(self: *const Sequence) bool {
        if (self.bars.len > 0 or self.frags.len > 0) return true;
        for (self.steps) |step| if (step == .note) return true;
        return false;
    }
};
