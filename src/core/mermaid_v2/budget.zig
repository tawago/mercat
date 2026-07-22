//! Width-budget ladder driver.
//!
//! Iterates a small fixed sequence of layout attempts ("rungs"), widening
//! layout freedom only as needed to fit `max_width`. The lowest rung whose
//! Sketch has no `width_overflow` wins; the terminal `truncate` rung always
//! returns, even if still overflowing. Delegates each per-rung layout
//! attempt to `recurse.zig` (cluster cut-layout-stitch recursion).
//!
//! Allowed imports (enforced by `tools/lint_imports.zig`): `std`,
//! `sketch.zig`, `sem_graph.zig`, `layout.zig`, `parse.zig`, `cluster/*`,
//! `recurse.zig`. Must not reach into raster/, lattice/, or paint/.

const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");
const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const coords = @import("layout.zig");
const recurse = @import("recurse.zig");

/// Ordered budget-relaxation strategies, from least to most aggressive.
///
/// The driver tries them in numerical order; the first to produce a
/// Sketch with no `width_overflow` diagnostic wins. `truncate` is the
/// terminal rung — its result is returned even if overflow persists.
pub const Rung = enum(u8) {
    natural = 0,
    tight = 1,
    wrap_labels = 2,
    /// Lever C: serpentine chain-wrap. Folds a long LR/RL chain into a
    /// multi-band snake that PRESERVES the declared direction. Sits BELOW
    /// `switch_direction` deliberately: try the direction-preserving fold
    /// before paying for the 90° rotation.
    chain_wrap = 3,
    switch_direction = 4,
    truncate = 5,
};

/// Result of running the ladder. `sketch` is the chosen Sketch, allocated
/// from the caller-supplied arena allocator. `final_rung` is the rung that
/// produced it; `attempts` is how many layout calls were issued (1..=6).
pub const LadderResult = struct {
    sketch: sketch.Sketch,
    final_rung: Rung,
    attempts: u8,
    /// P2v Step 8 (D-DISPOSITION item 9(b)/9(e)): true only for the forced
    /// all-independent TERMINAL candidate. Lets a caller observe engagement
    /// without a debug log (the RO `disp_terminal_fallback_engaged` count
    /// aggregation itself is Step 10's telemetry job — this is just the flag).
    terminal_fallback: bool = false,
};

/// Run the WidthBudget ladder against `graph`. Returns the first Sketch that
/// fits within `max_width`, falling through to `.truncate` as a terminal
/// "always returns" rung. Propagates structural `coords.layout` errors.
pub fn run(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
) !LadderResult {
    var attempts: u8 = 0;
    var rung_idx: u8 = 0;
    while (rung_idx <= @intFromEnum(Rung.truncate)) : (rung_idx += 1) {
        const rung: Rung = @enumFromInt(rung_idx);
        const attempt = try tryRung(arena, graph, join_permits, join_permits_flat, max_width, rung);
        attempts += 1;

        if (attempt.accepted) {
            return LadderResult{
                .sketch = attempt.sketch,
                .final_rung = rung,
                .attempts = attempts,
            };
        }
    }
    // Unreachable: the loop always returns at rung == .truncate.
    unreachable;
}

/// Lay out ONE rung: options + (switch_direction-only) rotation + the
/// cluster recursion; acceptance is NOT consulted here. The single layout
/// call shared by every driver in this file. `negotiated` adds the
/// measured-gutter fold flag (chain_wrap rung only). `join_permits` is a
/// pointer to the RENDER-lifetime plan (entry.zig's local), threaded
/// through every driver so `LayoutOptions.join_permits` aliases that plan
/// and never a stack copy.
fn layoutRung(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
    rung: Rung,
    negotiated: bool,
) !sketch.Sketch {
    var opts = optionsFor(rung, max_width);
    opts.join_permits = join_permits;
    opts.join_permits_flat = join_permits_flat;
    if (negotiated) opts.chain_wrap_negotiated = true;
    return recurse.layoutPieces(arena, rotateForRung(graph, rung), opts);
}

/// One rung's Sketch plus the ladder's acceptance verdict for it. Shared
/// by `run` and `enumerate`'s pre-incumbent phase — the exact layout-then-
/// accept call order is load-bearing (acceptance may run a rotation probe).
const RungAttempt = struct { sketch: sketch.Sketch, accepted: bool };

fn tryRung(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
    rung: Rung,
) !RungAttempt {
    const result = try layoutRung(arena, graph, join_permits, join_permits_flat, max_width, rung, false);
    return .{
        .sketch = result,
        .accepted = try ladderAccepts(arena, graph, join_permits, join_permits_flat, max_width, rung, result),
    };
}

/// The ladder's acceptance rule for one rung's laid-out Sketch. The terminal
/// `truncate` rung always wins; any earlier rung wins only with no
/// `width_overflow`, plus two rung-specific constraints:
///
/// `switch_direction`: a 90° rotation discards the author's flow direction, so
/// accept it only if it FITS — a rotated-but-overflowing Sketch loses to
/// `truncate` (which keeps the declared orientation). See budget_test.zig
/// "switch_direction is rejected when rotation also overflows; declared dir kept".
///
/// `chain_wrap`: the direction-preserving fold wins only when rotation cannot
/// save the chain — accept iff it fits AND a `switch_direction` probe still
/// overflows (one extra bounded pass, only when the fold fit). See
/// budget_test.zig "chain_wrap acceptance guard defers to rotation when rotation fits".
///
/// Plain rungs: once a rung fits in the authored direction, accept it — the
/// direction-preserving levers all run before `switch_direction`, so a fitting
/// non-rotated rung has already had its chance to compact.
fn ladderAccepts(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
    rung: Rung,
    result: sketch.Sketch,
) !bool {
    if (rung == .switch_direction) {
        // Rotated but still overflows: do NOT switch.
        return !hasWidthOverflow(result.diagnostics);
    }
    if (rung == .chain_wrap) {
        // Fold didn't fit, OR rotation would fit: defer.
        return !hasWidthOverflow(result.diagnostics) and
            try rotationStillOverflows(arena, graph, join_permits, join_permits_flat, max_width);
    }
    return rung == .truncate or !hasWidthOverflow(result.diagnostics);
}

/// One laid-out rung candidate, retained for score-shadow diagnostics.
/// `accepted` records whether the ladder's acceptance rule passed this rung
/// while the incumbent was still undecided (rungs after the incumbent are
/// laid out for scoring only and are never `accepted`).
pub const Candidate = struct {
    rung: Rung,
    sketch: sketch.Sketch,
    accepted: bool,
    /// Which transform produced this candidate (see `Transform`). budget.zig
    /// itself only ever emits `.raw`; the transformed candidates come from
    /// select.zig — the field lives here so the merged list stays one type.
    transform: Transform = .raw,
};

/// See `Candidate.transform`. Each transform owns its own eligibility:
/// which source directions it applies to and which rungs its candidates
/// are laid out at (select.zig consumes both).
pub const Transform = enum {
    raw,
    motif_pack,
    negotiated_fold,

    /// True when this transform can produce candidates for a graph flowing
    /// in `d`. Packing is a direction-preserving TD/BT move (rank_grid tiles
    /// vertical-flow rows); the negotiated fold lives on chain_wrap's LR/RL
    /// domain (foldChain is a no-op for vertical flows).
    pub fn appliesTo(t: Transform, d: sem_graph.Direction) bool {
        return switch (t) {
            .raw => true,
            .motif_pack => d == .TD or d == .BT,
            .negotiated_fold => d == .LR or d == .RL,
        };
    }

    /// The rung set this transform's candidates are laid out at. `.raw` is
    /// the full ladder (see `enumerate`). `.motif_pack` uses a capped set:
    /// rank_grid tiling of the rigid branch super-nodes fires under
    /// flush-left (rung >= tight); natural is kept as cheap insurance;
    /// rotating rungs are excluded — packing is direction-preserving.
    /// `.negotiated_fold` is one measured-gutter chain_wrap candidate.
    pub fn rungs(t: Transform) []const Rung {
        return switch (t) {
            .raw => &.{ .natural, .tight, .wrap_labels, .chain_wrap, .switch_direction, .truncate },
            .motif_pack => &.{ .natural, .tight, .truncate },
            .negotiated_fold => &.{.chain_wrap},
        };
    }
};

/// `run` plus retained candidates. `incumbent` is byte-for-byte the same
/// choice `run` makes; `candidates` holds every rung that laid out
/// successfully (all six in the common case), in rung order.
pub const EnumerateResult = struct {
    incumbent: LadderResult,
    candidates: []const Candidate,
};

/// Shadow-mode sibling of `run`: identical incumbent selection (same
/// layout calls, same acceptance predicate, same error propagation up to
/// the incumbent), but KEEPS every rung's Sketch and continues laying out
/// the remaining rungs after the incumbent is found so the score can
/// evaluate the full candidate set. Post-incumbent layout failures are
/// skipped (they must not affect the returned result — `run` would never
/// have executed them). All Sketches stay alive in `arena` (never reset
/// during a render), so retaining them is free.
///
/// ~2× the layout work of `run`; only entry.zig's env-gated shadow path
/// calls this. Normal renders keep using `run`.
pub fn enumerate(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
) !EnumerateResult {
    var candidates: std.ArrayList(Candidate) = .empty;
    var incumbent: ?LadderResult = null;
    var attempts: u8 = 0;
    var rung_idx: u8 = 0;
    while (rung_idx <= @intFromEnum(Rung.truncate)) : (rung_idx += 1) {
        const rung: Rung = @enumFromInt(rung_idx);
        if (incumbent == null) {
            const attempt = try tryRung(arena, graph, join_permits, join_permits_flat, max_width, rung);
            attempts += 1;
            try candidates.append(arena, .{ .rung = rung, .sketch = attempt.sketch, .accepted = attempt.accepted });
            if (attempt.accepted) {
                incumbent = .{ .sketch = attempt.sketch, .final_rung = rung, .attempts = attempts };
            }
        } else {
            // Post-incumbent: scoring-only extra work; failures skipped. // guarded-by: budget_test.zig "enumerate never probes acceptance for post-incumbent candidates"
            const result = layoutRung(arena, graph, join_permits, join_permits_flat, max_width, rung, false) catch continue;
            try candidates.append(arena, .{ .rung = rung, .sketch = result, .accepted = false });
        }
    }
    return .{
        // guarded-by: budget_test.zig "enumerate/run always resolve an incumbent across degenerate graphs and widths"
        .incumbent = incumbent.?,
        .candidates = try candidates.toOwnedSlice(arena),
    };
}

/// Lay out and return EXACTLY the given rung's candidate, bypassing the
/// acceptance ladder entirely (the result may overflow; the caller asked
/// for it). Driven by the `MERCAT_FORCE_RUNG` env knob in entry.zig so
/// external diagnostics tooling can render the argmin side of a
/// score-shadow disagreement for inspection. Never used by normal renders.
pub fn runForced(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
    rung: Rung,
) !LadderResult {
    const result = try layoutRung(arena, graph, join_permits, join_permits_flat, max_width, rung, false);
    return .{ .sketch = result, .final_rung = rung, .attempts = 1 };
}

/// P2v Step 8 (D-DISPOSITION item 9(b)): lay out the raw `.natural` rung with
/// trunk realization DISABLED (`LayoutOptions.disable_join_realization`), so
/// `join_commit` emits an all-independent plan and no fan busbar is realized —
/// the trunk-free CI-filter terminal geometry. Caller marks `terminal_fallback`.
pub fn runForcedIndependent(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
) !LadderResult {
    var opts = optionsFor(.natural, max_width);
    opts.join_permits = join_permits;
    opts.join_permits_flat = join_permits_flat;
    opts.disable_join_realization = true;
    return .{ .sketch = try recurse.layoutPieces(arena, graph, opts), .final_rung = .natural, .attempts = 1 };
}

/// Lay out the NEGOTIATED chain-wrap fold (`chain_wrap` + `chain_wrap_negotiated`)
/// so foldChain chooses band breaks against MEASURED per-band back-edge gutter
/// demand instead of the blind FLOW_RAIL_MARGIN. Bypasses acceptance like
/// `runForced`; select.zig tags the candidate `.negotiated_fold`.
pub fn runNegotiatedFold(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
) !LadderResult {
    const result = try layoutRung(arena, graph, join_permits, join_permits_flat, max_width, .chain_wrap, true);
    return .{ .sketch = result, .final_rung = .chain_wrap, .attempts = 1 };
}

/// Probe the `switch_direction` rung: lay `graph` out rotated and report
/// whether it STILL overflows `max_width`. Used by the chain-wrap acceptance
/// guard to keep the fold from churning chains that rotation already fit. One
/// bounded, deterministic layout pass.
fn rotationStillOverflows(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
) !bool {
    const opts = optionsFor(.switch_direction, max_width);
    var planned_opts = opts;
    planned_opts.join_permits = join_permits;
    planned_opts.join_permits_flat = join_permits_flat;
    const rotated = try recurse.layoutPieces(arena, rotateForRung(graph, .switch_direction), planned_opts);
    return hasWidthOverflow(rotated.diagnostics);
}

/// Build the `LayoutOptions` for a given rung (defaults from
/// `coords.LayoutOptions{}`; tighter rungs cut spacing). `wrap_labels` adds
/// `max_label_width` so `sizeNodes` soft-wraps over-wide labels (author
/// `<br>`/`\n` hard breaks honored at every rung regardless). `switch_direction`
/// has no override field, so `rotateForRung` rotates a local SemGraph copy
/// (borrowed slices), leaving the caller's graph unmutated.
fn optionsFor(rung: Rung, max_width: u32) coords.LayoutOptions {
    const defaults: coords.LayoutOptions = .{};
    // Every rung ABOVE `natural` packs rows flush-left (recovering orphan
    // whitespace) and halves the pure inter-cluster gaps (frame insets stay
    // full-size). The `natural` rung keeps centering + full gaps so fitting
    // seeds stay byte-identical.
    return switch (rung) {
        .natural => .{
            .max_width = max_width,
            .h_spacing = defaults.h_spacing,
            .v_spacing = defaults.v_spacing,
            .node_padding = defaults.node_padding,
            .rung = @intFromEnum(rung),
            .justify = .center,
            .spacing_scale = 0,
        },
        .tight => .{
            .max_width = max_width,
            .h_spacing = halveAtLeastOne(defaults.h_spacing),
            .v_spacing = halveAtLeastOne(defaults.v_spacing),
            .node_padding = defaults.node_padding,
            .rung = @intFromEnum(rung),
            .justify = .flush_left,
            .spacing_scale = 1,
        },
        .wrap_labels => .{
            // Tight spacing + a soft word-wrap cap. The cap is the budget
            // minus the per-box chrome a wrapped label still needs: 2 border
            // columns + 2*node_padding interior pad. Saturating so a tiny
            // budget can't underflow (then sizeNodes clamps to shape minima).
            .max_width = max_width,
            .h_spacing = halveAtLeastOne(defaults.h_spacing),
            .v_spacing = halveAtLeastOne(defaults.v_spacing),
            .node_padding = defaults.node_padding,
            .rung = @intFromEnum(rung),
            .max_label_width = max_width -| (2 + 2 * defaults.node_padding),
            .justify = .flush_left,
            .spacing_scale = 1,
        },
        .chain_wrap => .{
            // Lever C: same tight + flush-left + soft-wrap posture as
            // `wrap_labels`, PLUS the `chain_wrap` flag that turns on the
            // serpentine fold in layout.buildSketch. The fold only fires for
            // LR/RL chains whose flow axis busts the budget; it is a no-op
            // otherwise, so this rung degenerates to `wrap_labels` for every
            // graph the fold doesn't apply to (and the ladder then falls
            // through to `switch_direction` exactly as before).
            .max_width = max_width,
            .h_spacing = halveAtLeastOne(defaults.h_spacing),
            .v_spacing = halveAtLeastOne(defaults.v_spacing),
            .node_padding = defaults.node_padding,
            .rung = @intFromEnum(rung),
            .max_label_width = max_width -| (2 + 2 * defaults.node_padding),
            .justify = .flush_left,
            .spacing_scale = 1,
            .chain_wrap = true,
        },
        .switch_direction => .{
            // Rotated direction is applied via `rotateForRung` on the
            // graph itself; LayoutOptions stays at tight spacing. The
            // `is_direction_rotated` flag tells layout to suppress drift
            // compaction for the re-laid LR-as-TD chain.
            .max_width = max_width,
            .h_spacing = halveAtLeastOne(defaults.h_spacing),
            .v_spacing = halveAtLeastOne(defaults.v_spacing),
            .node_padding = defaults.node_padding,
            .rung = @intFromEnum(rung),
            .is_direction_rotated = true,
            .justify = .flush_left,
            .spacing_scale = 1,
        },
        .truncate => .{
            // Tightest options we can express. Layout still produces a
            // Sketch (possibly with width_overflow); caller treats this
            // as success regardless.
            .max_width = max_width,
            .h_spacing = halveAtLeastOne(defaults.h_spacing),
            .v_spacing = halveAtLeastOne(defaults.v_spacing),
            .node_padding = if (defaults.node_padding == 0) 0 else defaults.node_padding - 1,
            .rung = @intFromEnum(rung),
            .justify = .flush_left,
            .spacing_scale = 1,
        },
    };
}

fn halveAtLeastOne(v: u32) u32 {
    const h = v / 2;
    return if (h < 1) 1 else h;
}

/// Return a copy of `graph` with its `direction` rotated for the given
/// rung. Only `switch_direction` rotates; all other rungs return the
/// graph unchanged. The rotation swaps TD<->LR and BT<->RL so the
/// dominant axis flips.
fn rotateForRung(graph: sem_graph.SemGraph, rung: Rung) sem_graph.SemGraph {
    if (rung != .switch_direction) return graph;
    var copy = graph;
    copy.direction = prim.rotatedDirection(graph.direction);
    return copy;
}

pub fn hasWidthOverflow(diagnostics: []const sketch.Diagnostic) bool {
    for (diagnostics) |d| {
        switch (d) {
            .width_overflow => return true,
            else => {},
        }
    }
    return false;
}

// ====================================================================
// Tests
// ====================================================================
// Graph-level ladder tests (run/enumerate/runForced over parsed graphs)
// live in budget_test.zig to keep this file under the 500-line cap; the
// tests below cover the pure private helpers only.

test {
    _ = @import("budget_test.zig");
}

test "chain_wrap rung sets the serpentine flag; sibling rungs do not" {
    // Direct coverage of the new rung's options wiring. The fold flag must be
    // set ONLY on chain_wrap so the serpentine pass is inert on every other
    // rung (lower rungs / fitting seeds stay byte-identical).
    try std.testing.expect(optionsFor(.chain_wrap, 60).chain_wrap);
    try std.testing.expect(!optionsFor(.natural, 60).chain_wrap);
    try std.testing.expect(!optionsFor(.tight, 60).chain_wrap);
    try std.testing.expect(!optionsFor(.wrap_labels, 60).chain_wrap);
    try std.testing.expect(!optionsFor(.switch_direction, 60).chain_wrap);
    try std.testing.expect(!optionsFor(.truncate, 60).chain_wrap);
    // chain_wrap sits between wrap_labels and switch_direction in the ladder.
    try std.testing.expect(@intFromEnum(Rung.wrap_labels) < @intFromEnum(Rung.chain_wrap));
    try std.testing.expect(@intFromEnum(Rung.chain_wrap) < @intFromEnum(Rung.switch_direction));
}

test "halveAtLeastOne clamps to 1" {
    try std.testing.expectEqual(@as(u32, 2), halveAtLeastOne(4));
    try std.testing.expectEqual(@as(u32, 1), halveAtLeastOne(1));
    try std.testing.expectEqual(@as(u32, 1), halveAtLeastOne(0));
}

test "rotateForRung only fires on switch_direction" {
    const g: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &.{},
        .edges = &.{},
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    try std.testing.expectEqual(sem_graph.Direction.TD, rotateForRung(g, .natural).direction);
    try std.testing.expectEqual(sem_graph.Direction.TD, rotateForRung(g, .tight).direction);
    try std.testing.expectEqual(sem_graph.Direction.LR, rotateForRung(g, .switch_direction).direction);
    try std.testing.expectEqual(sem_graph.Direction.TD, rotateForRung(g, .truncate).direction);

    var g2 = g;
    g2.direction = .BT;
    try std.testing.expectEqual(sem_graph.Direction.RL, rotateForRung(g2, .switch_direction).direction);
}
