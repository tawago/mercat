//! Colour facts read from `classDef`, `class`, `:::`, `style` and `linkStyle`, resolved once the
//! whole source is read: mermaid lets a class be used before it is defined.

const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");

const Rgb = prim.Rgb;

/// The `stroke` property of a style text, as `#rgb` or `#rrggbb`; null otherwise.
pub fn strokeOf(text: []const u8) ?Rgb {
    var found: ?Rgb = null;
    var props = std.mem.splitScalar(u8, text, ',');
    while (props.next()) |prop| {
        const colon = std.mem.indexOfScalar(u8, prop, ':') orelse continue;
        const key = std.mem.trim(u8, prop[0..colon], " \t\r");
        if (!std.mem.eql(u8, key, "stroke")) continue;
        found = hex(withoutImportant(std.mem.trim(u8, prop[colon + 1 ..], " \t\r;")));
    }
    return found;
}

fn withoutImportant(value: []const u8) []const u8 {
    const flag = "!important";
    if (!std.mem.endsWith(u8, value, flag)) return value;
    return std.mem.trimEnd(u8, value[0 .. value.len - flag.len], " \t");
}

fn hex(value: []const u8) ?Rgb {
    if (value.len < 1 or value[0] != '#') return null;
    return Rgb.fromHex(value[1..]);
}

/// A `linkStyle` text without its leading `interpolate <curve>`.
pub fn linkProps(text: []const u8) []const u8 {
    const rest = std.mem.trimStart(u8, text, " \t");
    const word = "interpolate";
    if (!std.mem.startsWith(u8, rest, word)) return text;
    const after = rest[word.len..];
    if (after.len == 0 or (after[0] != ' ' and after[0] != '\t')) return text;
    const curve = std.mem.trimStart(u8, after, " \t");
    const end = std.mem.indexOfAny(u8, curve, " \t") orelse curve.len;
    return curve[end..];
}

pub const LinkTarget = union(enum) { default, index: u32 };

const Attach = struct { node: []const u8, class: []const u8 };
const NodeStroke = struct { node: []const u8, rgb: Rgb };
const LinkStroke = struct { target: LinkTarget, rgb: Rgb };

pub const Styles = struct {
    classes: std.StringHashMapUnmanaged(?Rgb) = .empty,
    attached: std.ArrayList(Attach) = .empty,
    node_strokes: std.ArrayList(NodeStroke) = .empty,
    links: std.ArrayList(LinkStroke) = .empty,

    pub fn defineClass(s: *Styles, a: std.mem.Allocator, name: []const u8, stroke: ?Rgb) error{OutOfMemory}!void {
        try s.classes.put(a, name, stroke orelse s.strokeOfClass(name));
    }

    pub fn attach(s: *Styles, a: std.mem.Allocator, node: []const u8, class: []const u8) error{OutOfMemory}!void {
        try s.attached.append(a, .{ .node = node, .class = class });
    }

    pub fn styleNode(s: *Styles, a: std.mem.Allocator, node: []const u8, stroke: ?Rgb) error{OutOfMemory}!void {
        if (stroke) |rgb| try s.node_strokes.append(a, .{ .node = node, .rgb = rgb });
    }

    pub fn styleLink(s: *Styles, a: std.mem.Allocator, target: LinkTarget, stroke: ?Rgb) error{OutOfMemory}!void {
        if (stroke) |rgb| try s.links.append(a, .{ .target = target, .rgb = rgb });
    }

    /// Sets each node's outline as mermaid layers it: `classDef default`, then `classDef node`,
    /// then each attached class in order, then the node's own `style`; the last stroke wins.
    pub fn resolveNodes(s: *const Styles, nodes: []sg.Node) void {
        const base = s.strokeOfClass("node") orelse s.strokeOfClass("default");
        for (nodes) |*n| {
            var outline: ?Rgb = base;
            for (s.attached.items) |at| {
                if (!std.mem.eql(u8, at.node, n.raw_id)) continue;
                if (s.strokeOfClass(at.class)) |rgb| outline = rgb;
            }
            for (s.node_strokes.items) |ns| {
                if (std.mem.eql(u8, ns.node, n.raw_id)) outline = ns.rgb;
            }
            n.outline = outline;
        }
    }

    fn strokeOfClass(s: *const Styles, name: []const u8) ?Rgb {
        return s.classes.get(name) orelse null;
    }

    /// One colour per declared edge: its last `linkStyle` stroke, else `linkStyle default`. Empty
    /// when no `linkStyle` gave a stroke.
    pub fn resolveEdges(s: *const Styles, a: std.mem.Allocator, edge_count: usize) error{OutOfMemory}![]const ?Rgb {
        if (s.links.items.len == 0 or edge_count == 0) return &.{};
        const out = try a.alloc(?Rgb, edge_count);
        @memset(out, null);
        for (s.links.items) |l| if (l.target == .default) @memset(out, l.rgb);
        for (s.links.items) |l| switch (l.target) {
            .default => {},
            .index => |i| if (i < edge_count) {
                out[i] = l.rgb;
            },
        };
        return out;
    }
};

test {
    _ = @import("style_test.zig");
}
