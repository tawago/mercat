//! Primitive vocabulary shared across every pipeline stage.
//!
//! The ONE module every mermaid_v2 stage (parse, layout, sketch, raster,
//! lattice, paint) may import freely; sits below all import boundaries,
//! imports only `std`. Carries pure-data types plus shared measurement
//! primitives (`displayWidth`/`truncateToWidth`/`wrapToWidth`) with a
//! self-contained East-Asian-Width table so every stage measures label
//! width identically without crossing the import allowlist. New shared
//! primitives belong here first; re-export via `pub const Foo = prim.Foo;`.

const std = @import("std");

/// Stable handle for a node within a single graph/sketch/lattice.
pub const NodeId = u32;

/// Stable handle for an edge within a single graph/sketch/lattice.
pub const EdgeId = u32;

/// Stable handle for a cluster (subgraph) within a single graph/sketch/lattice.
pub const ClusterId = u32;

/// Overall flowchart layout direction, mirroring Mermaid's TD/BT/LR/RL.
pub const Direction = enum {
    /// Top-to-down.
    TD,
    /// Bottom-to-top.
    BT,
    /// Left-to-right.
    LR,
    /// Right-to-left.
    RL,
};

/// How an edge that crosses a subgraph FRAME border is drawn — a user
/// choice (owner ruling, tawago 2026-07-19: BOTH notations are legal, the
/// user picks in config like theme/editor, and `bridge` is the default).
pub const SubgraphEdges = enum {
    /// Frame-solid: a through-going edge bridges the border gaplessly — the
    /// frame glyph stays continuous and the edge resumes on the far side; a
    /// corner arm onto the frame is refused. The default notation.
    bridge,
    /// The old junction-weld behavior: a through-going edge OR-merges into the
    /// border cell (a fabricated tee/cross), reproducing the pre-Slice-1
    /// rendering byte-for-byte.
    cross,

    /// User-friendly name for the TUI status message / toggle feedback.
    pub fn displayName(self: SubgraphEdges) []const u8 {
        return switch (self) {
            .bridge => "bridge",
            .cross => "cross",
        };
    }

    /// Flip to the other notation (the TUI `b` live toggle).
    pub fn next(self: SubgraphEdges) SubgraphEdges {
        return switch (self) {
            .bridge => .cross,
            .cross => .bridge,
        };
    }
};

/// Cardinal direction of a port on a node perimeter, or the facing of an
/// arrowhead cell in the lattice.
pub const Dir4 = enum {
    north,
    east,
    south,
    west,
};

/// Stroke style of an edge. Represents the visual weight / dash pattern of
/// the drawn line, independent of routing intent.
pub const EdgeKind = enum {
    solid,
    dotted,
    thick,
    invisible,
};

/// Routing-intent role of an edge or edge-segment cell. Carries downstream
/// the "why" of the polyline so raster/paint can resolve junction glyphs
/// without re-deriving topology from cell geometry.
pub const EdgeRole = enum {
    /// Default — straight forward edge between adjacent layers.
    forward,
    /// Edge whose direction was reversed by sugiyama for cycle removal;
    /// rasterizes as a back-edge rail beneath the node row.
    back_edge,
    /// A fan-OUT trunk cell at the source-column rail-row intersection.
    /// Painter forces `┴`/`┬`/`├`/`┤` (no continuing trunk past rail).
    fan_out_trunk,
    /// A fan-OUT rail or descent segment from source to per-child column.
    fan_out_rail,
    /// A fan-IN trunk cell at the target-column rail-row intersection.
    /// Painter keeps `┼` semantics (vertical pass-through preserved).
    fan_in_trunk,
    /// A fan-IN rail or ascent segment from per-source column to target.
    fan_in_rail,
    /// Self-loop edge — uses the lollipop polyline.
    self_loop,
    /// Forward edge whose both endpoints live in the same innermost
    /// cluster; has 1-cell whitespace inset at each port.
    cluster_internal,
};

/// Visual shape of a node as used by the geometry pipeline (sketch →
/// lattice → paint). This is the *rendered* shape set — it has 12 variants
/// rather than the 15 in `parse/sem_graph.NodeShape` because several
/// parse-level aliases collapse here (e.g. `double_circle → circle`,
/// `parallelogram_alt → parallelogram`, `trapezoid_alt → trapezoid`).
///
/// Layout uses this to choose perimeter geometry; paint uses it to choose
/// glyphs.
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

// ---------------------------------------------------------------------------
// Cluster frame chrome — the single source of truth
// ---------------------------------------------------------------------------
//
// A cluster (subgraph) is drawn as a box around its content. The chrome it
// costs on every side is `pad = inset + 1`: one border glyph cell plus an
// interior inset between that border and the content. Border and inset are kept
// DISTINCT on purpose — collapsing them into a single number desyncs super-node
// sizing (`cluster/stitch.superSize`) from the drawn frame and breaks the
// frame-collision avoidance that intra-layer spacing relies on. The pads are
// asymmetric per axis: 3 cols of inset horizontally, 1 row vertically.
//
// PRESSURE-GATED SHRINK (3d): the pads take a `scale` (LayoutOptions.spacing_scale,
// 0 on the `natural` rung, >0 on every escalated rung). At scale 0 the full
// insets are kept, so diagrams that fit at `natural` render byte-identically. At
// scale > 0 the X inset collapses 3→1 (padX 4→2) to claw back columns on nested
// diagrams; the Y inset is already at its 1-cell minimum and never shrinks. The
// floor of padX is 2 (1 border + ≥1 inset) so the frame always keeps a border
// plus one breathing cell, preserving the border-vs-inset distinction.
// All four geometry sites (superSize, both child translates, sibling gaps, sub-budget overhead) MUST pass the SAME scale within one layout pass, or super-node sizing desyncs from the drawn frame. guarded-by: recurse_test.zig "nested cluster: outer super-node pad tracks framePadX(scale) across two recursion levels"
//
// Downstream constants are DERIVED from here, never re-literaled:
//   - `cluster/stitch` frame_pad_x/y = `framePadX(scale)` / `framePadY(scale)`
//   - `cluster/stitch.superSize` = child_bbox + 2*framePad{X,Y}(scale)
//   - `layout/spacing.clusterHPad` = `framePadX(scale)` (same x quantity)
//   - `recurse` child sub-budget = `frameOverheadX(scale)`

/// Interior inset inside the cluster border, x axis (columns).
pub const frame_inset_x: u32 = 3;
/// Interior inset inside the cluster border, y axis (rows).
pub const frame_inset_y: u32 = 1;

/// Horizontal frame pad per side: 1 border cell + the x inset (`inset + 1`).
/// Full at `scale == 0` (inset 3 → padX 4); collapses to a floor of 2 (1 border
/// + 1 inset) under any width pressure (`scale > 0`), in lockstep across every
/// site that consumes it.
pub fn framePadX(scale: u32) u32 {
    return if (scale == 0) frame_inset_x + 1 else 2;
}

/// Vertical frame pad per side: 1 border cell + the y inset (`inset + 1`).
/// The y inset is already the minimum 1, so this is constant regardless of
/// `scale` (never shrink below border+1).
pub fn framePadY(scale: u32) u32 {
    _ = scale;
    return frame_inset_y + 1;
}

/// Total horizontal chrome a single child frame costs in width (both sides).
/// Used by the cluster recursion to shrink a child's width sub-budget by the
/// frame overhead it adds per nesting level. Must use the SAME `scale` as the
/// super-node sizing / drawn frame so the budget accounting matches the chrome.
pub fn frameOverheadX(scale: u32) u32 {
    return 2 * framePadX(scale);
}

/// Rotate a flow direction 90°: TD↔LR and BT↔RL (the dominant axis flips).
/// Pure data — the single definition reused by both the top-level
/// `switch_direction` rung (`budget.rotateForRung`) and the per-child
/// width-pressure direction flip (`recurse.layoutClustered`).
pub fn rotatedDirection(d: Direction) Direction {
    return switch (d) {
        .TD => .LR,
        .LR => .TD,
        .BT => .RL,
        .RL => .BT,
    };
}

// Edge-label placement — shared by layout/clusters.computeBbox (reservation) and raster/labels (painting); they MUST agree on the occupied cell. guarded-by: raster/labels_test.zig "vertical edge label paints at the exact prim anchor for both rail sides"

/// Top-left cell of an edge label given its mid-segment.
pub const LabelAnchor = struct { x: i32, y: i32 };

/// Context for the back-edge return-rail width lever. Pass `.{}` (disabled)
/// for any edge that is not a width-pressured back-edge.
pub const BackRailCtx = struct {
    /// Set only for a back-edge mid-segment under width pressure (rung > 0).
    active: bool = false,
    /// Width budget the diagram must fit (display columns).
    max_width: u32 = 0,
    /// Diagram right extent (exclusive max-x) from everything EXCEPT this
    /// label. The lever fires only when this label's default right placement
    /// busts `max_width` while `others_right` already fits — the necessity
    /// gate that keeps already-fitting seeds byte-identical.
    others_right: i32 = 0,
};

/// Anchor for an edge label whose mid-segment runs `(ax,ay)`→`(bx,by)`.
/// Horizontal segment: one row ABOVE, left-aligned to the midpoint. Vertical
/// segment: 2 cols RIGHT of the rail — UNLESS the back-edge rail lever fires
/// (see `BackRailCtx`), which relocates the wide label into the empty gap LEFT
/// of the rail, dropping the diagram's right extent by `label_w + 2` at zero
/// new width. The lever only fires when the label is the sole overflow driver
/// and the left anchor stays at x >= 0, so other layouts are byte-identical.
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
    if (ay == by) return .{ .x = mid_x, .y = mid_y - 1 }; // horizontal
    const right_x = mid_x + 2; // default: right of the vertical rail
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

/// LEFT-of-rail anchor for a vertical back-edge label: a 1-column gap then the
/// label, then the rail (`mid_x - 1 - label_w`). The single shared definition
/// so reservation (computeBbox) and painting (raster/labels) never disagree.
pub fn leftOfRailAnchor(ax: i32, ay: i32, bx: i32, by: i32, label_w: u32) LabelAnchor {
    const mid_x: i32 = @divTrunc(ax + bx, 2);
    const mid_y: i32 = @divTrunc(ay + by, 2);
    const lw: i32 = @intCast(label_w);
    return .{ .x = mid_x - 1 - lw, .y = mid_y };
}

// Self-contained EAW-aware column counting, duplicated from lib/unicode.zig
// because base/ files may only import std.
// guarded-by: tools/lint_imports.zig "base/ files may import only std and base/ siblings"

/// Display-column width of a single decoded codepoint.
///   - tab (\t)        -> 4
///   - control < 0x20  -> 0
///   - CJK / Hangul / fullwidth / wide ranges -> 2
///   - everything else -> 1
pub fn codepointWidth(codepoint: u21) u32 {
    if (codepoint == '\t') return 4;
    if (codepoint < 0x20) return 0;
    if (codepoint >= 0x1100 and (codepoint <= 0x115f or codepoint == 0x2329 or codepoint == 0x232a or (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or (codepoint >= 0xac00 and codepoint <= 0xd7a3) or (codepoint >= 0xf900 and codepoint <= 0xfaff) or (codepoint >= 0xfe10 and codepoint <= 0xfe19) or (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or (codepoint >= 0xff00 and codepoint <= 0xff60) or (codepoint >= 0xffe0 and codepoint <= 0xffe6))) {
        return 2;
    }
    return 1;
}

/// East-Asian-Width-aware display-column count of `text`.
///
/// Decodes `text` as UTF-8 and sums each codepoint's display width. On
/// malformed UTF-8 it counts 1 column and advances 1 byte (defensive,
/// matching `lib/unicode.zig`). Pure — imports nothing but `std`.
pub fn displayWidth(text: []const u8) u32 {
    var width: u32 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            width += 1;
            index += 1;
            continue;
        };
        if (index + seq_len > text.len) {
            width += 1;
            break;
        }
        const cp = std.unicode.utf8Decode(text[index .. index + seq_len]) catch {
            width += 1;
            index += 1;
            continue;
        };
        width += codepointWidth(cp);
        index += seq_len;
    }
    return width;
}

/// Return the longest prefix sub-slice of `text` whose `displayWidth` is
/// ≤ `max_w`, cut on a UTF-8 codepoint boundary (never splitting a
/// multibyte sequence). Returns a sub-slice of the input — no allocation.
///
/// Malformed UTF-8 is treated the same defensive way as `displayWidth`
/// (width 1, advance 1 byte) so the two measures stay consistent.
pub fn truncateToWidth(text: []const u8, max_w: u32) []const u8 {
    var width: u32 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            if (width + 1 > max_w) break;
            width += 1;
            index += 1;
            continue;
        };
        if (index + seq_len > text.len) {
            // Truncated trailing sequence: treat as width-1 byte.
            if (width + 1 > max_w) break;
            width += 1;
            index += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[index .. index + seq_len]) catch {
            if (width + 1 > max_w) break;
            width += 1;
            index += 1;
            continue;
        };
        const cw = codepointWidth(cp);
        if (width + cw > max_w) break;
        width += cw;
        index += seq_len;
    }
    return text[0..index];
}

/// Soft line-break sentinel byte. Author hard breaks (`<br>`, `\n`) are
/// normalized to this single 0x0A byte at parse time; `wrapToWidth` and the
/// sizing/placement paths split on it. ASCII newline so it never collides
/// with a real label codepoint.
pub const LINE_BREAK: u8 = '\n';

/// Word-wrap `text` to `width` display columns, returning lines as an
/// allocated array of sub-slices (only the outer array is allocated).
///
/// Two layers of breaking: (1) HARD — `text` is first split on the
/// `LINE_BREAK` (0x0A) sentinel, so author `<br>`/`\n` break at every width;
/// (2) SOFT — each hard segment is greedily word-wrapped to `width`, breaking
/// only at ASCII spaces. A word wider than `width` is hard-split on a
/// codepoint boundary (via `truncateToWidth`) so no line ever exceeds
/// `width`. `width == 0` is a degenerate guard: one line = the whole `text`.
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

/// Greedily word-wrap one hard segment (no embedded sentinel) to `width`,
/// appending each line to `lines`. An empty/all-space segment yields one
/// empty line. A line is tracked as `segment[line_start..line_end)`; on
/// overflow we flush and restart at the next word. Words wider than `width`
/// are hard-split via `splitLongWord`.
fn wrapSegment(
    allocator: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged([]const u8),
    segment: []const u8,
    width: u32,
) error{OutOfMemory}!void {
    var line_start: usize = 0;
    var line_end: usize = 0; // exclusive; == line_start means "line empty"
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
            // Line empty: this is the first word.
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

        // Candidate line spans line_start..word_end (the run of source bytes
        // between the current line's first word and this word, inclusive).
        if (displayWidth(segment[line_start..cursor]) <= width) {
            line_end = cursor; // fits — absorb the word and its separator
            continue;
        }

        // Overflow: flush current line, then restart with this word.
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
        // Empty/all-space segment: emit one blank line.
        try lines.append(allocator, segment[0..0]);
    }
}

/// Hard-split a single word wider than `width` into chunks each ≤ width,
/// cut on codepoint boundaries via `truncateToWidth`. Every chunk is
/// appended as its own line (the final remainder ≤ width included).
fn splitLongWord(
    allocator: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged([]const u8),
    word: []const u8,
    width: u32,
) error{OutOfMemory}!void {
    var rest = word;
    while (displayWidth(rest) > width) {
        const chunk = truncateToWidth(rest, width);
        // Zero-progress guard (one codepoint wider than width): emit ≥1 cp.
        const advance = if (chunk.len == 0)
            std.unicode.utf8ByteSequenceLength(rest[0]) catch 1
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
