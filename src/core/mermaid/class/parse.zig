const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const Scanner = @import("../scan.zig").Scanner;
const ClassDiagram = model.ClassDiagram;
const Class = model.Class;
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
            const name_start = s.pos;
            while (!s.isAtEnd() and s.isIdChar(s.current())) {
                s.advance();
            }
            const class_name = s.source[name_start..s.pos];
            if (class_name.len > 0) {
                const result = try diagram.classes.getOrPut(class_name);
                if (!result.found_existing) {
                    result.value_ptr.* = Class.init(s.allocator, class_name);
                    try diagram.class_order.append(s.allocator, class_name);
                }
            }
            s.skipToNextLine();
            continue;
        }

        const parsed = try parseClassStatement(s, &diagram);
        if (!parsed) {
            s.skipToNextLine();
        }
    }

    return diagram;
}

fn parseClassStatement(s: *Scanner, diagram: *ClassDiagram) !bool {
    const start_pos = s.pos;

    const first_name = parseClassName(s);
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

    const rel_type = parseClassRelation(s);
    if (rel_type) |relation_type| {
        s.skipWhitespace();

        const second_name = parseClassName(s);
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

        try ensureClass(s, diagram, first_name);
        try ensureClass(s, diagram, second_name);

        try diagram.addRelation(.{
            .from = first_name,
            .to = second_name,
            .relation_type = relation_type,
            .label = label,
        });

        s.skipToNextLine();
        return true;
    }

    s.pos = start_pos;
    return false;
}

fn parseClassName(s: *Scanner) []const u8 {
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
    try ensureClass(s, diagram, class_name);

    const class = diagram.getClassMut(class_name) orelse return;

    var visibility: Visibility = .none;
    const first_char = s.current();
    if (first_char == '+' or first_char == '-' or first_char == '#' or first_char == '~') {
        visibility = Visibility.fromChar(first_char);
        s.advance();
    }

    const member_start = s.pos;
    while (!s.isAtEnd() and s.current() != '\n') {
        s.advance();
    }
    const member_text = std.mem.trimRight(u8, s.source[member_start..s.pos], " \t\r");

    if (member_text.len == 0) return;

    const is_method = std.mem.indexOf(u8, member_text, "(") != null;

    var member_type: []const u8 = "";
    var name: []const u8 = member_text;

    if (std.mem.indexOf(u8, member_text, " ")) |space_idx| {
        if (!is_method) {
            member_type = member_text[0..space_idx];
            name = member_text[space_idx + 1 ..];
        }
    }

    try class.addMember(.{
        .name = name,
        .member_type = member_type,
        .visibility = visibility,
        .is_method = is_method,
    });

    s.skipToNextLine();
}

fn ensureClass(s: *Scanner, diagram: *ClassDiagram, name: []const u8) !void {
    const result = try diagram.classes.getOrPut(name);
    if (!result.found_existing) {
        result.value_ptr.* = Class.init(s.allocator, name);
        try diagram.class_order.append(s.allocator, name);
    }
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
