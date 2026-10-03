//! Reads a painted flowchart back and compares what its ink asserts with the
//! declared graph. Only tests and offline tools use it; nothing it decides
//! feeds the renderer.
//!
//! The reader knows the ink grammar and nothing about how the grid was made:
//! boxes are closed rectangles of border glyphs, a trace follows arms through
//! junctions, jumps one cell over ink or a subgraph frame it does not join,
//! and ends at a box border. Shared ink is judged by the trace model: a trace
//! may change member only at a junction, and every one-way member it runs
//! along must agree on its direction.

const std = @import("std");
const grid = @import("check/grid.zig");
const trace = @import("check/trace.zig");

pub const End = grid.End;
pub const Finding = grid.Finding;
pub const Stroke = trace.Stroke;
pub const Endpoint = trace.Endpoint;
pub const Relation = trace.Relation;

pub const Verdict = enum { faithful, lying, undecodable };

/// What the source declares, with labels as written.
pub const Declared = struct {
    labels: []const []const u8,
    edges: []const Relation,
};

pub const Judgement = struct {
    verdict: Verdict,
    /// True when a row ends in the clip marker: the grid says it is incomplete.
    clipped: bool,
    /// Relations the ink asserts that the source does not declare.
    fabricated: []const Relation,
    /// Declared relations the ink does not assert.
    lost: []const Relation,
    /// Boxes whose text names no declared node.
    unknown_boxes: []const []const u8,
    /// Boxes showing only part of their node's label, with no ellipsis.
    mangled_boxes: []const []const u8,
    /// Declared nodes with no box.
    missing_nodes: []const []const u8,
    findings: []const Finding,
};

/// Reads painted plain text and compares it with the declared graph. What a
/// clipped grid loses is not held against it; what it fabricates is.
pub fn judge(arena: std.mem.Allocator, declared: Declared, text: []const u8) !Judgement {
    var scan = try grid.scan(arena, text);
    var unknown: std.ArrayList([]const u8) = .empty;
    var mangled: std.ArrayList([]const u8) = .empty;
    const names = try arena.alloc([]const u8, scan.boxes.len);
    for (scan.boxes, names) |box, *name| {
        const found = try resolve(arena, declared.labels, box) orelse {
            name.* = try key(arena, box);
            if (std.mem.endsWith(u8, name.*, ellipsis)) {
                name.* = try std.fmt.allocPrint(arena, "{s}{d}", .{ hidden, @intFromPtr(box.ptr) });
            } else try unknown.append(arena, box);
            continue;
        };
        if (!found.whole) try mangled.append(arena, box);
        name.* = found.key;
    }
    var missing: std.ArrayList([]const u8) = .empty;
    const used = try arena.alloc(bool, names.len);
    @memset(used, false);
    next_label: for (declared.labels) |label| {
        const k = try key(arena, label);
        for (names, used) |n, *u| if (!u.* and std.mem.eql(u8, n, k)) {
            u.* = true;
            continue :next_label;
        };
        try missing.append(arena, label);
    }

    const ends = try arena.alloc(Endpoint, scan.terminals.len);
    for (scan.terminals, ends) |t, *e| e.* = if (t.target.frame)
        .{ .label = try key(arena, scan.frames[t.target.index]), .frame = true }
    else
        .{ .label = names[t.target.index] };
    const want = try arena.alloc(Relation, declared.edges.len);
    for (declared.edges, want) |d, *w| {
        w.* = d;
        w.a.label = try key(arena, d.a.label);
        w.b.label = try key(arena, d.b.label);
    }
    const traced = try trace.trace(arena, &scan, ends, want);

    var fabricated: std.ArrayList(Relation) = .empty;
    var lost: std.ArrayList(Relation) = .empty;
    const matched = try arena.alloc(bool, want.len);
    @memset(matched, false);
    next_relation: for (traced) |r| {
        if (std.mem.startsWith(u8, r.a.label, hidden) or std.mem.startsWith(u8, r.b.label, hidden)) continue;
        for (want, matched) |w, *m| if (!m.* and same(r, w)) {
            m.* = true;
            continue :next_relation;
        };
        try fabricated.append(arena, r);
    }
    for (want, matched) |w, m| if (!m) try lost.append(arena, w);

    const clipped = scan.clipped;
    var unreadable = false;
    var broken = mangled.items.len > 0;
    for (scan.findings.items) |f| switch (f.kind) {
        .unknown_glyph => unreadable = unreadable or !clipped,
        .dangling_arm, .loose_ink => broken = broken or !clipped,
        else => broken = true,
    };
    if (clipped) {
        lost.clearRetainingCapacity();
        missing.clearRetainingCapacity();
    }
    const lies = broken or fabricated.items.len + lost.items.len + missing.items.len > 0;
    return .{
        .verdict = if (unknown.items.len > 0 or unreadable) .undecodable else if (lies) .lying else .faithful,
        .clipped = clipped,
        .fabricated = fabricated.items,
        .lost = lost.items,
        .unknown_boxes = unknown.items,
        .mangled_boxes = mangled.items,
        .missing_nodes = missing.items,
        .findings = scan.findings.items,
    };
}

fn same(r: Relation, w: Relation) bool {
    const strokes = r.stroke == .any or r.stroke == w.stroke;
    return strokes and ((sameEnd(r.a, r.end_a, w.a, w.end_a) and sameEnd(r.b, r.end_b, w.b, w.end_b)) or
        (sameEnd(r.a, r.end_a, w.b, w.end_b) and sameEnd(r.b, r.end_b, w.a, w.end_a)));
}

fn sameEnd(x: Endpoint, xe: End, y: Endpoint, ye: End) bool {
    return x.frame == y.frame and xe == ye and std.mem.eql(u8, x.label, y.label);
}

const ellipsis = "…";

// Names a box the clip cut before its text could say which node it is.
const hidden = "\x00cut";

const Named = struct { key: []const u8, whole: bool };

// The declared node a box's text names. A box cut short with an ellipsis
// names the one label it begins, or none the clip lets it show; an uncut box whose lines are pieces
// of one label, in order, names it but not whole; pieces of several labels
// name no node, and say so.
fn resolve(arena: std.mem.Allocator, labels: []const []const u8, text: []const u8) !?Named {
    const k = try key(arena, text);
    const cut = std.mem.endsWith(u8, k, ellipsis);
    const stem = if (cut) k[0 .. k.len - ellipsis.len] else k;
    if (try unique(arena, labels, stem, if (cut) .prefix else .whole)) |found| return .{ .key = found, .whole = true };
    if (cut or stem.len == 0) return null;
    var found: ?[]const u8 = null;
    for (labels) |l| {
        const lk = try key(arena, l);
        if (!try inParts(arena, lk, text)) continue;
        if (found) |f| if (!std.mem.eql(u8, f, lk)) return .{ .key = k, .whole = false };
        found = lk;
    }
    return .{ .key = found orelse return null, .whole = false };
}

// Whether each line of `text` appears in `label`, in order.
fn inParts(arena: std.mem.Allocator, label: []const u8, text: []const u8) !bool {
    var at: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var part = try key(arena, line);
        if (std.mem.endsWith(u8, part, ellipsis)) part = part[0 .. part.len - ellipsis.len];
        if (part.len == 0) continue;
        at = (std.mem.indexOfPos(u8, label, at, part) orelse return false) + part.len;
    }
    return true;
}

fn unique(arena: std.mem.Allocator, labels: []const []const u8, stem: []const u8, how: enum { whole, prefix }) !?[]const u8 {
    var found: ?[]const u8 = null;
    for (labels) |l| {
        const lk = try key(arena, l);
        const hit = switch (how) {
            .whole => std.mem.eql(u8, lk, stem),
            .prefix => std.mem.startsWith(u8, lk, stem),
        };
        if (!hit) continue;
        if (found) |f| if (!std.mem.eql(u8, f, lk)) return null;
        found = lk;
    }
    return found;
}

/// A label with its line breaks and spacing removed, so wrapped text and the
/// source spelling compare equal.
pub fn key(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (breakTag(text[i..])) |n| {
            i += n;
            continue;
        }
        if (std.ascii.isWhitespace(text[i])) {
            i += 1;
            continue;
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}

fn breakTag(text: []const u8) ?usize {
    for ([_][]const u8{ "<br>", "<br/>", "<br />" }) |tag| {
        if (text.len >= tag.len and std.ascii.eqlIgnoreCase(text[0..tag.len], tag)) return tag.len;
    }
    return null;
}
