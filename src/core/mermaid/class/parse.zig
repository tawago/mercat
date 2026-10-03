const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const Scanner = @import("../scan.zig").Scanner;
const ClassDiagram = model.ClassDiagram;
const ClassRelationType = model.ClassRelationType;
const Visibility = model.Visibility;

pub fn parse(allocator: Allocator, source: []const u8) !ClassDiagram {
    var s = Scanner.init(allocator, source);
    return parseClassDiagramInternal(&s);
}

fn parseClassDiagramInternal(s: *Scanner) !ClassDiagram {
    var diagram = ClassDiagram.init(s.allocator);
    errdefer diagram.deinit();

    s.skipWhitespaceAndComments();

    _ = s.consumeKeyword("classDiagram");
    s.skipToNextLine();

    while (!s.isAtEnd()) {
        s.skipWhitespaceAndComments();
        if (s.isAtEnd()) break;

        if (s.consumeKeyword("direction") or
            s.consumeKeyword("note") or
            s.consumeKeyword("callback") or
            s.consumeKeyword("link") or
            s.consumeKeyword("cssClass"))
        {
            s.skipToNextLine();
            continue;
        }

        if (s.consumeKeyword("class")) {
            s.skipWhitespace();
            const class_name = s.identifier();
            if (class_name.len > 0) {
                try diagram.ensureClass(class_name);
            }
            s.skipToNextLine();
            continue;
        }

        if (!try parseClassStatement(s, &diagram)) {
            s.skipToNextLine();
        }
    }

    return diagram;
}

fn parseClassStatement(s: *Scanner, diagram: *ClassDiagram) !bool {
    const start_pos = s.pos;

    const first_name = s.name();
    if (first_name.len == 0) {
        s.pos = start_pos;
        return false;
    }

    s.skipWhitespace();

    if (s.matchChar(':')) {
        s.skipWhitespace();
        try parseClassMember(s, diagram, first_name);
        return true;
    }

    if (parseClassRelation(s)) |relation_type| {
        s.skipWhitespace();

        const second_name = s.name();
        if (second_name.len == 0) {
            s.pos = start_pos;
            return false;
        }

        try diagram.ensureClass(first_name);
        try diagram.ensureClass(second_name);

        try diagram.addRelation(.{
            .from = first_name,
            .to = second_name,
            .relation_type = relation_type,
        });

        s.skipToNextLine();
        return true;
    }

    s.pos = start_pos;
    return false;
}

fn parseClassRelation(s: *Scanner) ?ClassRelationType {
    if (s.matchString("<|--")) return .inheritance;
    if (s.matchString("--|>")) return .inheritance;
    if (s.matchString("..|>")) return .realization;
    if (s.matchString("<|..")) return .realization;
    if (s.matchString("*--")) return .composition;
    if (s.matchString("--*")) return .composition;
    if (s.matchString("o--")) return .aggregation;
    if (s.matchString("--o")) return .aggregation;
    if (s.matchString("..>")) return .dependency;
    if (s.matchString("<..")) return .dependency;
    if (s.matchString("-->")) return .association;
    if (s.matchString("<--")) return .association;
    if (s.matchString("--")) return .link;
    if (s.matchString("..")) return .dependency;

    return null;
}

fn parseClassMember(s: *Scanner, diagram: *ClassDiagram, class_name: []const u8) !void {
    try diagram.ensureClass(class_name);

    const class = diagram.getClassMut(class_name) orelse return;

    const visibility = Visibility.fromChar(s.current());
    if (visibility != .none) s.advance();

    const member_text = s.restOfLine();
    if (member_text.len == 0) return;

    const is_method = std.mem.indexOfScalar(u8, member_text, '(') != null;

    var name: []const u8 = member_text;

    if (std.mem.indexOfScalar(u8, member_text, ' ')) |space_idx| {
        if (!is_method) name = member_text[space_idx + 1 ..];
    }

    try class.addMember(.{
        .name = name,
        .visibility = visibility,
        .is_method = is_method,
    });

    s.skipToNextLine();
}

test "parse simple class diagram" {
    const testing = std.testing;

    const source =
        \\classDiagram
        \\    Animal <|-- Duck
        \\    Animal : +int age
        \\    Animal : +String gender
        \\    Duck : +swim()
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 2), diagram.class_order.items.len);
    try testing.expectEqual(@as(usize, 1), diagram.relations.items.len);

    try testing.expect(diagram.getClass("Animal") != null);
    try testing.expect(diagram.getClass("Duck") != null);

    const rel = diagram.relations.items[0];
    try testing.expectEqualStrings("Animal", rel.from);
    try testing.expectEqualStrings("Duck", rel.to);
    try testing.expectEqual(ClassRelationType.inheritance, rel.relation_type);

    const animal = diagram.getClass("Animal").?;
    try testing.expectEqual(@as(usize, 2), animal.members.items.len);

    const duck = diagram.getClass("Duck").?;
    try testing.expectEqual(@as(usize, 1), duck.members.items.len);
    try testing.expect(duck.members.items[0].is_method);
}

test "parse class diagram with various relations" {
    const testing = std.testing;

    const source =
        \\classDiagram
        \\    A <|-- B
        \\    C *-- D
        \\    E o-- F
        \\    G --> H
    ;

    var diagram = try parse(testing.allocator, source);
    defer diagram.deinit();

    try testing.expectEqual(@as(usize, 4), diagram.relations.items.len);
    try testing.expectEqual(ClassRelationType.inheritance, diagram.relations.items[0].relation_type);
    try testing.expectEqual(ClassRelationType.composition, diagram.relations.items[1].relation_type);
    try testing.expectEqual(ClassRelationType.aggregation, diagram.relations.items[2].relation_type);
    try testing.expectEqual(ClassRelationType.association, diagram.relations.items[3].relation_type);
}
