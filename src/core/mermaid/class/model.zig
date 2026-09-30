const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Visibility = enum {
    public,
    private,
    protected,
    package,
    none,

    pub fn toChar(self: Visibility) ?u8 {
        return switch (self) {
            .public => '+',
            .private => '-',
            .protected => '#',
            .package => '~',
            .none => null,
        };
    }

    pub fn fromChar(c: u8) Visibility {
        return switch (c) {
            '+' => .public,
            '-' => .private,
            '#' => .protected,
            '~' => .package,
            else => .none,
        };
    }
};

pub const ClassMember = struct {
    name: []const u8,
    visibility: Visibility = .none,
    is_method: bool = false,
};

pub const ClassRelationType = enum {
    inheritance,
    composition,
    aggregation,
    association,
    dependency,
    realization,
    link,

    pub fn endMarker(self: ClassRelationType) []const u8 {
        return switch (self) {
            .inheritance, .realization => "◁",
            .association, .dependency => "▶",
            .composition, .aggregation, .link => "",
        };
    }
};

pub const Class = struct {
    name: []const u8,
    members: std.ArrayList(ClassMember),
    allocator: Allocator,
    x: ?i32 = null,
    y: ?i32 = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(allocator: Allocator, name: []const u8) Class {
        return .{
            .name = name,
            .members = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Class) void {
        self.members.deinit(self.allocator);
    }

    pub fn addMember(self: *Class, member: ClassMember) !void {
        try self.members.append(self.allocator, member);
    }
};

pub const ClassRelation = struct {
    from: []const u8,
    to: []const u8,
    relation_type: ClassRelationType = .association,
};

pub const ClassDiagram = struct {
    allocator: Allocator,
    classes: std.StringHashMap(Class),
    relations: std.ArrayList(ClassRelation),
    class_order: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) ClassDiagram {
        return .{
            .allocator = allocator,
            .classes = std.StringHashMap(Class).init(allocator),
            .relations = .empty,
            .class_order = .empty,
        };
    }

    pub fn deinit(self: *ClassDiagram) void {
        var it = self.classes.valueIterator();
        while (it.next()) |class| {
            @constCast(class).deinit();
        }
        self.classes.deinit();
        self.relations.deinit(self.allocator);
        self.class_order.deinit(self.allocator);
    }

    pub fn getClass(self: *const ClassDiagram, name: []const u8) ?*const Class {
        return self.classes.getPtr(name);
    }

    pub fn getClassMut(self: *ClassDiagram, name: []const u8) ?*Class {
        return self.classes.getPtr(name);
    }

    /// Register a class by name, leaving an existing one untouched.
    pub fn ensureClass(self: *ClassDiagram, name: []const u8) !void {
        const result = try self.classes.getOrPut(name);
        if (!result.found_existing) {
            result.value_ptr.* = Class.init(self.allocator, name);
            try self.class_order.append(self.allocator, name);
        }
    }

    pub fn addRelation(self: *ClassDiagram, relation: ClassRelation) !void {
        try self.relations.append(self.allocator, relation);
    }
};
