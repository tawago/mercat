const std = @import("std");
const render_model = @import("../core/markdown/render.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

pub const Decoration = packed struct {
    underline: bool = false,
    strikethrough: bool = false,
};

pub const PositionedRun = struct {
    text: []const u8,
    row: u32,
    start_col: u32,
    columns: u32,
    foreground: Color,
    background: ?Color,
    decoration: Decoration,
    semantic_style: render_model.SpanStyle,
};

pub const Geometry = struct {
    cell_width_px: u16,
    cell_height_px: u16,
    baseline_px: i16,
    padding_left_px: u16,
    padding_right_px: u16,
    padding_top_px: u16,
    padding_bottom_px: u16,

    pub const PixelError = error{PixelOverflow};

    pub fn pixelWidth(self: Geometry, columns: u32) PixelError!u32 {
        return addPad(
            try mul(columns, self.cell_width_px),
            self.padding_left_px,
            self.padding_right_px,
        );
    }

    pub fn pixelHeight(self: Geometry, rows: u32) PixelError!u32 {
        return addPad(
            try mul(rows, self.cell_height_px),
            self.padding_top_px,
            self.padding_bottom_px,
        );
    }

    fn mul(count: u32, cell: u16) PixelError!u32 {
        return std.math.mul(u32, count, cell) catch return error.PixelOverflow;
    }

    fn addPad(body: u32, lead: u16, trail: u16) PixelError!u32 {
        const with_lead = std.math.add(u32, body, lead) catch return error.PixelOverflow;
        return std.math.add(u32, with_lead, trail) catch return error.PixelOverflow;
    }
};

pub const ExportDocument = struct {
    rows: u32,
    columns: u32,
    geometry: Geometry,
    page_background: Color,
    runs: []PositionedRun,
    font_sha256: [32]u8,

    pub fn deinit(self: ExportDocument, allocator: std.mem.Allocator) void {
        for (self.runs) |run| allocator.free(run.text);
        allocator.free(self.runs);
    }

    pub fn pixelWidth(self: ExportDocument) Geometry.PixelError!u32 {
        return self.geometry.pixelWidth(self.columns);
    }

    pub fn pixelHeight(self: ExportDocument) Geometry.PixelError!u32 {
        return self.geometry.pixelHeight(self.rows);
    }
};

const testing = std.testing;

fn sampleDoc(runs: []PositionedRun) ExportDocument {
    return .{
        .rows = 2,
        .columns = 5,
        .geometry = .{
            .cell_width_px = 9,
            .cell_height_px = 20,
            .baseline_px = 36,
            .padding_left_px = 9,
            .padding_right_px = 9,
            .padding_top_px = 20,
            .padding_bottom_px = 20,
        },
        .page_background = .{ .r = 255, .g = 255, .b = 255 },
        .runs = runs,
        .font_sha256 = [_]u8{0xAB} ** 32,
    };
}

test "pixel dimensions follow §7.4" {
    const doc = sampleDoc(&.{});
    try testing.expectEqual(@as(u32, 63), try doc.pixelWidth());
    try testing.expectEqual(@as(u32, 80), try doc.pixelHeight());
}

test "pixel dimensions overflow is reported" {
    const g = Geometry{
        .cell_width_px = 65535,
        .cell_height_px = 1,
        .baseline_px = 0,
        .padding_left_px = 0,
        .padding_right_px = 0,
        .padding_top_px = 0,
        .padding_bottom_px = 0,
    };
    try testing.expectError(error.PixelOverflow, g.pixelWidth(std.math.maxInt(u32)));
}
