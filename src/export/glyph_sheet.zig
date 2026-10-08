const std = @import("std");

const render_model = @import("../core/markdown/render/types.zig");
const theme = @import("../core/theme.zig");
const font = @import("font.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");
const surface_mod = @import("surface.zig");
const png = @import("png.zig");

const Span = render_model.Span;
const Line = render_model.Line;
const SpanStyle = render_model.SpanStyle;

pub const junction_glyphs = [_]u21{
    ' ',   '╵', '╶', '└', '╷', '│', '┌', '├',
    '╴', '┘', '─', '┴', '┐', '┤', '┬', '┼',
};

pub const stroke_glyphs = [_]u21{
    '┊', '╌',
    '║', '═',
    '╚', '╔',
    '╠', '╝',
    '╩', '╗',
    '╣', '╦',
    '╬', '╨',
    '╞', '╥',
    '╡',
};

pub const shape_glyphs = [_]u21{
    '╭', '╮', '╯', '╰',
    '(',   ')',   '╤', '╧',
    '╱', '╲', '>',   '<',
    '◇', '/',   '\\',
};

pub const arrow_glyphs = [_]u21{
    0x25B2,
    0x25B6,
    0x25BC,
    0x25C0,
    0x25C7,
    0x2192,
    0x25B3,
    0x25B7,
    0x25BD,
    0x25C1,
    0x25CB,
    0x2715,
};

pub const heavy_box_glyphs = [_]u21{
    0x250F,
    0x2513,
    0x2517,
    0x251B,
    0x2501,
    0x2503,
};

pub const legacy_stroke_glyphs = [_]u21{
    0x2504,
    0x2506,
    0x2508,
};

pub const legacy_marker_glyphs = [_]u21{
    0x25CF,
    0x25CE,
    0x25B3,
    0x25BA,
    0x25C4,
    0x25C1,
    0x25C6,
};

pub const misc_render_glyphs = [_]u21{
    0x2022,
    0x258E,
    0x2502,
    0x2500,
    0x253C,
    0x00A7,
    0x00BB,
};

pub fn allRendererOwned(buf: *std.ArrayList(u21), allocator: std.mem.Allocator) !void {
    for (junction_glyphs) |g| try buf.append(allocator, g);
    for (stroke_glyphs) |g| try buf.append(allocator, g);
    for (shape_glyphs) |g| try buf.append(allocator, g);
    for (arrow_glyphs) |g| try buf.append(allocator, g);
    for (heavy_box_glyphs) |g| try buf.append(allocator, g);
    for (legacy_stroke_glyphs) |g| try buf.append(allocator, g);
    for (legacy_marker_glyphs) |g| try buf.append(allocator, g);
    for (misc_render_glyphs) |g| try buf.append(allocator, g);
}

fn spanOf(text: []const u8, style: SpanStyle) Span {
    return .{ .text = text, .style = style };
}

const testing = std.testing;

fn sheetOptions() layout.Options {
    return .{
        .palette = theme.neutralDark,
        .color_mode = .monochrome,
    };
}

test "font covers every renderer-owned glyph and every ASCII printable" {
    const face = try font.Font.init(20);

    var cp: u21 = 0x20;
    while (cp <= 0x7E) : (cp += 1) {
        _ = face.requireGlyph(cp) catch |err| {
            std.debug.print("uncovered ASCII U+{X:0>4}\n", .{cp});
            return err;
        };
    }

    var glyphs: std.ArrayList(u21) = .empty;
    defer glyphs.deinit(testing.allocator);
    try allRendererOwned(&glyphs, testing.allocator);
    for (glyphs.items) |g| {
        if (g == ' ') continue;
        _ = face.requireGlyph(g) catch |err| {
            std.debug.print("uncovered renderer glyph U+{X:0>4}\n", .{g});
            return err;
        };
    }
}

fn inked(s: surface_mod.Surface, x: u32, y: u32) bool {
    const i = (@as(usize, y) * s.width + x) * 4;
    return s.pixels[i] < 128;
}

fn verticalJoinContinuous(s: surface_mod.Surface, g: types.Geometry, col: u32, seam_y: u32) bool {
    const x0 = @as(u32, g.padding_left_px) + col * g.cell_width_px;
    var x = x0;
    while (x < x0 + g.cell_width_px) : (x += 1) {
        if (inked(s, x, seam_y - 1) and inked(s, x, seam_y)) return true;
    }
    return false;
}

fn horizontalJoinContinuous(s: surface_mod.Surface, g: types.Geometry, row: u32, seam_x: u32) bool {
    const y0 = @as(u32, g.padding_top_px) + row * g.cell_height_px;
    var y = y0;
    while (y < y0 + g.cell_height_px) : (y += 1) {
        if (inked(s, seam_x - 1, y) and inked(s, seam_x, y)) return true;
    }
    return false;
}

fn renderMini(allocator: std.mem.Allocator, lines: []Line) !struct { surface: surface_mod.Surface, geometry: types.Geometry } {
    const face = try font.Font.init(20);
    var doc = try layout.build(allocator, .{ .lines = lines }, &face, sheetOptions());
    defer doc.deinit(allocator);
    const w = try doc.pixelWidth();
    const h = try doc.pixelHeight();
    var surface = try surface_mod.Surface.init(allocator, w, h);
    errdefer surface.deinit(allocator);
    surface.fill(doc.page_background);
    try png.paintSheet(allocator, &surface, doc, &face, null);
    return .{ .surface = surface, .geometry = doc.geometry };
}

test "a + junction connects to all four adjacent line cells with no gap" {
    var r0 = [_]Span{spanOf(" │ ", .body)};
    var r1 = [_]Span{spanOf("─┼─", .body)};
    var r2 = [_]Span{spanOf(" │ ", .body)};
    var lines = [_]Line{ .{ .spans = &r0 }, .{ .spans = &r1 }, .{ .spans = &r2 } };
    var mini = try renderMini(testing.allocator, &lines);
    defer mini.surface.deinit(testing.allocator);

    const g = mini.geometry;
    const top_seam = @as(u32, g.padding_top_px) + g.cell_height_px;
    const bot_seam = @as(u32, g.padding_top_px) + 2 * g.cell_height_px;
    const left_seam = @as(u32, g.padding_left_px) + g.cell_width_px;
    const right_seam = @as(u32, g.padding_left_px) + 2 * g.cell_width_px;

    try testing.expect(verticalJoinContinuous(mini.surface, g, 1, top_seam));
    try testing.expect(verticalJoinContinuous(mini.surface, g, 1, bot_seam));
    try testing.expect(horizontalJoinContinuous(mini.surface, g, 1, left_seam));
    try testing.expect(horizontalJoinContinuous(mini.surface, g, 1, right_seam));
}
