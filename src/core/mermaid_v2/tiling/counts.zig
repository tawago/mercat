//! Counter record of the report-only structural audit (`tiling/`).
//!
//! PREFIX CONTRACT — every field name begins with exactly one of:
//!
//!   `n_`  population / denominator. Never a claim; the thing the rates
//!         below are measured against.
//!   `m_`  measurement. A number with no defect claim attached.
//!   `c_`  renderer CONVENTION: legal by construction, counted so the
//!         legal population can never contaminate the defect total.
//!   `d_`  genuine defect candidate. `defectTotal()` sums exactly these
//!         and nothing else — it is the one human number on the line.
//!   `u_`  audit-side limitation (fix the audit, not the renderer).
//!
//! A bucket is added, never suppressed: when a legal rendering lands in a
//! `d_` field the answer is a new `c_` bucket, not a filter.
//! guarded-by: counts_test.zig "counts: every field carries an n_/m_/c_/d_/u_ prefix"
//!
//! Flat, all `u32`, reflection-emitted: the struct and the printer cannot
//! drift because `writeLine` enumerates the fields.
//! Imports: `std` only.

const std = @import("std");

/// Field-name prefixes of the contract, in declaration order. Exposed so
/// the completeness test and any future consumer read the same list.
pub const prefixes = [_][]const u8{ "n_", "m_", "c_", "d_", "u_" };

/// Byte budget of one emitted line. Sized for the full taxonomy with
/// room to spare; `writeLine` truncates rather than failing.
pub const line_buf_len: usize = 4096;

/// Leading token of the emitted stderr line — the grep handle.
pub const line_prefix = "mercat-tiling:";

/// Every counter the audit maintains. Fields are grouped by the check
/// family that owns them (see `scan.zig`'s ownership table); a family's
/// fields appear only once the commit that implements it lands.
pub const Counts = struct {
    // -- meta ---------------------------------------------------------
    /// Lattice cells visited (`width * height`). The denominator.
    n_cells: u32 = 0,
    /// Clusters (subgraphs) declared in the SemGraph. Zero on a flat
    /// render; nonzero flags the population where fusion/shadowing
    /// conventions are expected and per-edge identity is lossy.
    n_clustered: u32 = 0,
    /// 1 when this render used the `cross` frame notation, else 0. Steers
    /// bucketing only (a frame arm is a convention under `cross` and a
    /// leak under `bridge`); never a defect by itself.
    n_mode_cross: u32 = 0,
    /// The audit's own scratch allocation failed and a tier was skipped.
    /// An audit limitation: the counts on this line are partial.
    u_audit_oom: u32 = 0,

    // -- arrowhead lateral exclusivity (arrows.zig) -------------------
    /// Arrowhead cells scanned.
    n_arrow_cells: u32 = 0,
    /// A lateral (tip-perpendicular) arm whose neighbour reciprocates, or
    /// resumes across a 1-cell reprieved gap: the ink genuinely turns or
    /// crosses here.
    c_arrow_lat_explained: u32 = 0,
    /// A lateral arm abutting a node/cluster ring — frame-solid: the ring
    /// never reciprocates, and the arrowhead inherited the bit legally.
    c_arrow_lat_frame: u32 = 0,
    /// A lateral arm abutting an opaque cell (label glyph or node fill):
    /// nothing there can reciprocate, so the bit explains itself.
    c_arrow_lat_opaque: u32 = 0,
    /// A lateral arm with nothing to explain it: metadata claiming ink
    /// that does not exist. Arrowhead masks are never reconciled, so
    /// these accumulate rather than being repaired.
    d_arrow_lat_orphan: u32 = 0,

    // -- item-4 bridge: EAW label geometry ----------------------------
    /// Label cells holding an East-Asian-Wide codepoint. Each such cell
    /// paints two columns while occupying one lattice cell.
    m_wide_label_cells: u32 = 0,
    /// Summed per-row excess of painted COLUMNS over lattice CELLS. The
    /// lattice is a cell grid, the terminal a column grid; a nonzero
    /// value means at least one row lies about its own width.
    m_row_col_overflow: u32 = 0,

    /// Sum of exactly the `d_` fields — the single number a reader looks
    /// at first. Reflection-driven, so a new defect bucket is included
    /// the moment it is declared.
    /// guarded-by: counts_test.zig "counts: defectTotal sums exactly the d_ fields"
    pub fn defectTotal(self: Counts) u32 {
        var total: u32 = 0;
        inline for (@typeInfo(Counts).@"struct".fields) |f| {
            if (comptime std.mem.startsWith(u8, f.name, "d_")) total += @field(self, f.name);
        }
        return total;
    }

    /// Render the one-line `mercat-tiling: k=v ...` form into `buf` and
    /// return the written slice. Truncates at the buffer end instead of
    /// failing — a diagnostic line must never break a render.
    /// The trailing `d_total` term is `defectTotal()`, not a field.
    /// guarded-by: counts_test.zig "writeLine: one token per field plus d_total, mercat-tiling prefix"
    pub fn writeLine(self: Counts, buf: []u8) []const u8 {
        var i: usize = 0;
        const head = std.fmt.bufPrint(buf, "{s}", .{line_prefix}) catch return buf[0..0];
        i = head.len;
        inline for (@typeInfo(Counts).@"struct".fields) |f| {
            const term = std.fmt.bufPrint(buf[i..], " {s}={d}", .{ f.name, @field(self, f.name) }) catch break;
            i += term.len;
        }
        const tail = std.fmt.bufPrint(buf[i..], " d_total={d}", .{self.defectTotal()}) catch return buf[0..i];
        return buf[0 .. i + tail.len];
    }

    /// Emit one line to STDERR. Stdout bytes are unaffected: this writes
    /// to stderr only and changes no pipeline decision.
    pub fn emitLine(self: Counts) void {
        var buf: [line_buf_len]u8 = undefined;
        std.debug.print("{s}\n", .{self.writeLine(&buf)});
    }
};
