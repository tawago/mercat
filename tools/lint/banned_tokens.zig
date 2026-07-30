//! Check 5: banned-token tombstones. Each row is a spelling deliberately
//! retired (a completed rename's old identifier, a deleted mechanism's
//! symbol) or a zone invariant cheaper to state as a token than as an
//! import rule. Matching is a plain case-sensitive substring scan over the
//! whole file, comments included: a tombstone also stops the old word
//! returning as prose. POLICY: tokens are FULL identifiers or longer
//! (e.g. "lanes.Demand", "fan_in_trunk", "pub fn weld") — never bare word
//! stems; exemptions are by basename (the matching gb_external uses), via
//! `allow` (everywhere except) or `only` (nowhere except).
//! Consequence for authors: never spell a retired name in a migration
//! note — describe it ("the pre-rename lane type").

const std = @import("std");

pub const Row = struct {
    token: []const u8,
    why: []const u8, // printed with the violation; must name the replacement
    allow: []const []const u8 = &.{}, // basenames where the token stays legal
    only: []const []const u8 = &.{}, // if non-empty: row applies ONLY to these basenames
};

pub const table = [_]Row{
    .{
        .token = "pub fn codepointWidth",
        .why = "width policy has exactly two sanctioned copies (src/lib/unicode.zig and base/types.zig, drift-pinned); do not add a third",
        .allow = &.{"types.zig"},
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
        .why = "renamed repairReciprocalStrokes (rename wave B); the neighbour-bit 'arm' vocabulary itself is unaffected",
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
        .why = "the first-class fan trunk type is sketch.Rail, and its horizontal span is the `crossbar` field; the whole camelCase family went with it (rasterizeRails, drawRail, translateRail, conflictsRails/RailArrows/RailJunctions, railDirection, checkRails). The lowercase raster/busbars.zig filename and its local `busbars` names are deliberately unaffected — this row is case-sensitive",
    },
    .{
        .token = "fan_busbar",
        .why = "the fan trunk builder is layout/fan_rail.zig (+ fan_rail_test.zig); the old module basename is retired, including in guarded-by pointers and import strings",
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
        .why = "the diagnostic tag is rail_pivot_side_arrow (rename wave D); the unrelated ports.AttachmentClass.trunk_pivot keeps its name, which this longer token does not match",
    },
    .{
        .token = "trunk_duplicate_pair",
        .why = "the diagnostic tag is rail_duplicate_pair (rename wave D); the GroupVerdict.duplicate_pair flag it inventories is unaffected",
    },
    .{
        .token = "label_left_of_rail",
        .why = "EdgePath's back-edge label side flag is label_left_of_run (producer: clusters.LabelFootprint.left_of_run); 'rail' now names a fan's shared run, never an ordinary edge's vertical run",
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

    // Basename matching covers BOTH lanes.zig files — the behaviour the
    // base/ + layout/ sibling pair relies on.
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
    // Synthetic content, so the assertion never depends on tree state: if the
    // retired lane-type spelling comes back anywhere, the production table
    // must catch it and name the replacement.
    var got = try collect(a, "layout/thing.zig", "const d = lanes.Demand{};\n", &table);
    defer got.deinit(a);

    try testing.expectEqual(@as(usize, 1), got.list.items.len);
    try testing.expect(std.mem.indexOf(u8, got.list.items[0], "LaneClaim") != null);
}

test "banned token: a reverted fan-role spelling fires on both families" {
    const a = testing.allocator;
    // The fan roles were swapped in place (the old shared-run spelling now
    // names the per-child leg), so a half-reverted file is silently wrong
    // rather than a compile error: only these two tombstones catch it.
    var out_hit = try collect(a, "raster/busbars.zig", "role = .fan_out_trunk;\n", &table);
    defer out_hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), out_hit.list.items.len);
    try testing.expect(std.mem.indexOf(u8, out_hit.list.items[0], "fan_out_dropper") != null);

    var in_hit = try collect(a, "raster/busbars.zig", "role = .fan_in_trunk;\n", &table);
    defer in_hit.deinit(a);
    try testing.expectEqual(@as(usize, 1), in_hit.list.items.len);
    try testing.expect(std.mem.indexOf(u8, in_hit.list.items[0], "fan_in_dropper") != null);
}

test "banned token: a reverted diagnostic-tag spelling fires" {
    const a = testing.allocator;
    // The registry tags are their own wire names, so a reverted spelling
    // compiles fine in a stale switch arm and only shows up in emitted
    // records: the tombstone is the check that catches it.
    var got = try collect(a, "ledger/realized.zig", "return .trunk_pivot_side_arrow;\n", &table);
    defer got.deinit(a);

    try testing.expectEqual(@as(usize, 1), got.list.items.len);
    try testing.expect(std.mem.indexOf(u8, got.list.items[0], "rail_pivot_side_arrow") != null);
}

test "banned token: production table is well-formed" {
    for (table) |row| {
        try testing.expect(row.token.len >= 4);
        try testing.expect(row.why.len != 0);
        try testing.expect(row.allow.len == 0 or row.only.len == 0);
    }
}
