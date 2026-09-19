const prim = @import("prim");

pub const NodeId = prim.NodeId;
pub const EdgeId = prim.EdgeId;
pub const Dir4 = prim.Dir4;
pub const ArrowKind = prim.ArrowKind;
pub const EdgeKind = prim.EdgeKind;

pub const RailClaimId = u32;
pub const no_rail_claim: RailClaimId = 0;

pub fn validId(id: RailClaimId) bool {
    return id != no_rail_claim;
}

pub const RailPolarity = enum(u1) {
    out = 0,
    in = 1,

    pub fn pivotEnd(self: RailPolarity) Endpoint {
        return switch (self) {
            .out => .source,
            .in => .target,
        };
    }
};

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

pub const AttachmentSite = struct {
    node: NodeId,
    side: Dir4,
    offset: u32,
};

pub const RailClaimMember = struct {
    edge: EdgeId,
    endpoints: [2]?NodeId,
    sites: [2]?AttachmentSite,
    arrows: [2]ArrowKind,
    stands_for: prim.StandsFor = .arrow_free,
    kind: EdgeKind,
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

pub const RailLicenceMember = struct {
    edge: EdgeId,
    endpoints: [2]?NodeId,
    arrows: [2]ArrowKind,
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

pub const RailLicence = struct {
    id: RailClaimId,
    polarity: RailPolarity,
    pivot: NodeId,
    members: []const RailLicenceMember,
};

pub const RailClaim = struct {
    id: RailClaimId,
    polarity: RailPolarity,
    members: []const RailClaimMember,
};

pub const StarLawResult = struct {
    no_common_real_pivot: bool = false,
    wrong_polarity_end: bool = false,
    duplicate_member_edge: bool = false,
    duplicate_leaf: bool = false,
    parallel: bool = false,
    antiparallel: bool = false,
    self_loop: bool = false,
    leaf_is_pivot: bool = false,
    differing_or_missing_pi: bool = false,
    pivot_not_claimed: bool = false,
    non_blocking_member: bool = false,

    pub fn isValid(self: StarLawResult) bool {
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

pub const DecorationResult = struct {
    mixed_pivot_decoration: bool = false,

    pub fn isValid(self: DecorationResult) bool {
        return !self.mixed_pivot_decoration;
    }
};

pub const StyleResult = struct {
    style_mismatch: bool = false,

    pub fn isValid(self: StyleResult) bool {
        return !self.style_mismatch;
    }
};

pub const RecordResult = struct {
    invalid_id: bool = false,
    arity: bool = false,
    unresolved: bool = false,

    pub fn isValid(self: RecordResult) bool {
        return !self.invalid_id and !self.arity and !self.unresolved;
    }
};

pub const FailurePartition = struct {
    star_law: bool,
    decoration: bool,
    style: bool,
    record: bool,

    pub fn any(self: FailurePartition) bool {
        return self.star_law or self.decoration or self.style or self.record;
    }
};

pub const CheckResult = struct {
    star_law: StarLawResult,
    decoration: DecorationResult,
    style: StyleResult,
    record: RecordResult,
    derived_pivot: ?NodeId,
    derived_pi: ?AttachmentSite,
    derived_unresolved_members: u32,

    pub fn isValid(self: CheckResult) bool {
        return !self.partition().any();
    }

    pub fn partition(self: CheckResult) FailurePartition {
        return .{
            .star_law = !self.star_law.isValid(),
            .decoration = !self.decoration.isValid(),
            .style = !self.style.isValid(),
            .record = !self.record.isValid(),
        };
    }
};

pub const LicenceCheckResult = struct {
    star_law: StarLawResult,
    decoration: DecorationResult,
    style: StyleResult,
    record: RecordResult,
    derived_pivot: ?NodeId,

    pub fn isValid(self: LicenceCheckResult) bool {
        return self.star_law.isValid() and self.decoration.isValid() and
            self.style.isValid() and self.record.isValid();
    }
};

pub fn checkLicence(licence: RailLicence) LicenceCheckResult {
    return semanticCore(licence.id, licence.polarity, licence.pivot, licence.members);
}

pub fn check(claim: RailClaim) CheckResult {
    const sem = semanticCore(claim.id, claim.polarity, null, claim.members);
    var law = sem.star_law;
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
    law.differing_or_missing_pi = derived_pi == null;

    return .{
        .star_law = law,
        .decoration = sem.decoration,
        .style = sem.style,
        .record = record,
        .derived_pivot = sem.derived_pivot,
        .derived_pi = derived_pi,
        .derived_unresolved_members = unresolved,
    };
}

fn semanticCore(id: RailClaimId, polarity: RailPolarity, claimed_pivot: ?NodeId, members: anytype) LicenceCheckResult {
    var law: StarLawResult = .{};
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
        if (member.pivot_end != expected_pivot_end) law.wrong_polarity_end = true;

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
    law.no_common_real_pivot = derived_pivot == null;

    if (claimed_pivot) |pivot| {
        var claimed_ok = members.len != 0;
        for (members) |member| {
            const member_pivot = member.node(member.pivot_end) orelse {
                claimed_ok = false;
                continue;
            };
            if (member_pivot != pivot) claimed_ok = false;
        }
        law.pivot_not_claimed = !claimed_ok;
    }

    var any_directional = false;
    var any_non_blocking = false;
    for (members) |member| {
        const from = member.arrow(.source);
        const to = member.arrow(.target);
        if (!prim.memberArrowFree(from, to, member.stands_for)) any_directional = true;
        if (!prim.memberBlocks(from, to, member.stands_for)) any_non_blocking = true;
    }
    law.non_blocking_member = any_directional and any_non_blocking;

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
            law.self_loop = true;
        const member_pivot = member.node(member.pivot_end);
        const member_leaf = member.node(member.pivot_end.opposite());
        if (sameResolvedNode(member_pivot, member_leaf))
            law.leaf_is_pivot = true;

        for (members[0..i]) |prior| {
            if (prior.edge == member.edge) law.duplicate_member_edge = true;
            if (sameResolvedNode(
                prior.node(prior.pivot_end.opposite()),
                member.node(member.pivot_end.opposite()),
            ))
                law.duplicate_leaf = true;
            if (sameResolvedPair(prior, member, false)) law.parallel = true;
            if (sameResolvedPair(prior, member, true)) law.antiparallel = true;
        }
    }

    return .{
        .star_law = law,
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
