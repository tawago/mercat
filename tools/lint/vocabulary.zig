//! Check 5: banned-token tombstones. Each row is a spelling deliberately
//! retired (a completed rename's old identifier, a deleted mechanism's
//! symbol) or a zone invariant cheaper to state as a token than as an
//! import rule. Matching is a plain case-sensitive substring scan over the
//! whole file, comments included: a tombstone also stops the old word
//! returning as prose. POLICY: tokens are FULL identifiers or longer
//! (e.g. "lanes.Demand", "fan_in_trunk", "pub fn weld") — never bare word
//! stems. The three short privacy-boundary tokens are complete acronyms or a
//! complete sigil, not stems. Exemptions are by basename (the matching
//! gb_external uses), via `allow` (everywhere except) or `only` (nowhere except).
//! Consequence for authors: never spell a retired name in a migration
//! note — describe it ("the pre-rename lane type").

const std = @import("std");

pub const Row = struct {
    token: []const u8,
    why: []const u8,
    allow: []const []const u8 = &.{},
    only: []const []const u8 = &.{},
};

pub const table = [_]Row{
    .{
        .token = "TSD",
        .why = "private design-document references do not belong in tracked renderer source; state the behavioral contract directly",
    },
    .{
        .token = "SDD",
        .why = "private design-document references do not belong in tracked renderer source; state the behavioral contract directly",
    },
    .{
        .token = "§",
        .why = "private section pointers do not belong in tracked renderer source; state the behavioral contract directly",
    },
    .{
        .token = "pub fn codepointWidth",
        .why = "src/lib/unicode.zig is the Unicode width authority; codepointWidth exists there and as the delegating prim wrapper in base/types.zig, never as a third table",
        .allow = &.{ "unicode.zig", "types.zig" },
    },
    .{
        .token = "lib/unicode.zig",
        .why = "import the Unicode authority as the named module \"unicode\" so consumers cannot bypass one shared module identity",
        .allow = &.{ "types.zig", "imports.zig", "vocabulary.zig" },
    },
    .{
        .token = "getenv",
        .why = "entry.zig is the sole env-knob reader in mermaid_v2 (see its header); thread values down as plain parameters",
        .allow = &.{"entry.zig"},
    },
    .{
        .token = "lanes.Demand",
        .why = "renamed lanes.LaneClaim (rename wave A); the qualified old spelling is retired",
    },
    .{
        .token = "pub const Demand",
        .only = &.{"lanes.zig"},
        .why = "base/lanes.zig's interval type is LaneClaim; ports.zig's SideDemand family is unrelated and unaffected",
    },
    .{
        .token = "PiercesRect",
        .why = "columnPiercesRect/rowPiercesRect are columnIntrudesRect/rowIntrudesRect: they detect illegal strict-interior intrusion; 'pierce' is reserved for licensed border-crossing corridors",
    },
    .{ .token = "polyPierces", .why = "renamed polyIntrudes (rename wave A)" },
    .{ .token = "finalLegPierces", .why = "renamed finalLegIntrudes (rename wave A)" },
    .{
        .token = "mergeSourceBorder",
        .why = "renamed drawPortStroke (rename wave B): it draws the departure port stroke on the source node border",
    },
    .{
        .token = "repairReciprocalArms",
        .why = "the additive reciprocity-repair post-pass this named is DELETED, under this spelling and its later one alike; a neighbour bit the edge writer declined is never restored from geometry. The neighbour-bit 'arm' vocabulary itself is unaffected",
    },
    .{
        .token = "repairReciprocalStrokes",
        .why = "DELETED mechanism: the post-walk pass that re-added a neighbour bit toward any reciprocating edge_segment. It ran before the side table was attached and was handed no crossing context, so it could not tell a legal bundle sharer from the foreign arm the crossing rule had just refused — and it put both back, painting a junction no source declares. The remedy for a false disconnect is evidence upstream (declare the sharing relation as a ledger.Bundle so the refusal never fires on a legal sharer), never an additive repair downstream. raster/reconcile.zig CLEARS only",
    },
    .{
        .token = "ensureBaseApproachLengthen",
        .why = "renamed satisfyApproach (rename wave B): it satisfies the base-side approach law for a terminal",
    },
    .{
        .token = "pub fn weld",
        .why = "raster/arrow_base's pass is receiveBase (rename wave B); 'weld' stays as the event vocabulary (c_border_arm_weld, the weld-order pin), never as a function name",
    },
    .{
        .token = "fan_out_trunk",
        .why = "the fan-OUT EdgeRole pair is fan_out_rail (the whole shared run) / fan_out_dropper (one child's leg); the old scheme is inexpressible without this spelling",
    },
    .{
        .token = "fan_in_trunk",
        .why = "the fan-IN EdgeRole pair is fan_in_rail (the whole shared run) / fan_in_dropper (one source's leg); the old scheme is inexpressible without this spelling",
    },
    .{
        .token = "BusBar",
        .why = "the first-class fan rail type is sketch.Rail, and its horizontal span is the `crossbar` field; the whole camelCase family went with it (rasterizeRails, drawRail, translateRail, conflictsRails/RailArrows/RailJunctions, railDirection, checkRails), and the lowercase family followed (raster/rails.zig, Sketch.rails)",
    },
    .{
        .token = "fan_busbar",
        .why = "the fan rail builder is layout/fan_rail.zig (+ fan_rail_test.zig); the old module basename is retired, including in guarded-by pointers and import strings",
    },
    .{
        .token = "trunk_member_style_mixed",
        .why = "the diagnostic tag is rail_member_style_mixed (rename wave D): the shared run a fan realizes is a rail; the tag name is also its record-verbatim wire name",
    },
    .{
        .token = "trunk_member_invisible",
        .why = "the diagnostic tag is rail_member_invisible (rename wave D); the tag name is also its record-verbatim wire name",
    },
    .{
        .token = "trunk_pivot_side_arrow",
        .why = "the diagnostic tag is rail_pivot_side_arrow (rename wave D); ports.AttachmentClass later became rail_pivot (P8), which this longer token never matched",
    },
    .{
        .token = "trunk_duplicate_pair",
        .why = "the diagnostic tag is rail_duplicate_pair (rename wave D); the GroupVerdict.duplicate_pair flag it inventories is unaffected",
    },
    .{
        .token = "label_left_of_rail",
        .why = "EdgePath's back-edge label side flag is label_left_of_run (producer: clusters.LabelFootprint.left_of_run); 'rail' now names a fan's shared run, never an ordinary edge's vertical run",
    },
    .{
        .token = "meshUnionLegal",
        .why = "there is no union to judge legal: a shared run is licensed by the ONE endpoint its members share, discovered as a star group in ledger/permits.zig, and everything a rail additionally implies is judged by the declared-pair closure test — stated in base/rail_closure.zig and applied per fused group, trace-blocked and not alike, by layout/fan_lanes.zig (amended 2026-08-04)",
    },
    .{
        .token = "stampFanTrunks",
        .why = "the post-hoc grid re-derivation of fan roles is gone: roles are stamped from producer facts (raster/fan_roles.markShared at write time) and the fan-OUT strip resolved from the Sketch's pivot geometry (raster/fan_roles.resolveMasks). Never re-infer a role by scanning the finished lattice",
    },
    .{
        .token = "MERCAT_FANROLE_SHADOW",
        .why = "the fan-role shadow comparator was retired with the inference it shadowed; the producers' roles ARE the derived roles now, and a peer-drawn rail role and its membership record are pinned as one event",
    },
    .{
        .token = "mercat-fanrole-shadow",
        .why = "the shadow comparator's stderr line is retired along with its knob; there is no second reading of fan roles to report",
    },
    .{
        .token = "mesh_legal",
        .why = "the complete-mesh union path is gone; ledger/dispose.zig (clause-(g)-pre withdrawal) is what survived the split, and there is no legality module because there is no union to judge",
    },
    .{
        .token = "meshUnions",
        .why = "a shared rail exists only where members share ONE exact endpoint, so there is no K(N,M) union producer; an all-to-all renders as its star decomposition (one rail per shared endpoint, lane-separated by layout/fan_lanes.zig)",
    },
    .{
        .token = "fanMeshExempt",
        .why = "there is no fan-level exemption mechanism to name: layout/fan_lanes.zig admits a fused group only by the closure test on the group's own declared edges (fusionForbidden — a two-sided group keeps one row exactly when every member blocks the leaf-to-leaf trace with a one-way head, no ink is missing from its model, and the declared set is the whole of srcs x tgts), never by exempting a fan (amended 2026-08-04)",
    },
    .{
        .token = "noDuplicateLeafPairs",
        .why = "the union-element legality predicate died with the union path (ledger/leaf_pairs.zig deleted); a star rail's legality is its shared pivot, checked where the group is discovered",
    },
    .{
        .token = "JoinGroup",
        .why = "the candidate-bundle record is ledger.CandidateBundle (P8): a bundle is the ONE name for a set of edges licensed to share ink; the Id went with it (CandidateBundleId)",
    },
    .{
        .token = "JoinPermits",
        .why = "the licence-tier record is ledger.BundlePermits (P8); the JoinPolicy/JoinDirection/JoinMembership family became BundlePolicy/BundleDirection/BundleMembership",
    },
    .{
        .token = "JoinProposal",
        .why = "the candidate-local proposal record is ledger.BundleProposal (P8)",
    },
    .{
        .token = "SelectedJoin",
        .why = "the fusion-tier selection record is ledger.SelectedBundle (P8); its id type is SelectedBundleId (formerly RealizedJoinId)",
    },
    .{
        .token = "RealizedJoins",
        .why = "the candidate-local realization envelope is ledger.RealizedBundles (P8), riding Sketch.bundles",
    },
    .{
        .token = "intentional_joins",
        .why = "the diagnostic tag is intentional_bundles (P8)",
    },
    .{
        .token = "permission_group",
        .why = "the disposition/proposal field is candidate_bundle (P8): it names the candidate bundle the membership belongs to",
    },
    .{
        .token = "CoSet",
        .why = "the operational sharing-membership record is ledger.Bundle (P8, base/bundle.zig): a co-set always WAS a bundle — the one structural decision that licenses shared ink",
    },
    .{
        .token = "ChannelId",
        .why = "the sharing identity a rail's ink carries is the bundle's: ledger.BundleId (P8); no_channel/privateChannel/channelOf/channelsAgree became no_bundle/privateBundle/bundleOf/bundlesAgree",
    },
    .{
        .token = "co_realized",
        .why = "the theory name is DISCHARGE: RealizedBundles.discharged (P8) lists the declared edges whose entire rendering is a span of another bundle's rail",
    },
    .{
        .token = "sketch_channels",
        .why = "the stamp module is sketch_bundles.zig (P8); the old basename is retired, including in guarded-by pointers and import strings",
    },
    .{
        .token = "co_channel",
        .why = "the membership-vocabulary module is base/bundle.zig (P8)",
    },
    .{
        .token = "bridge_trunks",
        .why = "the licensed shared-source module is cluster/bridge_rails.zig (P8): the rendered shared stretch is a rail everywhere",
    },
    .{
        .token = "BndSResult",
        .why = "renamed to StarLawResult (P10): lettered concept codes are retired for articulated names",
    },
    .{
        .token = "fan_rail_law",
        .why = "renamed fan_rail_licence.zig (P11): the closure rule is a licence, the same logical level as the star and fusion licences",
    },
    .{
        .token = "bnd_s",
        .why = "renamed to star_law (P10): lettered concept codes are retired for articulated names",
    },
};

fn basenameOf(rel_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, rel_path, std.fs.path.sep)) |s| return rel_path[s + 1 ..];
    return rel_path;
}

fn applies(row: Row, base: []const u8) bool {
    if (row.only.len != 0) {
        for (row.only) |f| if (std.mem.eql(u8, f, base)) return true;
        return false;
    }
    for (row.allow) |f| if (std.mem.eql(u8, f, base)) return false;
    return true;
}

/// One violation per (file, row): the fix is always "remove every occurrence".
/// Reports the 1-based line of the first hit.
pub fn scan(
    a: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    rel_path: []const u8,
    contents: []const u8,
    rows: []const Row,
) !void {
    const base = basenameOf(rel_path);
    for (rows) |row| {
        if (!applies(row, base)) continue;
        const hit = std.mem.indexOf(u8, contents, row.token) orelse continue;
        var line: usize = 1;
        for (contents[0..hit]) |c| {
            if (c == '\n') line += 1;
        }
        try violations.append(a, try std.fmt.allocPrint(
            a,
            "{s}:{d}: banned token \"{s}\": {s}",
            .{ rel_path, line, row.token, row.why },
        ));
    }
}

const testing = std.testing;

/// Collects into a caller-freed list so each test can inspect the messages.
const Collected = struct {
    list: std.ArrayList([]const u8),

    fn deinit(self: *Collected, a: std.mem.Allocator) void {
        for (self.list.items) |v| a.free(v);
        self.list.deinit(a);
    }
};

fn collect(
    a: std.mem.Allocator,
    rel_path: []const u8,
    contents: []const u8,
    rows: []const Row,
) !Collected {
    var out = Collected{ .list = .empty };
    try scan(a, &out.list, rel_path, contents, rows);
    return out;
}

test "banned token: violation names file, 1-based line, token, and why" {
    const a = testing.allocator;
    const rows = [_]Row{.{ .token = "OldName", .why = "renamed to NewName" }};
    var got = try collect(a, "layout/thing.zig", "a\nb OldName", &rows);
    defer got.deinit(a);

    try testing.expectEqual(@as(usize, 1), got.list.items.len);
    const msg = got.list.items[0];
    try testing.expect(std.mem.indexOf(u8, msg, "layout/thing.zig") != null);
    try testing.expect(std.mem.indexOf(u8, msg, ":2:") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "OldName") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "NewName") != null);
}

test "banned token: absent token yields nothing" {
    const a = testing.allocator;
    const rows = [_]Row{.{ .token = "OldName", .why = "renamed to NewName" }};
    var got = try collect(a, "layout/thing.zig", "nothing retired in here\n", &rows);
    defer got.deinit(a);

    try testing.expectEqual(@as(usize, 0), got.list.items.len);
}

test "banned token: allow exempts by basename" {
    const a = testing.allocator;
    const rows = [_]Row{.{
        .token = "OldName",
        .why = "renamed to NewName",
        .allow = &.{"prose.zig"},
    }};

    var exempt = try collect(a, "layout/prose.zig", "OldName", &rows);
    defer exempt.deinit(a);
    try testing.expectEqual(@as(usize, 0), exempt.list.items.len);

    var caught = try collect(a, "layout/other.zig", "OldName", &rows);
    defer caught.deinit(a);
    try testing.expectEqual(@as(usize, 1), caught.list.items.len);
}

test "banned token: only scopes a row to named basenames" {
    const a = testing.allocator;
    const rows = [_]Row{.{
        .token = "OldName",
        .why = "renamed to NewName",
        .only = &.{"lanes.zig"},
    }};

    var base_hit = try collect(a, "base/lanes.zig", "OldName", &rows);
    defer base_hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), base_hit.list.items.len);

    var layout_hit = try collect(a, "layout/lanes.zig", "OldName", &rows);
    defer layout_hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), layout_hit.list.items.len);

    var miss = try collect(a, "layout/back_edges.zig", "OldName", &rows);
    defer miss.deinit(a);
    try testing.expectEqual(@as(usize, 0), miss.list.items.len);
}

test "banned token: repeated occurrences report once per file" {
    const a = testing.allocator;
    const rows = [_]Row{.{ .token = "OldName", .why = "renamed to NewName" }};
    var got = try collect(a, "layout/thing.zig", "OldName\nOldName\nOldName\n", &rows);
    defer got.deinit(a);

    try testing.expectEqual(@as(usize, 1), got.list.items.len);
    try testing.expect(std.mem.indexOf(u8, got.list.items[0], ":1:") != null);
}

test "banned token: a reverted wave-A spelling fires" {
    const a = testing.allocator;
    var got = try collect(a, "layout/thing.zig", "const d = lanes.Demand{};\n", &table);
    defer got.deinit(a);

    try testing.expectEqual(@as(usize, 1), got.list.items.len);
    try testing.expect(std.mem.indexOf(u8, got.list.items[0], "LaneClaim") != null);
}

test "banned token: a reverted fan-role spelling fires on both families" {
    const a = testing.allocator;
    var out_hit = try collect(a, "raster/rails.zig", "role = .fan_out_trunk;\n", &table);
    defer out_hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), out_hit.list.items.len);
    try testing.expect(std.mem.indexOf(u8, out_hit.list.items[0], "fan_out_dropper") != null);

    var in_hit = try collect(a, "raster/rails.zig", "role = .fan_in_trunk;\n", &table);
    defer in_hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), in_hit.list.items.len);
    try testing.expect(std.mem.indexOf(u8, in_hit.list.items[0], "fan_in_dropper") != null);
}

test "banned token: a reverted diagnostic-tag spelling fires" {
    const a = testing.allocator;
    var got = try collect(a, "ledger/realized.zig", "return .trunk_pivot_side_arrow;\n", &table);
    defer got.deinit(a);

    try testing.expectEqual(@as(usize, 1), got.list.items.len);
    try testing.expect(std.mem.indexOf(u8, got.list.items[0], "rail_pivot_side_arrow") != null);
}

test "banned token: an env read outside entry.zig fires, and entry.zig is exempt" {
    const a = testing.allocator;
    var hit = try collect(a, "layout/thing.zig", "const v = std.posix.getenv(\"MERCAT_X\");\n", &table);
    defer hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), hit.list.items.len);
    try testing.expect(std.mem.indexOf(u8, hit.list.items[0], "entry.zig is the sole env-knob reader") != null);

    var exempt = try collect(a, "entry.zig", "const v = std.posix.getenv(\"MERCAT_X\");\n", &table);
    defer exempt.deinit(a);
    try testing.expectEqual(@as(usize, 0), exempt.list.items.len);
}

test "banned token: a third codepointWidth table fires, the two authorities are exempt" {
    const a = testing.allocator;
    var hit = try collect(a, "raster/labels.zig", "pub fn codepointWidth(cp: u21) u32 {\n", &table);
    defer hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), hit.list.items.len);

    var prim = try collect(a, "base/types.zig", "pub fn codepointWidth(cp: u21) u32 {\n", &table);
    defer prim.deinit(a);
    try testing.expectEqual(@as(usize, 0), prim.list.items.len);
}

test "banned token: production table is well-formed" {
    for (table) |row| {
        const short_privacy_token = std.mem.eql(u8, row.token, "TSD") or
            std.mem.eql(u8, row.token, "SDD") or
            std.mem.eql(u8, row.token, "§");
        try testing.expect(row.token.len >= 4 or short_privacy_token);
        try testing.expect(row.why.len != 0);
        try testing.expect(row.allow.len == 0 or row.only.len == 0);
    }
}
