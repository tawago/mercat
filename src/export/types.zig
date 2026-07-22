//! Backend-neutral positioned export document.
//!
//! This is the shared input for every pixel/vector backend (the native PNG
//! writer today, a future PDF writer tomorrow). It carries fixed-cell geometry
//! and per-run semantic/color/decoration facts — but NO backend-specific pixel
//! buffers or encoder options. Keeping those out of this type is the §6.3
//! "PDF-ready boundary" invariant.
//!
//! `canonicalSha256` produces a stable content hash of the document using an
//! explicit byte encoding (never raw Zig memory): the same logical document
//! hashes identically across builds, targets, and struct-layout changes.

const std = @import("std");
const render_model = @import("../core/render_model.zig");

/// Bumped whenever the canonical-hash byte encoding changes. It is the first
/// value fed into `canonicalSha256`, so a recipe change necessarily changes
/// every document hash.
pub const canonical_hash_version: u16 = 1;

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

/// One positioned run of styled text. A run spans one contiguous stretch of a
/// single rendered `Span` on one row; `text` holds its exact UTF-8 bytes and
/// `columns` is the sum of the display widths of its scalars (never the byte
/// length). Wide (width-2) and combining (width-0) scalars are re-traversed by
/// the painter using the same width policy; the run only records where it
/// starts and how many cells it occupies.
pub const PositionedRun = struct {
    text: []const u8,
    row: u32,
    start_col: u32,
    columns: u32,
    foreground: Color,
    background: ?Color,
    decoration: Decoration,
    semantic_style: render_model.SpanStyle,
    url: ?[]const u8,
};

pub const Geometry = struct {
    cell_width_px: u16,
    cell_height_px: u16,
    /// Baseline distance from the top of the page (top padding already added),
    /// i.e. `padding_top_px + font.baseline_px` per §7.1 step 9.
    baseline_px: i16,
    padding_left_px: u16,
    padding_right_px: u16,
    padding_top_px: u16,
    padding_bottom_px: u16,

    pub const PixelError = error{PixelOverflow};

    /// Total surface width in pixels for a document of `columns` columns
    /// (§7.4). Overflow-checked.
    pub fn pixelWidth(self: Geometry, columns: u32) PixelError!u32 {
        return addPad(
            try mul(columns, self.cell_width_px),
            self.padding_left_px,
            self.padding_right_px,
        );
    }

    /// Total surface height in pixels for a document of `rows` rows (§7.4).
    /// Overflow-checked. Callers pass the already-floored row count (a
    /// zero-row document is laid out as one padded background row).
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

    /// Frees the runs slice and the owned text/url bytes of each run. The
    /// document owns copies of every string so its lifetime is independent of
    /// the `Rendered` value it was built from.
    pub fn deinit(self: ExportDocument, allocator: std.mem.Allocator) void {
        for (self.runs) |run| {
            allocator.free(run.text);
            if (run.url) |url| allocator.free(url);
        }
        allocator.free(self.runs);
    }

    /// Surface width in pixels (§7.4), overflow-checked.
    pub fn pixelWidth(self: ExportDocument) Geometry.PixelError!u32 {
        return self.geometry.pixelWidth(self.columns);
    }

    /// Surface height in pixels (§7.4), overflow-checked.
    pub fn pixelHeight(self: ExportDocument) Geometry.PixelError!u32 {
        return self.geometry.pixelHeight(self.rows);
    }

    /// Canonical content hash (§6.3). Encodes, in order: version, rows,
    /// columns, every geometry field, page background, font hash, the run
    /// count, then each run (row, start col, column count, foreground,
    /// optional background, decoration bits, stable semantic-style tag,
    /// optional URL, text). Unsigned big-endian integers; UTF-8 strings carry a
    /// big-endian u32 byte-length prefix; optionals carry one presence byte.
    /// Pointers, slice addresses, padding, and native endianness never enter
    /// the hash.
    pub fn canonicalSha256(self: ExportDocument) [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        var w = Writer{ .hasher = &h };

        w.putU16(canonical_hash_version);
        w.putU32(self.rows);
        w.putU32(self.columns);
        w.geometry(self.geometry);
        w.color(self.page_background);
        h.update(&self.font_sha256);
        w.putU32(@intCast(self.runs.len));

        for (self.runs) |run| {
            w.putU32(run.row);
            w.putU32(run.start_col);
            w.putU32(run.columns);
            w.color(run.foreground);
            w.optionalColor(run.background);
            w.putU8(decorationBits(run.decoration));
            w.putU16(semanticStyleTag(run.semantic_style));
            w.optionalString(run.url);
            w.string(run.text);
        }

        var digest: [32]u8 = undefined;
        h.final(&digest);
        return digest;
    }
};

/// Two-bit decoration encoding: bit 0 = underline, bit 1 = strikethrough.
fn decorationBits(d: Decoration) u8 {
    var bits: u8 = 0;
    if (d.underline) bits |= 0b01;
    if (d.strikethrough) bits |= 0b10;
    return bits;
}

/// Stable numeric tag for a semantic span style. These values are frozen: they
/// are part of the canonical-hash encoding and MUST NOT be reordered or reused.
/// Adding a style appends a new number and bumps `canonical_hash_version`.
pub fn semanticStyleTag(style: render_model.SpanStyle) u16 {
    return switch (style) {
        .heading1 => 1,
        .heading2 => 2,
        .heading3 => 3,
        .heading4 => 4,
        .heading5 => 5,
        .heading6 => 6,
        .body => 7,
        .muted => 8,
        .emphasis => 9,
        .strong => 10,
        .strong_emphasis => 11,
        .code => 12,
        .code_block => 13,
        .code_block_keyword => 14,
        .code_block_string => 15,
        .code_block_number => 16,
        .code_block_comment => 17,
        .code_keyword => 18,
        .code_string => 19,
        .code_number => 20,
        .code_comment => 21,
        .quote => 22,
        .link => 23,
        .strikethrough => 24,
        .image_alt => 25,
        .superscript => 26,
        .subscript => 27,
        .highlight => 28,
    };
}

/// Big-endian primitive encoder that feeds a running SHA-256. Only logical
/// values reach the hasher; no struct memory is ever hashed directly.
const Writer = struct {
    hasher: *std.crypto.hash.sha2.Sha256,

    fn putU8(self: *Writer, value: u8) void {
        self.hasher.update(&[_]u8{value});
    }

    fn putU16(self: *Writer, value: u16) void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .big);
        self.hasher.update(&buf);
    }

    fn putU32(self: *Writer, value: u32) void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .big);
        self.hasher.update(&buf);
    }

    /// Signed 16-bit as its two's-complement bit pattern, big-endian.
    fn putI16(self: *Writer, value: i16) void {
        self.putU16(@bitCast(value));
    }

    fn color(self: *Writer, value: Color) void {
        self.hasher.update(&[_]u8{ value.r, value.g, value.b, value.a });
    }

    fn optionalColor(self: *Writer, value: ?Color) void {
        if (value) |c| {
            self.putU8(1);
            self.color(c);
        } else {
            self.putU8(0);
        }
    }

    fn string(self: *Writer, bytes: []const u8) void {
        self.putU32(@intCast(bytes.len));
        self.hasher.update(bytes);
    }

    fn optionalString(self: *Writer, bytes: ?[]const u8) void {
        if (bytes) |b| {
            self.putU8(1);
            self.string(b);
        } else {
            self.putU8(0);
        }
    }

    fn geometry(self: *Writer, g: Geometry) void {
        self.putU16(g.cell_width_px);
        self.putU16(g.cell_height_px);
        self.putI16(g.baseline_px);
        self.putU16(g.padding_left_px);
        self.putU16(g.padding_right_px);
        self.putU16(g.padding_top_px);
        self.putU16(g.padding_bottom_px);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

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
    // width = 9 + 5*9 + 9 = 63; height = 20 + 2*20 + 20 = 80.
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

test "canonical hash is deterministic and depends on content" {
    var run_a = [_]PositionedRun{.{
        .text = "hello",
        .row = 0,
        .start_col = 0,
        .columns = 5,
        .foreground = .{ .r = 0, .g = 0, .b = 0 },
        .background = null,
        .decoration = .{},
        .semantic_style = .body,
        .url = null,
    }};
    const doc_a = sampleDoc(&run_a);
    const h1 = doc_a.canonicalSha256();
    const h2 = doc_a.canonicalSha256();
    try testing.expectEqualSlices(u8, &h1, &h2);

    // A single differing text byte changes the hash.
    var run_b = [_]PositionedRun{run_a[0]};
    run_b[0].text = "hellp";
    const doc_b = sampleDoc(&run_b);
    try testing.expect(!std.mem.eql(u8, &h1, &doc_b.canonicalSha256()));

    // A differing decoration changes the hash.
    var run_c = [_]PositionedRun{run_a[0]};
    run_c[0].decoration = .{ .underline = true };
    try testing.expect(!std.mem.eql(u8, &h1, &sampleDoc(&run_c).canonicalSha256()));
}

test "semantic style tags are unique" {
    const styles = std.enums.values(render_model.SpanStyle);
    var seen = std.AutoHashMap(u16, void).init(testing.allocator);
    defer seen.deinit();
    for (styles) |s| {
        const tag = semanticStyleTag(s);
        try testing.expect(!seen.contains(tag));
        try seen.put(tag, {});
    }
}
