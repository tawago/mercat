//! Semantic identity and star-law checks for one realized shared rail.
//!
//! A `RailClaim` records the final, render-local semantic facts behind shared
//! rail ink. Members are the single source of truth: `check` derives the
//! pivot, its attachment site, and the unresolved count from them on demand.
//! Pure data and pure functions only; imports the canonical primitive module.

const prim = @import("prim");

pub const NodeId = prim.NodeId;
pub const EdgeId = prim.EdgeId;
pub const Dir4 = prim.Dir4;
pub const ArrowKind = prim.ArrowKind;
pub const EdgeKind = prim.EdgeKind;

/// Render-local rail identity. Claims are numbered from one; zero means that
/// no claim is present. This identity is separate from channel identity.
pub const RailClaimId = u32;
pub const no_rail_claim: RailClaimId = 0;

pub fn validId(id: RailClaimId) bool {
    return id != no_rail_claim;
}

/// Which endpoint all members of a rail share.
pub const RailPolarity = enum(u1) {
    /// Members share their source and fan out to distinct targets.
    out = 0,
    /// Members share their target and fan in from distinct sources.
    in = 1,

    pub fn pivotEnd(self: RailPolarity) Endpoint {
        return switch (self) {
            .out => .source,
            .in => .target,
        };
    }
};

/// One of an edge's two declared ends. Its ordinal indexes the endpoint,
/// attachment-site, and arrow arrays in `RailClaimMember`.
pub const Endpoint = enum(u1) {
    source = 0,
    target = 1,

    pub fn index(self: Endpoint) usize {
        return @intFromEnum(self);
    }

    pub fn opposite(self: Endpoint) Endpoint {
        return switch (self) {
            .source => .target,
            .target => .source,
        };
    }
};

/// A final perimeter attachment. `offset` has the same side-local, zero-based
/// meaning as `sketch.Port.offset`; `node` makes the site self-identifying
/// after cluster and stitch remaps.
pub const AttachmentSite = struct {
    node: NodeId,
    side: Dir4,
    offset: u32,
};

/// One semantic edge carried by a rail. Null endpoints or sites mean that the
/// producer could not finish the corresponding final-space remap.
pub const RailClaimMember = struct {
    edge: EdgeId,
    endpoints: [2]?NodeId,
    sites: [2]?AttachmentSite,
    arrows: [2]ArrowKind,
    /// Class of ink this member stands for beyond its own end glyphs
    /// (a placement edge proxies its crossings' decoration).
    stands_for: prim.StandsFor = .arrow_free,
    kind: EdgeKind,
    /// Producer's assertion about which end meets the pivot. The checker also
    /// derives this from `polarity` and reports disagreement independently.
    pivot_end: Endpoint,

    pub fn node(self: RailClaimMember, end: Endpoint) ?NodeId {
        return self.endpoints[end.index()];
    }

    pub fn site(self: RailClaimMember, end: Endpoint) ?AttachmentSite {
        return self.sites[end.index()];
    }

    pub fn arrow(self: RailClaimMember, end: Endpoint) ArrowKind {
        return self.arrows[end.index()];
    }
};

/// Licence-tier member: the graph facts of one edge, no geometry. The type
/// has no site fields, so a pre-layout producer cannot fabricate them.
pub const RailLicenceMember = struct {
    edge: EdgeId,
    endpoints: [2]?NodeId,
    arrows: [2]ArrowKind,
    /// Class of ink this member stands for beyond its own end glyphs
    /// (a placement edge proxies its crossings' decoration).
    stands_for: prim.StandsFor = .arrow_free,
    kind: EdgeKind,
    pivot_end: Endpoint,

    pub fn node(self: RailLicenceMember, end: Endpoint) ?NodeId {
        return self.endpoints[end.index()];
    }

    pub fn arrow(self: RailLicenceMember, end: Endpoint) ArrowKind {
        return self.arrows[end.index()];
    }
};

/// Licence-tier claim: the semantic sharing question, asked of the graph
/// alone. `pivot` is the caller's claimed pivot; the checker reports both the
/// member consensus and disagreement with the claim.
pub const RailLicence = struct {
    id: RailClaimId,
    polarity: RailPolarity,
    pivot: NodeId,
    members: []const RailLicenceMember,
};

/// One render-local semantic claim for shared rail ink. Pivot, pivot site,
/// and resolution state are derived from members by `check`, never stored.
pub const RailClaim = struct {
    id: RailClaimId,
    polarity: RailPolarity,
    members: []const RailClaimMember,
};

/// BND-S and attachment-coherence failures. Every field is independent: one
/// malformed member set may truthfully report several failures at once.
pub const BndSResult = struct {
    no_common_real_pivot: bool = false,
    wrong_polarity_end: bool = false,
    duplicate_member_edge: bool = false,
    duplicate_leaf: bool = false,
    parallel: bool = false,
    antiparallel: bool = false,
    self_loop: bool = false,
    leaf_is_pivot: bool = false,
    differing_or_missing_pi: bool = false,
    /// Licence tier only: a member's pivot end is missing or is not the
    /// claimed pivot. Realized claims derive their pivot; never set there.
    pivot_not_claimed: bool = false,
    /// L1 blocking predicate: a directional end is present in the star, yet
    /// some member does not block (`prim.blocks`) — two directional ends,
    /// or none while another member carries one. An ALL-arrow-free star is
    /// L3's domain (base/rail_closure.zig) and never sets this.
    non_blocking_member: bool = false,

    pub fn isValid(self: BndSResult) bool {
        return !self.no_common_real_pivot and
            !self.wrong_polarity_end and
            !self.duplicate_member_edge and
            !self.duplicate_leaf and
            !self.parallel and
            !self.antiparallel and
            !self.self_loop and
            !self.leaf_is_pivot and
            !self.differing_or_missing_pi and
            !self.pivot_not_claimed and
            !self.non_blocking_member;
    }
};

/// Pivot-end decoration has its own result so it maps to `rail_deco_mixed`,
/// not the structural star diagnostic.
pub const DecorationResult = struct {
    mixed_pivot_decoration: bool = false,

    pub fn isValid(self: DecorationResult) bool {
        return !self.mixed_pivot_decoration;
    }
};

/// Stroke-class agreement has its own result so it maps to
/// `rail_member_style_mixed` independently of decoration and BND-S.
pub const StyleResult = struct {
    style_mismatch: bool = false,

    pub fn isValid(self: StyleResult) bool {
        return !self.style_mismatch;
    }
};

/// Envelope failures. `unresolved` is derived from members.
pub const RecordResult = struct {
    invalid_id: bool = false,
    arity: bool = false,
    unresolved: bool = false,

    pub fn isValid(self: RecordResult) bool {
        return !self.invalid_id and !self.arity and !self.unresolved;
    }
};

/// The non-overlapping diagnostic partitions of a check result. A `true`
/// field means that partition has at least one failure.
pub const FailurePartition = struct {
    bnd_s: bool,
    decoration: bool,
    style: bool,
    record: bool,

    pub fn any(self: FailurePartition) bool {
        return self.bnd_s or self.decoration or self.style or self.record;
    }
};

pub const CheckResult = struct {
    bnd_s: BndSResult,
    decoration: DecorationResult,
    style: StyleResult,
    record: RecordResult,
    derived_pivot: ?NodeId,
    derived_pi: ?AttachmentSite,
    derived_unresolved_members: u32,

    /// Exact validity: identity, arity, resolution, BND-S, decoration,
    /// and style must all be valid.
    pub fn isValid(self: CheckResult) bool {
        return !self.partition().any();
    }

    pub fn partition(self: CheckResult) FailurePartition {
        return .{
            .bnd_s = !self.bnd_s.isValid(),
            .decoration = !self.decoration.isValid(),
            .style = !self.style.isValid(),
            .record = !self.record.isValid(),
        };
    }
};

/// Licence-tier verdict: the semantic partitions only. Resolution and pi are
/// realization facts and have no licence-tier meaning.
pub const LicenceCheckResult = struct {
    bnd_s: BndSResult,
    decoration: DecorationResult,
    style: StyleResult,
    record: RecordResult,
    derived_pivot: ?NodeId,

    pub fn isValid(self: LicenceCheckResult) bool {
        return self.bnd_s.isValid() and self.decoration.isValid() and
            self.style.isValid() and self.record.isValid();
    }
};

/// Validate one licence-tier claim from graph facts alone.
pub fn checkLicence(licence: RailLicence) LicenceCheckResult {
    return semanticCore(licence.id, licence.polarity, licence.pivot, licence.members);
}

/// Derive and validate one realized claim without allocation or mutation.
pub fn check(claim: RailClaim) CheckResult {
    const sem = semanticCore(claim.id, claim.polarity, null, claim.members);
    var bnd = sem.bnd_s;
    var record = sem.record;

    var unresolved: u32 = 0;
    for (claim.members) |member| {
        if (!endResolved(member, .source) or !endResolved(member, .target)) {
            if (unresolved != max_u32) unresolved += 1;
        }
    }
    record.unresolved = unresolved != 0;

    var derived_pi: ?AttachmentSite = null;
    var pi_consistent = claim.members.len != 0;
    for (claim.members, 0..) |member, i| {
        const site = member.site(member.pivot_end) orelse {
            pi_consistent = false;
            continue;
        };
        const node = member.node(member.pivot_end) orelse {
            pi_consistent = false;
            continue;
        };
        if (site.node != node) pi_consistent = false;
        if (i == 0) {
            derived_pi = site;
        } else if (derived_pi == null or !siteEqual(derived_pi.?, site)) {
            pi_consistent = false;
        }
    }
    if (!pi_consistent) derived_pi = null;
    bnd.differing_or_missing_pi = derived_pi == null;

    return .{
        .bnd_s = bnd,
        .decoration = sem.decoration,
        .style = sem.style,
        .record = record,
        .derived_pivot = sem.derived_pivot,
        .derived_pi = derived_pi,
        .derived_unresolved_members = unresolved,
    };
}

/// The checks both tiers share, over any member type carrying graph facts.
/// `claimed_pivot` is licence-tier only; realized claims pass null.
fn semanticCore(id: RailClaimId, polarity: RailPolarity, claimed_pivot: ?NodeId, members: anytype) LicenceCheckResult {
    var bnd: BndSResult = .{};
    var decoration: DecorationResult = .{};
    var style: StyleResult = .{};
    const record: RecordResult = .{
        .invalid_id = !validId(id),
        .arity = members.len < 2,
    };

    const expected_pivot_end = polarity.pivotEnd();
    var derived_pivot: ?NodeId = null;
    var pivot_consistent = members.len != 0;

    for (members, 0..) |member, i| {
        if (member.pivot_end != expected_pivot_end) bnd.wrong_polarity_end = true;

        const member_pivot = member.node(member.pivot_end) orelse {
            pivot_consistent = false;
            continue;
        };
        if (i == 0) {
            derived_pivot = member_pivot;
        } else if (derived_pivot == null or derived_pivot.? != member_pivot) {
            pivot_consistent = false;
        }
    }
    if (!pivot_consistent) derived_pivot = null;
    bnd.no_common_real_pivot = derived_pivot == null;

    if (claimed_pivot) |pivot| {
        var claimed_ok = members.len != 0;
        for (members) |member| {
            const member_pivot = member.node(member.pivot_end) orelse {
                claimed_ok = false;
                continue;
            };
            if (member_pivot != pivot) claimed_ok = false;
        }
        bnd.pivot_not_claimed = !claimed_ok;
    }

    var any_directional = false;
    var any_non_blocking = false;
    for (members) |member| {
        const from = member.arrow(.source);
        const to = member.arrow(.target);
        if (!prim.memberArrowFree(from, to, member.stands_for)) any_directional = true;
        if (!prim.memberBlocks(from, to, member.stands_for)) any_non_blocking = true;
    }
    bnd.non_blocking_member = any_directional and any_non_blocking;

    if (members.len != 0) {
        const first = members[0];
        const first_deco = first.arrow(first.pivot_end);
        const first_kind = first.kind;
        for (members[1..]) |member| {
            if (member.arrow(member.pivot_end) != first_deco)
                decoration.mixed_pivot_decoration = true;
            if (member.kind != first_kind) style.style_mismatch = true;
        }
    }

    for (members, 0..) |member, i| {
        const source = member.node(.source);
        const target = member.node(.target);
        if (source != null and target != null and source.? == target.?)
            bnd.self_loop = true;
        const member_pivot = member.node(member.pivot_end);
        const member_leaf = member.node(member.pivot_end.opposite());
        if (sameResolvedNode(member_pivot, member_leaf))
            bnd.leaf_is_pivot = true;

        for (members[0..i]) |prior| {
            if (prior.edge == member.edge) bnd.duplicate_member_edge = true;
            if (sameResolvedNode(
                prior.node(prior.pivot_end.opposite()),
                member.node(member.pivot_end.opposite()),
            ))
                bnd.duplicate_leaf = true;
            if (sameResolvedPair(prior, member, false)) bnd.parallel = true;
            if (sameResolvedPair(prior, member, true)) bnd.antiparallel = true;
        }
    }

    return .{
        .bnd_s = bnd,
        .decoration = decoration,
        .style = style,
        .record = record,
        .derived_pivot = derived_pivot,
    };
}

const max_u32: u32 = 0xffff_ffff;

fn endResolved(member: RailClaimMember, end: Endpoint) bool {
    const node = member.node(end) orelse return false;
    const site = member.site(end) orelse return false;
    return site.node == node;
}

fn sameResolvedNode(a: ?NodeId, b: ?NodeId) bool {
    return a != null and b != null and a.? == b.?;
}

fn sameResolvedPair(a: anytype, b: @TypeOf(a), reversed: bool) bool {
    const af = a.node(.source) orelse return false;
    const at = a.node(.target) orelse return false;
    const bf = b.node(.source) orelse return false;
    const bt = b.node(.target) orelse return false;
    return if (reversed) af == bt and at == bf else af == bf and at == bt;
}

fn siteEqual(a: AttachmentSite, b: AttachmentSite) bool {
    return a.node == b.node and a.side == b.side and a.offset == b.offset;
}
