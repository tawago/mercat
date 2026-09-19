const std = @import("std");
const sketch = @import("sketch.zig");
const validate = @import("layout/validate.zig");
const geom = @import("score_geom.zig");

pub const Direction = sketch.Direction;

pub const RUNG_SCALE = [5]u64{ 16, 30, 32, SWITCH_TO_VERTICAL_SCALE, 50 };

pub const SWITCH_TO_VERTICAL_SCALE: u64 = 36;
pub const SWITCH_TO_HORIZONTAL_SCALE: u64 = 44;

pub fn switchScale(final_direction: Direction) u64 {
    return switch (final_direction) {
        .TD, .BT => SWITCH_TO_VERTICAL_SCALE,
        .LR, .RL => SWITCH_TO_HORIZONTAL_SCALE,
    };
}

pub const W_INTEGRITY: u64 = 20480;

pub const RasterCounts = struct {
    labels_dropped: u32 = 0,
    labels_displaced: u32 = 0,
    edge_cells_lost: u32 = 0,
    foreign_junction: u32 = 0,
    arrowhead_transit: u32 = 0,
    arrow_base: u32 = 0,
    arm_into_head: u32 = 0,
};

pub const W_FOREIGN_JUNCTION: u64 = 8192;
pub const W_ARROWHEAD_TRANSIT: u64 = 8192;
pub const W_ARROW_BASE: u64 = 4096;
pub const W_ARM_INTO_HEAD: u64 = 8192;

pub const W_LABEL_DROP: u64 = 4096;

pub const W_CELL_LOST: u64 = 512;

pub const W_LABEL_DISPLACED: u64 = 592;

pub const NATURAL_PREFERENCE_MARGIN: u64 = 128;

pub fn displacesNatural(challenger: Score, natural: Score) bool {
    if (!challenger.lessThan(natural)) return false;
    if (challenger.t0_fit != natural.t0_fit) return true;
    if (challenger.t12_composite == natural.t12_composite) return true;
    return natural.t12_composite - challenger.t12_composite >= NATURAL_PREFERENCE_MARGIN;
}

const W_DEAD_SPACE: u64 = 1;
const W_EDGE_STRETCH: u64 = 2;
const W_BENDS: u64 = 2;
const W_CROSSINGS: u64 = 1;
const W_LABEL_WRAPS: u64 = 2;

pub const Score = struct {
    t0_fit: u32,
    t1_integrity: u32,
    t2_legibility: u64,
    t3_height: u32,
    t4_index: u32,
    t12_composite: u64,
    r_labels_dropped: u32 = 0,
    r_edge_cells_lost: u32 = 0,

    pub fn lessThan(a: Score, b: Score) bool {
        if (a.t0_fit != b.t0_fit) return a.t0_fit < b.t0_fit;
        if (a.t12_composite != b.t12_composite) return a.t12_composite < b.t12_composite;
        if (a.t3_height != b.t3_height) return a.t3_height < b.t3_height;
        return a.t4_index < b.t4_index;
    }

    pub fn decidingTier(a: Score, b: Score) []const u8 {
        if (a.t0_fit != b.t0_fit) return "t0";
        if (a.t12_composite != b.t12_composite) return "t12";
        if (a.t3_height != b.t3_height) return "t3";
        if (a.t4_index != b.t4_index) return "t4";
        return "tie";
    }
};

pub fn eval(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    source_direction: Direction,
    candidate_index: u32,
    raster: RasterCounts,
) !Score {
    const counts = blk: {
        const vr = try validate.validate(allocator, s);
        break :blk validate.counts(vr, s);
    };
    const t1: u32 = counts.path_through_interior + counts.edge_unrouted;

    const dead = try geom.deadSpace(allocator, s);
    const t2: u64 = W_DEAD_SPACE * dead +
        W_EDGE_STRETCH * geom.edgeStretch(s) +
        W_BENDS * geom.bends(s) +
        W_CROSSINGS * geom.countCrossings(s) +
        W_LABEL_WRAPS * geom.labelWraps(s);

    const rung_idx: usize = @min(s.budget.rung, RUNG_SCALE.len - 1);
    var scale = RUNG_SCALE[rung_idx];
    if (s.direction != source_direction) scale = @max(scale, switchScale(s.direction));

    return .{
        .t0_fit = fitSeverity(s),
        .t1_integrity = t1,
        .t2_legibility = t2,
        .t3_height = s.bbox.h,
        .t4_index = candidate_index,
        .t12_composite = scale * t2 + W_INTEGRITY * @as(u64, t1) +
            W_LABEL_DROP * @as(u64, raster.labels_dropped) +
            W_LABEL_DISPLACED * @as(u64, raster.labels_displaced) +
            W_CELL_LOST * @as(u64, raster.edge_cells_lost) +
            W_FOREIGN_JUNCTION * @as(u64, raster.foreign_junction) +
            W_ARROWHEAD_TRANSIT * @as(u64, raster.arrowhead_transit) +
            W_ARROW_BASE * @as(u64, raster.arrow_base) +
            W_ARM_INTO_HEAD * @as(u64, raster.arm_into_head),
        .r_labels_dropped = raster.labels_dropped,
        .r_edge_cells_lost = raster.edge_cells_lost,
    };
}

pub fn fitSeverity(s: sketch.Sketch) u32 {
    var n: u32 = s.bbox.w -| s.budget.max_width;
    for (s.diagnostics) |d| switch (d) {
        .width_overflow => n += 1,
        else => {},
    };
    return n;
}

test {
    _ = @import("score_test.zig");
}
