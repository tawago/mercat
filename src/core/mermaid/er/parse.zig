const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const Scanner = @import("../scan.zig").Scanner;
const ERDiagram = model.ERDiagram;
const Entity = model.Entity;
const Cardinality = model.Cardinality;

const ERRelationResult = struct {
    left: Cardinality,
    right: Cardinality,
};

pub fn parse(allocator: Allocator, source: []const u8) !ERDiagram {
    var s = Scanner.init(allocator, source);
    return parseERDiagramInternal(&s);
}

fn parseERDiagramInternal(s: *Scanner) !ERDiagram {
    var diagram = ERDiagram.init(s.allocator);
    errdefer diagram.deinit();

    s.skipWhitespaceAndComments();

    _ = s.consumeKeyword("erDiagram");
    s.skipToNextLine();

    while (!s.isAtEnd()) {
        s.skipWhitespaceAndComments();
        if (s.isAtEnd()) break;

        const parsed = try parseERStatement(s, &diagram);
        if (!parsed) {
            s.skipToNextLine();
        }
    }

    return diagram;
}

fn parseERStatement(s: *Scanner, diagram: *ERDiagram) !bool {
    const start_pos = s.pos;

    const first_name = parseEntityName(s);
    if (first_name.len == 0) {
        s.pos = start_pos;
        return false;
    }

    s.skipWhitespace();

    const rel = parseERRelation(s);
    if (rel) |relation| {
        s.skipWhitespace();

        const second_name = parseEntityName(s);
        if (second_name.len == 0) {
            s.pos = start_pos;
            return false;
        }

        s.skipWhitespace();
        var label: ?[]const u8 = null;
        if (s.matchChar(':')) {
            s.skipWhitespace();
            const label_start = s.pos;
            while (!s.isAtEnd() and s.current() != '\n') {
                s.advance();
            }
            label = std.mem.trimRight(u8, s.source[label_start..s.pos], " \t\r");
        }

        try ensureEntity(s, diagram, first_name);
        try ensureEntity(s, diagram, second_name);

        try diagram.addRelation(.{
            .from = first_name,
            .to = second_name,
            .from_cardinality = relation.left,
            .to_cardinality = relation.right,
            .label = label,
        });

        s.skipToNextLine();
        return true;
    }

    if (first_name.len > 0) {
        try ensureEntity(s, diagram, first_name);
        s.skipToNextLine();
        return true;
    }

    s.pos = start_pos;
    return false;
}

fn parseEntityName(s: *Scanner) []const u8 {
    const start = s.pos;
    while (!s.isAtEnd()) {
        const c = s.current();
        if (s.isIdChar(c) or c == '-') {
            s.advance();
        } else {
            break;
        }
    }
    return s.source[start..s.pos];
}

fn parseERRelation(s: *Scanner) ?ERRelationResult {
    var left: Cardinality = .exactly_one;
    var right: Cardinality = .exactly_one;

    if (s.matchString("||")) {
        left = .exactly_one;
    } else if (s.matchString("|o")) {
        left = .zero_or_one;
    } else if (s.matchString("}|")) {
        left = .one_or_more;
    } else if (s.matchString("}o")) {
        left = .zero_or_more;
    } else {
        return null;
    }

    if (!s.matchString("--") and !s.matchString("..")) {
        return null;
    }

    if (s.matchString("||")) {
        right = .exactly_one;
    } else if (s.matchString("o|")) {
        right = .zero_or_one;
    } else if (s.matchString("|{")) {
        right = .one_or_more;
    } else if (s.matchString("o{")) {
        right = .zero_or_more;
    } else {
        return null;
    }

    return .{
        .left = left,
        .right = right,
    };
}

fn ensureEntity(s: *Scanner, diagram: *ERDiagram, name: []const u8) !void {
    const result = try diagram.entities.getOrPut(name);
    if (!result.found_existing) {
        result.value_ptr.* = Entity.init(s.allocator, name);
        try diagram.entity_order.append(s.allocator, name);
    }
}

test "parse simple ER diagram" {
    const testing = std.testing;

    const source =
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
        \\    ORDER ||--|{ LINE-ITEM : contains
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 3), diagram.entity_order.items.len);
    try testing.expectEqual(@as(usize, 2), diagram.relations.items.len);

    try testing.expect(diagram.getEntity("CUSTOMER") != null);
    try testing.expect(diagram.getEntity("ORDER") != null);
    try testing.expect(diagram.getEntity("LINE-ITEM") != null);

    const rel1 = diagram.relations.items[0];
    try testing.expectEqualStrings("CUSTOMER", rel1.from);
    try testing.expectEqualStrings("ORDER", rel1.to);
    try testing.expectEqual(Cardinality.exactly_one, rel1.from_cardinality);
    try testing.expectEqual(Cardinality.zero_or_more, rel1.to_cardinality);
    try testing.expectEqualStrings("places", rel1.label.?);

    const rel2 = diagram.relations.items[1];
    try testing.expectEqualStrings("ORDER", rel2.from);
    try testing.expectEqualStrings("LINE-ITEM", rel2.to);
    try testing.expectEqual(Cardinality.exactly_one, rel2.from_cardinality);
    try testing.expectEqual(Cardinality.one_or_more, rel2.to_cardinality);
}
