//! Minimal, deterministic, dependency-free PNG encoder.
//!
//! The user rejected an external image library ("too weak and not fully
//! prod", 2026-07-13), so PNG encoding is implemented natively here using only
//! the Zig standard library. The encoder emits:
//!
//!   * the 8-byte PNG signature;
//!   * one IHDR chunk (8-bit RGBA truecolor+alpha, non-interlaced);
//!   * exactly one IDAT chunk (fixed chunking policy — the whole zlib stream is
//!     one chunk) carrying a zlib-wrapped DEFLATE bitstream;
//!   * one IEND chunk.
//!
//! Every scanline uses filter type 0 (None) — deterministic and simple; there
//! is deliberately no heuristic filter selection. No tEXt/tIME/pHYs chunks are
//! written, so the output carries zero timestamps or host metadata.
//!
//! The DEFLATE stream is a single fixed-Huffman block (BFINAL=1, BTYPE=01) with
//! greedy LZ77 matching over a 32 KiB window. Because Zig 0.15.1's
//! `std.compress.flate.Compress` is a `@panic("TODO")` stub, we produce the
//! bitstream ourselves. The output is byte-identical for identical input.
//!
//! Correctness is anchored by the round-trip test at the bottom, which inflates
//! our stream through `std.compress.flate.Decompress` and checks the adler32 and
//! every chunk CRC.

const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{
    /// The pixel buffer length does not equal `width * height * 4`.
    PixelBufferSizeMismatch,
    /// A dimension was zero, or the surface arithmetic overflowed `u32`/`usize`.
    InvalidDimensions,
};

/// An encoded PNG plus the metadata the caller needs (§7.6). `bytes` is the
/// complete PNG file, owned by the caller's allocator.
pub const Encoded = struct {
    bytes: []u8,
    width: u32,
    height: u32,
    /// SHA-256 of `bytes` (the full PNG file).
    sha256: [32]u8,

    pub fn deinit(self: Encoded, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

const png_signature = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

/// Native encoder identity, exposed for the artifact-metadata/manifest
/// producer. There is no third-party image library, so this names the in-repo encoder. Bump `encoder_version`
/// whenever the emitted byte stream for a fixed RGBA input would change, so a
/// recorded provenance never claims byte-identity across incompatible encoders.
pub const encoder_name = "mercat-native-png";
pub const encoder_version = "1";

/// Encode an 8-bit RGBA row-major pixel buffer as a PNG. `pixels.len` must be
/// exactly `width * height * 4`.
pub fn encodeRgba(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) Error!Encoded {
    if (width == 0 or height == 0) return error.InvalidDimensions;

    const row_bytes = std.math.mul(usize, width, 4) catch return error.InvalidDimensions;
    const expected = std.math.mul(usize, row_bytes, height) catch return error.InvalidDimensions;
    if (pixels.len != expected) return error.PixelBufferSizeMismatch;

    // 1. Build the filtered image data: one 0x00 filter byte per row, then the
    //    row's RGBA bytes. This is what the zlib stream compresses and what the
    //    adler32 covers.
    const filtered_len = std.math.mul(usize, height, row_bytes + 1) catch return error.InvalidDimensions;
    const filtered = try allocator.alloc(u8, filtered_len);
    defer allocator.free(filtered);
    {
        var src: usize = 0;
        var dst: usize = 0;
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            filtered[dst] = 0; // filter type 0 (None)
            dst += 1;
            @memcpy(filtered[dst .. dst + row_bytes], pixels[src .. src + row_bytes]);
            dst += row_bytes;
            src += row_bytes;
        }
    }

    // 2. zlib stream = 2-byte header + fixed-Huffman DEFLATE + adler32.
    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(allocator);
    // 0x78 0x9C: CM=8/CINFO=7 (32K window), FLEVEL=2, FDICT=0; (0x789C % 31 == 0).
    try zlib.appendSlice(allocator, &.{ 0x78, 0x9C });
    try deflateFixed(allocator, &zlib, filtered);
    const adler = std.hash.Adler32.hash(filtered);
    var adler_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_be, adler, .big);
    try zlib.appendSlice(allocator, &adler_be);

    // 3. Assemble the PNG file.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &png_signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type 6 = truecolor + alpha
    ihdr[10] = 0; // compression method 0 (deflate)
    ihdr[11] = 0; // filter method 0
    ihdr[12] = 0; // interlace method 0 (none)
    try writeChunk(allocator, &out, "IHDR", &ihdr);

    // Fixed chunking policy: exactly one IDAT chunk holds the whole zlib stream.
    try writeChunk(allocator, &out, "IDAT", zlib.items);
    try writeChunk(allocator, &out, "IEND", &.{});

    const bytes = try out.toOwnedSlice(allocator);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .bytes = bytes, .width = width, .height = height, .sha256 = digest };
}

/// Append one PNG chunk: 4-byte big-endian length, 4-byte type, data, then a
/// 4-byte CRC-32 over (type ++ data).
fn writeChunk(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    chunk_type: *const [4]u8,
    data: []const u8,
) std.mem.Allocator.Error!void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len_be);
    try out.appendSlice(allocator, chunk_type);
    try out.appendSlice(allocator, data);

    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    var crc_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_be, crc.final(), .big);
    try out.appendSlice(allocator, &crc_be);
}

// ===========================================================================
// DEFLATE: single fixed-Huffman block with greedy LZ77
// ===========================================================================

const min_match = 3;
const max_match = 258;
const window_size = 32768;
const hash_bits = 15;
const hash_size = 1 << hash_bits;
const hash_mask = hash_size - 1;
/// Bounded hash-chain walk keeps compression time linear and the result
/// deterministic regardless of input.
const max_chain = 128;

/// LSB-first bit accumulator over a growing byte buffer, as DEFLATE requires.
const BitWriter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bit_buffer: u32 = 0,
    bit_count: u5 = 0,

    /// Emit the low `n` bits of `value`, least-significant bit first (used for
    /// the block header and for length/distance extra bits).
    fn writeBits(self: *BitWriter, value: u32, n: u4) std.mem.Allocator.Error!void {
        self.bit_buffer |= (value & ((@as(u32, 1) << n) - 1)) << self.bit_count;
        self.bit_count += n;
        while (self.bit_count >= 8) {
            try self.out.append(self.allocator, @truncate(self.bit_buffer));
            self.bit_buffer >>= 8;
            self.bit_count -= 8;
        }
    }

    /// Emit a Huffman code of `n` bits, most-significant bit first. DEFLATE
    /// packs the bit stream LSB-first but Huffman codes are transmitted with
    /// their MSB first, so the code is bit-reversed before writing.
    fn writeCode(self: *BitWriter, code: u32, n: u4) std.mem.Allocator.Error!void {
        try self.writeBits(reverseBits(code, n), n);
    }

    fn finish(self: *BitWriter) std.mem.Allocator.Error!void {
        if (self.bit_count > 0) {
            try self.out.append(self.allocator, @truncate(self.bit_buffer));
            self.bit_buffer = 0;
            self.bit_count = 0;
        }
    }
};

fn reverseBits(value: u32, n: u4) u32 {
    var v = value;
    var r: u32 = 0;
    var i: u4 = 0;
    while (i < n) : (i += 1) {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    return r;
}

/// Fixed literal/length Huffman code for symbol 0..287 (RFC 1951 §3.2.6).
fn litCode(sym: u16) struct { code: u32, len: u4 } {
    if (sym <= 143) return .{ .code = 0x30 + @as(u32, sym), .len = 8 };
    if (sym <= 255) return .{ .code = 0x190 + @as(u32, sym - 144), .len = 9 };
    if (sym <= 279) return .{ .code = @as(u32, sym - 256), .len = 7 };
    return .{ .code = 0xC0 + @as(u32, sym - 280), .len = 8 };
}

const LenEntry = struct { code: u16, extra_bits: u4, base: u16 };
const DistEntry = struct { code: u16, extra_bits: u4, base: u16 };

// RFC 1951 §3.2.5 length codes 257..285.
const length_table = [_]LenEntry{
    .{ .code = 257, .extra_bits = 0, .base = 3 },
    .{ .code = 258, .extra_bits = 0, .base = 4 },
    .{ .code = 259, .extra_bits = 0, .base = 5 },
    .{ .code = 260, .extra_bits = 0, .base = 6 },
    .{ .code = 261, .extra_bits = 0, .base = 7 },
    .{ .code = 262, .extra_bits = 0, .base = 8 },
    .{ .code = 263, .extra_bits = 0, .base = 9 },
    .{ .code = 264, .extra_bits = 0, .base = 10 },
    .{ .code = 265, .extra_bits = 1, .base = 11 },
    .{ .code = 266, .extra_bits = 1, .base = 13 },
    .{ .code = 267, .extra_bits = 1, .base = 15 },
    .{ .code = 268, .extra_bits = 1, .base = 17 },
    .{ .code = 269, .extra_bits = 2, .base = 19 },
    .{ .code = 270, .extra_bits = 2, .base = 23 },
    .{ .code = 271, .extra_bits = 2, .base = 27 },
    .{ .code = 272, .extra_bits = 2, .base = 31 },
    .{ .code = 273, .extra_bits = 3, .base = 35 },
    .{ .code = 274, .extra_bits = 3, .base = 43 },
    .{ .code = 275, .extra_bits = 3, .base = 51 },
    .{ .code = 276, .extra_bits = 3, .base = 59 },
    .{ .code = 277, .extra_bits = 4, .base = 67 },
    .{ .code = 278, .extra_bits = 4, .base = 83 },
    .{ .code = 279, .extra_bits = 4, .base = 99 },
    .{ .code = 280, .extra_bits = 4, .base = 115 },
    .{ .code = 281, .extra_bits = 5, .base = 131 },
    .{ .code = 282, .extra_bits = 5, .base = 163 },
    .{ .code = 283, .extra_bits = 5, .base = 195 },
    .{ .code = 284, .extra_bits = 5, .base = 227 },
    .{ .code = 285, .extra_bits = 0, .base = 258 },
};

// RFC 1951 §3.2.5 distance codes 0..29.
const dist_table = [_]DistEntry{
    .{ .code = 0, .extra_bits = 0, .base = 1 },
    .{ .code = 1, .extra_bits = 0, .base = 2 },
    .{ .code = 2, .extra_bits = 0, .base = 3 },
    .{ .code = 3, .extra_bits = 0, .base = 4 },
    .{ .code = 4, .extra_bits = 1, .base = 5 },
    .{ .code = 5, .extra_bits = 1, .base = 7 },
    .{ .code = 6, .extra_bits = 2, .base = 9 },
    .{ .code = 7, .extra_bits = 2, .base = 13 },
    .{ .code = 8, .extra_bits = 3, .base = 17 },
    .{ .code = 9, .extra_bits = 3, .base = 25 },
    .{ .code = 10, .extra_bits = 4, .base = 33 },
    .{ .code = 11, .extra_bits = 4, .base = 49 },
    .{ .code = 12, .extra_bits = 5, .base = 65 },
    .{ .code = 13, .extra_bits = 5, .base = 97 },
    .{ .code = 14, .extra_bits = 6, .base = 129 },
    .{ .code = 15, .extra_bits = 6, .base = 193 },
    .{ .code = 16, .extra_bits = 7, .base = 257 },
    .{ .code = 17, .extra_bits = 7, .base = 385 },
    .{ .code = 18, .extra_bits = 8, .base = 513 },
    .{ .code = 19, .extra_bits = 8, .base = 769 },
    .{ .code = 20, .extra_bits = 9, .base = 1025 },
    .{ .code = 21, .extra_bits = 9, .base = 1537 },
    .{ .code = 22, .extra_bits = 10, .base = 2049 },
    .{ .code = 23, .extra_bits = 10, .base = 3073 },
    .{ .code = 24, .extra_bits = 11, .base = 4097 },
    .{ .code = 25, .extra_bits = 11, .base = 6145 },
    .{ .code = 26, .extra_bits = 12, .base = 8193 },
    .{ .code = 27, .extra_bits = 12, .base = 12289 },
    .{ .code = 28, .extra_bits = 13, .base = 16385 },
    .{ .code = 29, .extra_bits = 13, .base = 24577 },
};

fn lengthEntry(length: u16) LenEntry {
    // Highest base that does not exceed `length`.
    var chosen = length_table[0];
    for (length_table) |e| {
        if (e.base <= length) chosen = e else break;
    }
    return chosen;
}

fn distEntry(distance: u16) DistEntry {
    var chosen = dist_table[0];
    for (dist_table) |e| {
        if (e.base <= distance) chosen = e else break;
    }
    return chosen;
}

/// Compress `data` into `out` as one fixed-Huffman DEFLATE block.
fn deflateFixed(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    data: []const u8,
) std.mem.Allocator.Error!void {
    var bw = BitWriter{ .allocator = allocator, .out = out };

    // Block header: BFINAL=1 (1 bit), BTYPE=01 fixed Huffman (2 bits).
    try bw.writeBits(1, 1);
    try bw.writeBits(1, 2);

    if (data.len == 0) {
        try emitLiteralLength(&bw, 256); // end of block
        try bw.finish();
        return;
    }

    const head = try allocator.alloc(i32, hash_size);
    defer allocator.free(head);
    @memset(head, -1);
    const prev = try allocator.alloc(i32, data.len);
    defer allocator.free(prev);

    var pos: usize = 0;
    while (pos < data.len) {
        var best_len: usize = 0;
        var best_dist: usize = 0;

        if (pos + min_match <= data.len) {
            const h = hash3(data, pos);
            var cand = head[h];
            var chain: u32 = 0;
            const max_here = @min(@as(usize, max_match), data.len - pos);
            while (cand >= 0 and chain < max_chain) : (chain += 1) {
                const cpos: usize = @intCast(cand);
                const dist = pos - cpos;
                if (dist > window_size) break;
                const ml = matchLen(data, cpos, pos, max_here);
                if (ml > best_len) {
                    best_len = ml;
                    best_dist = dist;
                    if (ml >= max_here) break;
                }
                cand = prev[cpos];
            }
            // Insert pos into its hash chain (using the pre-search head).
            prev[pos] = head[h];
            head[h] = @intCast(pos);
        }

        if (best_len >= min_match) {
            try emitMatch(&bw, @intCast(best_len), @intCast(best_dist));
            // Insert the interior positions the match covered so later matches
            // can reference them.
            var k: usize = 1;
            while (k < best_len) : (k += 1) {
                const p = pos + k;
                if (p + min_match <= data.len) {
                    const hh = hash3(data, p);
                    prev[p] = head[hh];
                    head[hh] = @intCast(p);
                }
            }
            pos += best_len;
        } else {
            try emitLiteralLength(&bw, data[pos]);
            pos += 1;
        }
    }

    try emitLiteralLength(&bw, 256); // end of block
    try bw.finish();
}

fn hash3(data: []const u8, pos: usize) usize {
    const a = @as(usize, data[pos]);
    const b = @as(usize, data[pos + 1]);
    const c = @as(usize, data[pos + 2]);
    return ((a << 10) ^ (b << 5) ^ c) & hash_mask;
}

fn matchLen(data: []const u8, i: usize, j: usize, max_here: usize) usize {
    var k: usize = 0;
    while (k < max_here and data[i + k] == data[j + k]) : (k += 1) {}
    return k;
}

fn emitLiteralLength(bw: *BitWriter, sym: u16) std.mem.Allocator.Error!void {
    const lc = litCode(sym);
    try bw.writeCode(lc.code, lc.len);
}

fn emitMatch(bw: *BitWriter, length: u16, distance: u16) std.mem.Allocator.Error!void {
    const le = lengthEntry(length);
    try emitLiteralLength(bw, le.code);
    if (le.extra_bits > 0) try bw.writeBits(length - le.base, le.extra_bits);

    const de = distEntry(distance);
    // Fixed-Huffman distance codes are all 5 bits, transmitted MSB-first.
    try bw.writeCode(de.code, 5);
    if (de.extra_bits > 0) try bw.writeBits(distance - de.base, de.extra_bits);
}

// ===========================================================================
// PNG decoding
// ===========================================================================
//
// A self-contained reader that walks chunks, verifies each CRC, inflates the
// IDAT zlib stream, and returns the decoded RGBA plus dimensions. It is public
// so a consumer can hash the exact decoded-RGBA bytes of a PNG
// (decoded-RGBA determinism) without a second PNG implementation, and the
// round-trip tests below reuse it. Unlike the encoder, this path only ever sees
// this encoder's own output, so the format checks are conservative: 8-bit RGBA,
// non-interlaced, filter type 0.

pub const DecodeError = std.mem.Allocator.Error || error{
    /// Missing or wrong 8-byte PNG signature.
    InvalidSignature,
    /// A chunk length/CRC ran past the end of the buffer.
    TruncatedChunk,
    /// A chunk CRC-32 did not match its stored value.
    CrcMismatch,
    /// No IHDR chunk was seen.
    MissingIhdr,
    /// IHDR declared a colour type/bit depth/interlace this decoder (which only
    /// consumes this encoder's own output) does not handle.
    UnsupportedPngFormat,
    /// The IDAT zlib stream failed to inflate (bad stream or adler32).
    InflateFailed,
    /// A scanline used a filter type other than 0 (None).
    UnsupportedFilter,
    /// The inflated size did not equal `height * (width*4 + 1)`.
    FilteredSizeMismatch,
    /// `width * height * 4` overflowed `usize`.
    DimensionOverflow,
};

/// A decoded PNG. `pixels` is 8-bit RGBA row-major (`width*height*4` bytes) and
/// is owned by the caller's allocator. `chunk_types` records every chunk tag in
/// file order for provenance/metadata assertions.
pub const Decoded = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    chunk_types: std.ArrayList([4]u8),

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.chunk_types.deinit(allocator);
    }

    pub fn hasChunk(self: Decoded, name: *const [4]u8) bool {
        for (self.chunk_types.items) |t| {
            if (std.mem.eql(u8, &t, name)) return true;
        }
        return false;
    }

    /// SHA-256 of the decoded RGBA pixel bytes (NOT the PNG file bytes). This is
    /// the decoded-RGBA hash.
    pub fn rgbaSha256(self: Decoded) [32]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.pixels, &digest, .{});
        return digest;
    }
};

/// Decode a PNG produced by `encodeRgba` back to its RGBA pixel bytes. Every
/// failure is a typed `DecodeError`; no partial `Decoded` is returned.
pub fn decodeRgba(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Decoded {
    if (bytes.len < 8 or !std.mem.eql(u8, &png_signature, bytes[0..8])) {
        return error.InvalidSignature;
    }

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var saw_ihdr = false;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    var chunk_types: std.ArrayList([4]u8) = .empty;
    errdefer chunk_types.deinit(allocator);

    while (pos + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const ctype = bytes[pos + 4 ..][0..4];
        const data_start = pos + 8;
        const data_end = std.math.add(usize, data_start, len) catch return error.TruncatedChunk;
        // data + 4-byte CRC must fit.
        if (data_end + 4 > bytes.len) return error.TruncatedChunk;
        const data = bytes[data_start..data_end];

        var crc = std.hash.Crc32.init();
        crc.update(ctype);
        crc.update(data);
        const stored_crc = std.mem.readInt(u32, bytes[data_end..][0..4], .big);
        if (stored_crc != crc.final()) return error.CrcMismatch;

        try chunk_types.append(allocator, ctype.*);

        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (data.len < 13) return error.TruncatedChunk;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (data[8] != 8 or data[9] != 6 or data[12] != 0) return error.UnsupportedPngFormat;
            saw_ihdr = true;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            try idat.appendSlice(allocator, data);
        }

        pos = data_end + 4;
    }

    if (!saw_ihdr) return error.MissingIhdr;

    const row_bytes = std.math.mul(usize, width, 4) catch return error.DimensionOverflow;
    const stride = std.math.add(usize, row_bytes, 1) catch return error.DimensionOverflow;
    const expected_filtered = std.math.mul(usize, stride, height) catch return error.DimensionOverflow;

    // Inflate the zlib stream (this also validates the adler32 footer) directly
    // into an exactly-sized output buffer. A zero-length window buffer puts
    // `Decompress` in direct-streaming mode, where LZ77 back-references resolve
    // against the consumer's output buffer; because that buffer is the full
    // decompressed size, `flate.history_len` lookback is always in range and the
    // decoder never needs to rebase (the fixed-writer path that would otherwise
    // hit `unreachable` for a large image).
    const filtered = try allocator.alloc(u8, expected_filtered);
    defer allocator.free(filtered);
    {
        var in_reader = std.Io.Reader.fixed(idat.items);
        var out = std.Io.Writer.fixed(filtered);
        var dc = std.compress.flate.Decompress.init(&in_reader, .zlib, &.{});
        _ = dc.reader.streamRemaining(&out) catch return error.InflateFailed;
        if (out.end != expected_filtered) return error.FilteredSizeMismatch;
    }

    const pixel_len = std.math.mul(usize, row_bytes, height) catch return error.DimensionOverflow;
    const pixels = try allocator.alloc(u8, pixel_len);
    errdefer allocator.free(pixels);

    // Strip the per-row filter bytes (all filter type 0).
    var src: usize = 0;
    var dst: usize = 0;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        if (filtered[src] != 0) return error.UnsupportedFilter;
        src += 1;
        @memcpy(pixels[dst .. dst + row_bytes], filtered[src .. src + row_bytes]);
        src += row_bytes;
        dst += row_bytes;
    }

    return .{ .width = width, .height = height, .pixels = pixels, .chunk_types = chunk_types };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

// The round-trip tests below decode through the public `decodeRgba` above.
const decodePng = decodeRgba;

fn makeGradient(allocator: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const buf = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = (@as(usize, y) * w + x) * 4;
            buf[i + 0] = @truncate(x *% 7 +% y *% 3);
            buf[i + 1] = @truncate(x *% 13);
            buf[i + 2] = @truncate(y *% 5);
            buf[i + 3] = 255;
        }
    }
    return buf;
}

test "encode/decode RGBA roundtrip preserves pixels and dimensions" {
    const allocator = testing.allocator;
    const w: u32 = 17;
    const h: u32 = 11;
    const pixels = try makeGradient(allocator, w, h);
    defer allocator.free(pixels);

    const enc = try encodeRgba(allocator, pixels, w, h);
    defer enc.deinit(allocator);

    var dec = try decodePng(allocator, enc.bytes);
    defer dec.deinit(allocator);

    try testing.expectEqual(w, dec.width);
    try testing.expectEqual(h, dec.height);
    try testing.expectEqualSlices(u8, pixels, dec.pixels);
}

test "solid runs compress and roundtrip (LZ77 match path)" {
    const allocator = testing.allocator;
    const w: u32 = 64;
    const h: u32 = 40;
    const pixels = try allocator.alloc(u8, @as(usize, w) * h * 4);
    defer allocator.free(pixels);
    // Mostly white with a black rectangle — long identical runs exercise the
    // match finder.
    @memset(pixels, 0xFF);
    var y: u32 = 10;
    while (y < 30) : (y += 1) {
        var x: u32 = 8;
        while (x < 56) : (x += 1) {
            const i = (@as(usize, y) * w + x) * 4;
            pixels[i + 0] = 0;
            pixels[i + 1] = 0;
            pixels[i + 2] = 0;
        }
    }

    const enc = try encodeRgba(allocator, pixels, w, h);
    defer enc.deinit(allocator);
    var dec = try decodePng(allocator, enc.bytes);
    defer dec.deinit(allocator);
    try testing.expectEqualSlices(u8, pixels, dec.pixels);
    // Compression must beat the raw filtered size for such a redundant image.
    try testing.expect(enc.bytes.len < pixels.len);
}

test "output is deterministic across two encodes" {
    const allocator = testing.allocator;
    const pixels = try makeGradient(allocator, 23, 9);
    defer allocator.free(pixels);
    const a = try encodeRgba(allocator, pixels, 23, 9);
    defer a.deinit(allocator);
    const b = try encodeRgba(allocator, pixels, 23, 9);
    defer b.deinit(allocator);
    try testing.expectEqualSlices(u8, a.bytes, b.bytes);
    try testing.expectEqualSlices(u8, &a.sha256, &b.sha256);
}

test "no tIME or tEXt metadata chunks are emitted" {
    const allocator = testing.allocator;
    const pixels = try makeGradient(allocator, 5, 5);
    defer allocator.free(pixels);
    const enc = try encodeRgba(allocator, pixels, 5, 5);
    defer enc.deinit(allocator);
    var dec = try decodePng(allocator, enc.bytes);
    defer dec.deinit(allocator);
    try testing.expect(dec.hasChunk("IHDR"));
    try testing.expect(dec.hasChunk("IDAT"));
    try testing.expect(dec.hasChunk("IEND"));
    try testing.expect(!dec.hasChunk("tIME"));
    try testing.expect(!dec.hasChunk("tEXt"));
    try testing.expect(!dec.hasChunk("pHYs"));
}

test "size mismatch and zero dimensions are rejected" {
    const allocator = testing.allocator;
    var small = [_]u8{0} ** 4;
    try testing.expectError(error.PixelBufferSizeMismatch, encodeRgba(allocator, &small, 2, 2));
    try testing.expectError(error.InvalidDimensions, encodeRgba(allocator, &small, 0, 1));
}

test "single-pixel image roundtrips" {
    const allocator = testing.allocator;
    var one = [_]u8{ 12, 34, 56, 78 };
    const enc = try encodeRgba(allocator, &one, 1, 1);
    defer enc.deinit(allocator);
    var dec = try decodePng(allocator, enc.bytes);
    defer dec.deinit(allocator);
    try testing.expectEqualSlices(u8, &one, dec.pixels);
}
