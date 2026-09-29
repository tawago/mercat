const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");

const Pt = sketch.Point;

pub const Crossing = struct {
    id: sketch.EdgeId,
    from: sg.NodeId,
    to: sg.NodeId,
    kind: sketch.EdgeKind,
    arrow_from: sketch.ArrowKind,
    arrow_to: sketch.ArrowKind,
    label: ?[]const u8,
    origin: sg.EdgeId = sg.SENTINEL,
};

pub const RailEnd = enum { start, end };

pub const Pending = struct {
    cross: Crossing,
    gf: sketch.NodeId,
    gt: sketch.NodeId,
    from_rect: sketch.Rect,
    to_rect: sketch.Rect,
    to_box: sketch.Rect,
    sides: Sides,
    start: Pt,
    end: Pt,
    off_from: u32,
    off_to: u32,
    from_frame: ?sketch.ClusterId,
    to_frame: ?sketch.ClusterId,
    pref: ?i32,
    anchor: Anchor,
    jog: ?i32 = null,
    rail_end: RailEnd = .start,
};

pub const Anchor = struct { frame: bool, id: u32 };

pub const Sides = struct { exit: sketch.Dir4, entry: sketch.Dir4 };
