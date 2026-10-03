const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const Scanner = @import("../scan.zig").Scanner;
const ERDiagram = model.ERDiagram;
const Cardinality = model.Cardinality;

const Notation = struct { []const u8, Cardinality };

const left_notations = [_]Notation{
    .{ "||", .exactly_one },
    .{ "|o", .zero_or_one },
    .{ "}|", .one_or_more },
    .{ "}o", .zero_or_more },
};

const right_notations = [_]Notation{
    .{ "||", .exactly_one },
    .{ "o|", .zero_or_one },
    .{ "|{", .one_or_more },
    .{ "o{", .zero_or_more },
};

const Ends = struct {
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

        if (!try parseERStatement(s, &diagram)) {
            s.skipToNextLine();
        }
    }

    return diagram;
}

fn parseERStatement(s: *Scanner, diagram: *ERDiagram) !bool {
    const start_pos = s.pos;

    const first_name = s.name();
    if (first_name.len == 0) {
        s.pos = start_pos;
        return false;
    }

    s.skipWhitespace();

    if (parseERRelation(s)) |relation| {
        s.skipWhitespace();

        const second_name = s.name();
        if (second_name.len == 0) {
            s.pos = start_pos;
            return false;
        }

        s.skipWhitespace();
        const label = s.labelAfterColon();

        try diagram.ensureEntity(first_name);
        try diagram.ensureEntity(second_name);

        try diagram.addRelation(.{
            .from = first_name,
            .to = second_name,
            .from_cardinality = relation.left,
            .to_cardinality = relation.right,
            .label = label,
        });
    } else {
        try diagram.ensureEntity(first_name);
    }

    s.skipToNextLine();
    return true;
}

fn parseERRelation(s: *Scanner) ?Ends {
    const left = matchNotation(s, &left_notations) orelse return null;

    if (!s.matchString("--") and !s.matchString("..")) {
        return null;
    }

    const right = matchNotation(s, &right_notations) orelse return null;

    return .{
        .left = left,
        .right = right,
    };
}

fn matchNotation(s: *Scanner, notations: []const Notation) ?Cardinality {
    for (notations) |notation| {
        if (s.matchString(notation[0])) return notation[1];
    }
    return null;
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
