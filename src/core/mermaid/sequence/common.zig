//! What the top-down and left-to-right sequence renderers share: the participant box and the
//! activation bars.

const types = @import("../types.zig");
const model = @import("model.zig");
const Canvas = @import("../shared/canvas.zig").Canvas;

const Participant = model.Participant;
const SequenceDiagram = model.SequenceDiagram;

/// How a participant name is written: `scalar` drops a name the canvas cannot place one scalar
/// to a cell, `spanning` keeps one terminal column per cell.
pub const NameText = enum { scalar, spanning };

pub fn drawParticipantBox(canvas: *Canvas, participant: *const Participant, y: i32, name_text: NameText) !void {
    const rect = types.Rect{
        .x = participant.x,
        .y = y,
        .width = participant.box_width,
        .height = 3,
    };
    canvas.drawBox(rect, types.unicode_rounded, .node_border);
    switch (name_text) {
        .scalar => canvas.drawTextCentered(rect, participant.displayName(), .node_text),
        .spanning => try canvas.drawTextCenteredSpanning(rect, participant.displayName(), .node_text),
    }
}

pub fn drawLifelines(canvas: *Canvas, diagram: *const SequenceDiagram, top: i32, bottom: i32) void {
    for (diagram.participants.items) |*p| {
        canvas.drawVerticalLine(p.centerX(), top, bottom, types.LineChars.vertical_dotted, .edge);
    }
}

/// A closed activation: the participant it sits on and its extent along the time axis.
pub const Bar = struct {
    participant: *const Participant,
    start: i32,
    end: i32,
};

/// Pairs each deactivate with the activate before it. Only the first sixteen participants
/// are tracked.
pub const Activations = struct {
    pub const tracked = 16;

    starts: [tracked]i32 = .{-1} ** tracked,

    /// Take in one activate or deactivate seen at `pos` along the time axis. An activate opens a
    /// bar one step before `pos`; a deactivate closes the open one one step before `pos`.
    pub fn apply(self: *Activations, diagram: *const SequenceDiagram, act: model.Activation, pos: i32) ?Bar {
        const idx = diagram.getParticipantIndex(act.participant) orelse return null;
        if (idx >= tracked) return null;
        if (act.is_activate) {
            self.starts[idx] = pos - 1;
            return null;
        }
        const start = self.starts[idx];
        if (start < 0) return null;
        self.starts[idx] = -1;
        return .{ .participant = &diagram.participants.items[idx], .start = start, .end = pos - 1 };
    }
};
