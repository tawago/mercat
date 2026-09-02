//! Emission half of the audit's counter record, split out of `counts.zig` at
//! the 500-line cap so the taxonomy itself keeps room to grow.
//!
//! Nothing here knows the taxonomy: every function takes the counter struct as
//! a comptime type and walks its fields by reflection, which is also why this
//! file imports `counts.zig` not at all — the dependency runs one way, and the
//! struct and its printer cannot drift because the printer never names a
//! field.
//!
//! Imports: `std` only.

const std = @import("std");

/// Field-name prefixes of the contract, in declaration order. Exposed so
/// the completeness test and any future consumer read the same list.
pub const prefixes = [_][]const u8{ "n_", "m_", "c_", "d_", "u_" };

/// Byte budget of one emitted line. Sized so that even the absolute worst
/// case — every counter printed at a u32's full ten digits — leaves the
/// buffer half empty, so the taxonomy can keep growing; `writeLine`
/// truncates rather than failing either way.
/// @guarded-by: counts_test.zig "writeLine: the whole taxonomy fits the line buffer with room to grow"
pub const line_buf_len: usize = 8192;

/// Leading token of the emitted stderr line — the grep handle.
pub const line_prefix = "mercat-tiling:";

/// Sum of exactly the `d_` fields of `T`.
pub fn defectTotal(comptime T: type, self: T) u32 {
    var total: u32 = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime std.mem.startsWith(u8, f.name, "d_")) total += @field(self, f.name);
    }
    return total;
}

/// Render the one-line `mercat-tiling: k=v ...` form into `buf` and return the
/// written slice. Truncates at the buffer end instead of failing — a
/// diagnostic line must never break a render.
pub fn writeLine(comptime T: type, self: T, buf: []u8) []const u8 {
    var i: usize = 0;
    const head = std.fmt.bufPrint(buf, "{s}", .{line_prefix}) catch return buf[0..0];
    i = head.len;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const term = std.fmt.bufPrint(buf[i..], " {s}={d}", .{ f.name, @field(self, f.name) }) catch break;
        i += term.len;
    }
    const tail = std.fmt.bufPrint(buf[i..], " d_total={d}", .{defectTotal(T, self)}) catch return buf[0..i];
    return buf[0 .. i + tail.len];
}

/// Emit one line to STDERR. Stdout bytes are unaffected: this writes to
/// stderr only and changes no pipeline decision.
pub fn emitLine(comptime T: type, self: T) void {
    var buf: [line_buf_len]u8 = undefined;
    std.debug.print("{s}\n", .{writeLine(T, self, &buf)});
}
