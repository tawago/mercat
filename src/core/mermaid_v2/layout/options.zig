//! layout/options.zig — the per-candidate layout knob bag.
//!
//! Cap-forced split of layout.zig: `LayoutOptions` is the one struct every
//! driver (budget.zig's rung ladder, recurse.zig, select.zig's variants)
//! fills in to steer one layout pass, plus the `Justify` enum it carries.
//! Pure data; re-exported from layout.zig so every existing call site keeps
//! naming it `layout.LayoutOptions` / `coords.LayoutOptions`.

const prim = @import("prim");
const ledger = @import("../base/ledger.zig");
const sizing = @import("sizing.zig");

/// A caller-imposed size override for one node; see `sizing.FixedSize`.
pub const FixedSize = sizing.FixedSize;

pub const LayoutOptions = struct {
    /// One render-wide semantic permission plan, inert until bundle planning.
    /// Carries its own scope (flat vs skipped_clustered); never re-derived
    /// from recursion pieces.
    bundle_permits: ?*const ledger.BundlePermits = null,
    /// Width budget in display columns.
    max_width: u32 = 120,
    /// Horizontal spacing between adjacent nodes in the same layer.
    h_spacing: u32 = 4,
    /// Vertical spacing between adjacent layers.
    v_spacing: u32 = 2,
    /// Padding inside each node (text margin).
    node_padding: u32 = 1,
    /// Initial budget rung. Coords doesn't run the ladder itself, but
    /// exposing this lets the ladder driver set it later.
    rung: u8 = 0,
    /// Optional per-node size overrides (super-node sizing). Empty by
    /// default — a label-only flowchart sizes every node from its text.
    fixed_sizes: []const FixedSize = &.{},
    /// The nodes a cross-border edge leaves toward the flow (cluster/split.zig
    /// `Departure`): the bridge routed above this piece jogs in the row under
    /// such a node when a box stacked beneath it forces a corridor, and the
    /// row ledger reserves that row.
    departures: []const ledger.NodeId = &.{},
    /// Soft word-wrap cap in display columns; null = no soft wrap. Set only
    /// on the budget ladder's `wrap_labels` rung. When non-null, `sizeNodes`
    /// word-wraps each node label to this width (hard `<br>`/`\n` breaks are
    /// always honored regardless). Author hard breaks are independent of this
    /// knob; this only gates *soft* wrapping under budget pressure.
    max_label_width: ?u32 = null,
    /// True when the budget ladder has rotated this graph's flow direction
    /// 90° (the `switch_direction` rung). Set by `budget.optionsFor`. When
    /// true, drift compaction (`compact_x`) is suppressed: a rotated diagram
    /// is a long single-rail chain that relies on raw packed positions to
    /// keep its vertical connectors drilled.
    is_direction_rotated: bool = false,
    /// Justification under width pressure. `.center` (the default, used on the
    /// `natural` rung) centers narrow rows on their parent barycenter;
    /// `.flush_left` (every rung > `natural`) suppresses that recentering so
    /// rows stay left-packed, recovering orphan whitespace.
    justify: Justify = .center,
    /// Inter-node / inter-cluster gap scale, in halvings. 0 = full-size gaps
    /// (natural rung); 1 = halve `SIBLING_GAP_BASE` / `CLUSTER_NODE_GAP`
    /// (every rung > `natural`), floored so boxes never collide. Frame insets
    /// are intentionally NOT scaled here (must move in lockstep with
    /// super-node sizing + the drawn frame).
    spacing_scale: u8 = 0,
    /// This candidate's cross-border bridge build (`prim.BridgeBuild`).
    /// `.plain` (default, and what every debug/forced driver uses) keeps
    /// the track-assigned jogs; select.zig lays out the dodged/railed
    /// variants for a clustered graph and the score against the real
    /// raster decides — routing itself never picks between them.
    bridge_build: prim.BridgeBuild = .plain,
};

/// Horizontal justification of layout rows. Pressure-gated: only the
/// `natural` rung uses `.center`; every wider rung uses `.flush_left`.
pub const Justify = enum { center, flush_left };
