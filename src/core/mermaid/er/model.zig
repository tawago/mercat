const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Cardinality = enum {
    zero_or_one,
    exactly_one,
    zero_or_more,
    one_or_more,

    pub fn toStringLeft(self: Cardinality, unicode_mode: bool) []const u8 {
        _ = unicode_mode;
        return switch (self) {
            .zero_or_one => "o|",
            .exactly_one => "||",
            .zero_or_more => "}o",
            .one_or_more => "}|",
        };
    }

    pub fn toStringRight(self: Cardinality, unicode_mode: bool) []const u8 {
        _ = unicode_mode;
        return switch (self) {
            .zero_or_one => "|o",
            .exactly_one => "||",
            .zero_or_more => "o{",
            .one_or_more => "|{",
        };
    }
};

pub const Entity = struct {
    name: []const u8,
    attributes: std.ArrayList(EntityAttribute),
    allocator: Allocator,
    x: ?i32 = null,
    y: ?i32 = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(allocator: Allocator, name: []const u8) Entity {
        return .{
            .name = name,
            .attributes = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Entity) void {
        self.attributes.deinit(self.allocator);
    }
};

pub const EntityAttribute = struct {
    name: []const u8,
    attr_type: []const u8,
    is_primary_key: bool = false,
    is_foreign_key: bool = false,
};

pub const ERRelation = struct {
    from: []const u8,
    to: []const u8,
    from_cardinality: Cardinality = .exactly_one,
    to_cardinality: Cardinality = .exactly_one,
    label: ?[]const u8 = null,
};

pub const ERDiagram = struct {
    allocator: Allocator,
    entities: std.StringHashMap(Entity),
    relations: std.ArrayList(ERRelation),
    entity_order: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) ERDiagram {
        return .{
            .allocator = allocator,
            .entities = std.StringHashMap(Entity).init(allocator),
            .relations = .empty,
            .entity_order = .empty,
        };
    }

    pub fn deinit(self: *ERDiagram) void {
        var it = self.entities.valueIterator();
        while (it.next()) |entity| {
            @constCast(entity).deinit();
        }
        self.entities.deinit();
        self.relations.deinit(self.allocator);
        self.entity_order.deinit(self.allocator);
    }

    pub fn getEntity(self: *const ERDiagram, name: []const u8) ?*const Entity {
        return self.entities.getPtr(name);
    }

    pub fn getEntityMut(self: *ERDiagram, name: []const u8) ?*Entity {
        return self.entities.getPtr(name);
    }

    pub fn addRelation(self: *ERDiagram, relation: ERRelation) !void {
        try self.relations.append(self.allocator, relation);
    }
};
