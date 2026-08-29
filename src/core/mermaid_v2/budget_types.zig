//! budget_types.zig — the ladder's candidate vocabulary.
//!
//! Cap-forced split of budget.zig: the pure-data types the SELECTION layer
//! passes around (`Candidate`, the `Transform` taxonomy that produced it,
//! and `EnumerateResult`). No drivers, no layout calls. Re-exported from
//! budget.zig so every call site keeps naming them `budget.Candidate` etc.

const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const driver = @import("budget.zig");

pub const Rung = driver.Rung;
pub const LadderResult = driver.LadderResult;

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
    /// Bridge-build twins of a clustered graph's promising candidates
    /// (select.bridgeVariants): same recipe, `prim.BridgeBuild.dodged` /
    /// `.trunked` instead of the `.plain` default. Their rungs are chosen
    /// dynamically (raw natural + the ladder incumbent), so `rungs()` is
    /// empty for them.
    bridge_dodged,
    bridge_trunked,

    /// True when this transform can produce candidates for a graph flowing
    /// in `d`. Packing is a direction-preserving TD/BT move (rank_grid tiles
    /// vertical-flow rows).
    pub fn appliesTo(t: Transform, d: sem_graph.Direction) bool {
        return switch (t) {
            .raw, .bridge_dodged, .bridge_trunked => true,
            .motif_pack => d == .TD or d == .BT,
        };
    }

    /// The rung set this transform's candidates are laid out at. `.raw` is
    /// the full ladder (see `enumerate`). `.motif_pack` uses a capped set:
    /// rank_grid tiling of the rigid branch super-nodes fires under
    /// flush-left (rung >= tight); natural is kept as cheap insurance;
    /// rotating rungs are excluded — packing is direction-preserving.
    pub fn rungs(t: Transform) []const Rung {
        return switch (t) {
            .raw => &.{ .natural, .tight, .wrap_labels, .switch_direction, .truncate },
            .motif_pack => &.{ .natural, .tight, .truncate },
            .bridge_dodged, .bridge_trunked => &.{},
        };
    }
};

/// `run` plus retained candidates. `incumbent` is byte-for-byte the same
/// choice `run` makes; `candidates` holds every rung that laid out
/// successfully (all five in the common case), in rung order.
pub const EnumerateResult = struct {
    incumbent: LadderResult,
    candidates: []const Candidate,
};
