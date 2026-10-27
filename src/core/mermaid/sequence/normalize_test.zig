const std = @import("std");
const parse = @import("parse.zig");
const normalize = @import("normalize.zig");
const seq = @import("seq.zig");

const testing = std.testing;

fn withSequence(source: []const u8, check: fn (*const seq.Sequence) anyerror!void) !void {
    var diagram = try parse.parse(testing.allocator, source);
    defer diagram.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try normalize.normalize(arena.allocator(), &diagram);
    try check(&s);
}

fn expectBar(want: seq.Bar, got: seq.Bar) !void {
    try testing.expectEqual(want.part, got.part);
    try testing.expectEqual(want.first, got.first);
    try testing.expectEqual(want.last, got.last);
    try testing.expectEqual(want.depth, got.depth);
    try testing.expectEqual(want.joined, got.joined);
}

test "an activation starts at the message after which the source declares it and ends at the message before its deactivate" {
    try withSequence(
        \\sequenceDiagram
        \\    A->>B: one
        \\    activate B
        \\    B->>C: two
        \\    C-->>B: three
        \\    deactivate B
        \\    B-->>A: four
    , struct {
        fn check(s: *const seq.Sequence) !void {
            try testing.expectEqual(@as(usize, 1), s.bars.len);
            try expectBar(seq.Bar{ .part = 1, .first = 0, .last = 2, .depth = 1 }, s.bars[0]);
        }
    }.check);
}

test "the plus shorthand activates its own message; nested bars of one participant rank by depth" {
    try withSequence(
        \\sequenceDiagram
        \\    C->>+S: request
        \\    S->>+S: validate
        \\    S-->>-S: valid
        \\    S-->>-C: response
    , struct {
        fn check(s: *const seq.Sequence) !void {
            try testing.expectEqual(@as(usize, 2), s.bars.len);
            try expectBar(seq.Bar{ .part = 1, .first = 0, .last = 3, .depth = 1 }, s.bars[0]);
            try expectBar(seq.Bar{ .part = 1, .first = 1, .last = 2, .depth = 2 }, s.bars[1]);
            try testing.expect(s.steps[1].isSelf());
        }
    }.check);
}

test "an unmatched deactivate is ignored and an unclosed bar ends at the last step" {
    try withSequence(
        \\sequenceDiagram
        \\    A->>B: one
        \\    deactivate A
        \\    activate B
        \\    B->>A: two
        \\    Note over A: end
    , struct {
        fn check(s: *const seq.Sequence) !void {
            try testing.expectEqual(@as(usize, 1), s.bars.len);
            try expectBar(seq.Bar{ .part = 1, .first = 0, .last = 2, .depth = 1 }, s.bars[0]);
        }
    }.check);
}

test "a fragment spans exactly the participants its messages touch, nested fragments included" {
    try withSequence(
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    participant D
        \\    A->>B: start
        \\    loop outer
        \\        B->>B: think
        \\        alt inner
        \\            B->>C: lock
        \\        else other
        \\            C-->>B: locked
        \\        end
        \\    end
        \\    B->>D: done
    , struct {
        fn check(s: *const seq.Sequence) !void {
            try testing.expectEqual(@as(usize, 2), s.frags.len);
            try testing.expectEqual(@as(seq.PartIx, 1), s.frags[0].lo);
            try testing.expectEqual(@as(seq.PartIx, 2), s.frags[0].hi);
            try testing.expectEqual(@as(?seq.FragIx, 0), s.frags[1].parent);
            try testing.expectEqual(@as(usize, 2), s.frags[1].operands.len);
            try testing.expectEqualStrings("[other]", s.texts[s.frags[1].operands[1].guard.?]);
            const tags = [_]std.meta.Tag(seq.Item){ .step, .open, .step, .open, .step, .divider, .step, .close, .close, .step };
            try testing.expectEqual(tags.len, s.items.len);
            for (tags, s.items) |tag, item| try testing.expectEqual(tag, std.meta.activeTag(item));
            try testing.expect(s.hasTopDownOnly());
        }
    }.check);
}
