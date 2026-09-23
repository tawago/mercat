const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const driver = @import("budget.zig");

pub const Rung = driver.Rung;
pub const LadderResult = driver.LadderResult;

pub const Candidate = struct {
    rung: Rung,
    sketch: sketch.Sketch,
    accepted: bool,
    transform: Transform = .raw,
};

pub const Transform = enum {
    raw,
    motif_pack,
    bridge_dodged,
    bridge_railed,

    pub fn appliesTo(t: Transform, d: sem_graph.Direction) bool {
        return switch (t) {
            .raw, .bridge_dodged, .bridge_railed => true,
            .motif_pack => d == .TD or d == .BT,
        };
    }

    pub fn rungs(t: Transform) []const Rung {
        return switch (t) {
            .raw => &.{ .natural, .tight, .wrap_labels, .switch_direction, .truncate },
            .motif_pack => &.{ .natural, .tight, .truncate },
            .bridge_dodged, .bridge_railed => &.{},
        };
    }
};

pub const EnumerateResult = struct {
    incumbent: LadderResult,
    candidates: []const Candidate,
};
