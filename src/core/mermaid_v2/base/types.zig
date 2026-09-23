const std = @import("std");
const unicode = @import("unicode");

pub const NodeId = u32;

pub const EdgeId = u32;

pub const ClusterId = u32;

pub const Direction = enum {
    TD,
    BT,
    LR,
    RL,
};

pub const SubgraphEdges = enum {
    bridge,
    cross,

    pub fn displayName(self: SubgraphEdges) []const u8 {
        return switch (self) {
            .bridge => "bridge",
            .cross => "cross",
        };
    }

    pub fn next(self: SubgraphEdges) SubgraphEdges {
        return switch (self) {
            .bridge => .cross,
            .cross => .bridge,
        };
    }
};

pub const Dir4 = enum {
    north,
    east,
    south,
    west,
};

pub const ArrowKind = enum {
    none,
    open,
    filled,
    circle,
    cross,
};

pub fn directional(end: ArrowKind) bool {
    return switch (end) {
        .open, .filled => true,
        .none, .circle, .cross => false,
    };
}

pub fn blocks(arrow_from: ArrowKind, arrow_to: ArrowKind) bool {
    return directional(arrow_from) != directional(arrow_to);
}

pub const StandsFor = enum {
    arrow_free,
    forward_one_way,
    backward_one_way,
    directed,
};

pub fn memberBlocks(arrow_from: ArrowKind, arrow_to: ArrowKind, stands_for: StandsFor) bool {
    return switch (stands_for) {
        .arrow_free => blocks(arrow_from, arrow_to),
        .forward_one_way, .backward_one_way => true,
        .directed => false,
    };
}

pub fn memberArrowFree(arrow_from: ArrowKind, arrow_to: ArrowKind, stands_for: StandsFor) bool {
    return !directional(arrow_from) and !directional(arrow_to) and stands_for == .arrow_free;
}

pub const EdgeKind = enum {
    solid,
    dotted,
    thick,
    invisible,
};

pub const BridgeBuild = enum { plain, dodged, railed };

pub const EdgeRole = enum {
    forward,
    back_edge,
    fan_out_rail,
    fan_out_dropper,
    fan_in_rail,
    fan_in_dropper,
    member_stroke,
    self_loop,
    cluster_internal,
};

pub const Shape = enum {
    rect,
    round,
    stadium,
    subroutine,
    cylinder,
    circle,
    asymmetric_left,
    asymmetric_right,
    rhombus,
    hexagon,
    parallelogram,
    trapezoid,
};

// @guarded-by: recurse_test.zig "nested cluster: outer super-node pad tracks framePadX(scale) across two recursion levels"

pub const frame_inset_x: u32 = 3;
pub const frame_inset_y: u32 = 1;

pub fn framePadX(scale: u32) u32 {
    return if (scale == 0) frame_inset_x + 1 else 2;
}

pub fn framePadY(scale: u32) u32 {
    _ = scale;
    return frame_inset_y + 1;
}

pub fn frameOverheadX(scale: u32) u32 {
    return 2 * framePadX(scale);
}

pub fn rotatedDirection(d: Direction) Direction {
    return switch (d) {
        .TD => .LR,
        .LR => .TD,
        .BT => .RL,
        .RL => .BT,
    };
}

// @guarded-by: raster/labels_test.zig "vertical edge label paints at the exact prim anchor for both rail sides"

pub const LabelAnchor = struct { x: i32, y: i32 };

pub const BackRailCtx = struct {
    active: bool = false,
    max_width: u32 = 0,
    others_right: i32 = 0,
};

pub fn edgeLabelAnchor(
    ax: i32,
    ay: i32,
    bx: i32,
    by: i32,
    label_w: u32,
    ctx: BackRailCtx,
) LabelAnchor {
    const mid_x: i32 = @divTrunc(ax + bx, 2);
    const mid_y: i32 = @divTrunc(ay + by, 2);
    if (ay == by) return .{ .x = mid_x, .y = mid_y - 1 };
    const right_x = mid_x + 2;
    if (ctx.active) {
        const lw: i32 = @intCast(label_w);
        const budget: i32 = @intCast(ctx.max_width);
        if (right_x + lw > budget and ctx.others_right <= budget) {
            const left = leftOfRailAnchor(ax, ay, bx, by, label_w);
            if (left.x >= 0) return left;
        }
    }
    return .{ .x = right_x, .y = mid_y };
}

pub fn leftOfRailAnchor(ax: i32, ay: i32, bx: i32, by: i32, label_w: u32) LabelAnchor {
    const mid_x: i32 = @divTrunc(ax + bx, 2);
    const mid_y: i32 = @divTrunc(ay + by, 2);
    const lw: i32 = @intCast(label_w);
    return .{ .x = mid_x - 1 - lw, .y = mid_y };
}

// @guarded-by: tools/lint_imports.zig "base/ files may import only std and base/ siblings; types.zig alone may import unicode"

pub fn codepointWidth(codepoint: u21) u32 {
    return @intCast(unicode.codepointWidth(codepoint));
}

pub fn displayWidth(text: []const u8) u32 {
    return @intCast(unicode.displayWidth(text));
}

pub fn truncateToWidth(text: []const u8, max_w: u32) []const u8 {
    return unicode.clipToWidth(text, max_w);
}

pub const LINE_BREAK: u8 = '\n';

pub fn wrapToWidth(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: u32,
) error{OutOfMemory}![]const []const u8 {
    if (width == 0) {
        const out = try allocator.alloc([]const u8, 1);
        out[0] = text;
        return out;
    }

    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);

    var seg_it = std.mem.splitScalar(u8, text, LINE_BREAK);
    while (seg_it.next()) |segment| {
        try wrapSegment(allocator, &lines, segment, width);
    }
    return try lines.toOwnedSlice(allocator);
}

fn wrapSegment(
    allocator: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged([]const u8),
    segment: []const u8,
    width: u32,
) error{OutOfMemory}!void {
    var line_start: usize = 0;
    var line_end: usize = 0;
    var emitted_any = false;
    var cursor: usize = 0;

    while (cursor < segment.len) {
        if (segment[cursor] == ' ') {
            cursor += 1;
            continue;
        }
        const word_start = cursor;
        while (cursor < segment.len and segment[cursor] != ' ') cursor += 1;
        const word = segment[word_start..cursor];
        const word_w = displayWidth(word);

        if (line_end == line_start) {
            if (word_w > width) {
                try splitLongWord(allocator, lines, word, width);
                emitted_any = true;
                line_start = cursor;
                line_end = cursor;
            } else {
                line_start = word_start;
                line_end = cursor;
            }
            continue;
        }

        if (displayWidth(segment[line_start..cursor]) <= width) {
            line_end = cursor;
            continue;
        }

        try lines.append(allocator, segment[line_start..line_end]);
        emitted_any = true;
        if (word_w > width) {
            try splitLongWord(allocator, lines, word, width);
            line_start = cursor;
            line_end = cursor;
        } else {
            line_start = word_start;
            line_end = cursor;
        }
    }

    if (line_end > line_start) {
        try lines.append(allocator, segment[line_start..line_end]);
    } else if (!emitted_any) {
        try lines.append(allocator, segment[0..0]);
    }
}

fn splitLongWord(
    allocator: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged([]const u8),
    word: []const u8,
    width: u32,
) error{OutOfMemory}!void {
    var rest = word;
    while (displayWidth(rest) > width) {
        const chunk = truncateToWidth(rest, width);
        const advance = if (chunk.len == 0)
            @max(unicode.nextGlyph(rest, 0).bytes.len, 1)
        else
            chunk.len;
        try lines.append(allocator, rest[0..advance]);
        rest = rest[advance..];
    }
    if (rest.len > 0) try lines.append(allocator, rest);
}

test {
    _ = @import("types_test.zig");
}
