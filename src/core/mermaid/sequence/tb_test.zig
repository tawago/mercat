const std = @import("std");
const fixture = @import("tb_fixture_test.zig");
const render = @import("render.zig");
const unicode = @import("unicode");

const testing = std.testing;
const at = fixture.at;

const pinned =
    \\  ╭─────────╮           ╭────────╮      ╭──────────╮
    \\  │ Browser │           │ Server │      │ Database │
    \\  ╰─────────╯           ╰────────╯      ╰──────────╯
    \\       ┆                     ┆                ┆
    \\       ┆   POST /login       ┆                ┆
    \\       ┆───────────────────►┌─┐               ┆
    \\       ┆                    │ │   find user   ┆
    \\       ┆                    │ │──────────────►┆
    \\       ┆                    │ │   user row    ┆
    \\       ┆                    │ │◄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┆
    \\       ┆                    │ │               ┆
    \\┌─ alt ─── [password ok] ─────────────────────────┐
    \\│      ┆   200 + token      │ │               ┆   │
    \\│      ┆◄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄│ │               ┆   │
    \\│      ┆   hehe             │ │               ┆   │
    \\│     ┌─┐┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄►│ │               ┆   │
    \\│     │ │   hahaha          │ │               ┆   │
    \\│     │ │┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄►│ │               ┆   │
    \\│     └─┘                   │ │               ┆   │
    \\│      ┆   aaa              │ │               ┆   │
    \\│      ┆┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄│┄│┄┄┄┄┄┄┄┄┄┄┄┄┄┄►┆   │
    \\├┄┄┄┄┄┄┄┄┄ [bad password] ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┤
    \\│      ┆   401              │ │               ┆   │
    \\│      ┆◄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄│ │               ┆   │
    \\└─────────────────────────────────────────────────┘
    \\       ┆                    └─┘               ┆
    \\       ┆                     ┆                ┆
    \\
;

pub const wide_self_message =
    \\sequenceDiagram
    \\    participant P as Sender
    \\    participant API as Ingest endpoint
    \\    participant DB as DataStore
    \\    participant W as Worker
    \\    P->>API: Signed request
    \\    API->>API: Validate signature and size/schema limits
    \\    API->>DB: Transaction: dedupe + minimized record + event + task
    \\    API-->>P: Acknowledge
    \\    W->>DB: Lease task
    \\    W->>P: Fetch authoritative current value when needed
    \\    W->>DB: Commit normalized value + Domain event
;

const inner_span =
    \\sequenceDiagram
    \\    participant A
    \\    participant B
    \\    participant C
    \\    participant D
    \\    A->>B: start
    \\    critical only B and C
    \\        B->>C: lock
    \\        C-->>B: locked
    \\    end
    \\    B->>D: done
;

const every_kind =
    \\sequenceDiagram
    \\    A->B: solid line
    \\    A-->B: dashed line
    \\    A->>B: solid arrow
    \\    A-->>B: dashed arrow
    \\    A-xB: lost solid
    \\    A--xB: lost dashed
    \\    A-)B: async solid
    \\    A--)B: async dashed
;

const spaced_and_unspaced_names =
    \\sequenceDiagram
    \\    participant FE as Frontend Web Application
    \\    participant BE as BackendForFrontendService
    \\    participant DB as Primary Database Cluster
    \\    FE->>BE: fetch dashboard
    \\    BE->>DB: query widgets
    \\    DB-->>BE: rows
    \\    BE-->>FE: dashboard json
;

const one_wide_label =
    \\sequenceDiagram
    \\    participant U as User
    \\    participant API
    \\    U->>API: upload a very large file with a long descriptive message
    \\    API-->>U: done
;

const plain_wide =
    \\sequenceDiagram
    \\    participant Client
    \\    participant Gateway
    \\    participant Auth
    \\    participant Users
    \\    participant Billing
    \\    participant Audit
    \\    Client->>Gateway: request
    \\    Gateway->>Auth: verify
    \\    Billing->>Audit: log
;

const noted_wide =
    \\sequenceDiagram
    \\    participant Client
    \\    participant Gateway
    \\    participant Auth
    \\    participant Users
    \\    participant Billing
    \\    participant Audit
    \\    Client->>Gateway: request
    \\    Note over Auth: n
    \\    Billing->>Audit: log
;

const notes_on_a_busy_participant =
    \\sequenceDiagram
    \\    participant A
    \\    participant B
    \\    participant C
    \\    A->>+B: go
    \\    B->>B: think it over
    \\    Note over B: busy here
    \\    Note over A,B: both of them
    \\    Note over B,C: the other two
    \\    Note right of B: right
    \\    Note left of B: left
    \\    B-->>-A: back
;

const samples = [_][]const u8{ fixture.piercing_alternative(), wide_self_message, inner_span, every_kind, spaced_and_unspaced_names, one_wide_label, notes_on_a_busy_participant };

fn rowOf(rows: []const []const u8, needle: []const u8) ?usize {
    for (rows, 0..) |row, i| if (std.mem.indexOf(u8, row, needle) != null) return i;
    return null;
}

fn colOf(row: []const u8, needle: []const u8) usize {
    const byte = std.mem.indexOf(u8, row, needle).?;
    return unicode.displayWidth(row[0..byte]);
}

test "an alternative whose messages pierce an activation draws as pinned, and wider budgets do not stretch it" {
    for ([_]u32{ 80, 120 }) |width| {
        const text = try fixture.drawn(fixture.piercing_alternative(), width);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(pinned, text);
    }
}

test "order fidelity: steps read down in declared order" {
    const text = try fixture.drawn(fixture.piercing_alternative(), 80);
    defer testing.allocator.free(text);
    const rows = try fixture.lines(testing.allocator, text);
    defer testing.allocator.free(rows);
    var last: usize = 0;
    for ([_][]const u8{ "POST /login", "find user", "user row", "[password ok]", "200 + token", "hehe", "hahaha", "aaa", "[bad password]", "401" }) |label| {
        const row = rowOf(rows, label).?;
        try testing.expect(row > last);
        last = row;
    }
}

test "message passing an activation keeps its sides" {
    const text = try fixture.drawn(fixture.piercing_alternative(), 80);
    defer testing.allocator.free(text);
    const rows = try fixture.lines(testing.allocator, text);
    defer testing.allocator.free(rows);
    const label = rowOf(rows, "aaa").?;
    try testing.expect(std.mem.indexOf(u8, rows[label + 1], "│┄│") != null);
    try testing.expect(std.mem.indexOf(u8, rows[label + 1], "►┆") != null);
}

test "boundary piercing: a boundary keeps the lifeline and activation cells on its row, and they resume below" {
    const text = try fixture.drawn(fixture.piercing_alternative(), 80);
    defer testing.allocator.free(text);
    const rows = try fixture.lines(testing.allocator, text);
    defer testing.allocator.free(rows);
    const top = rowOf(rows, "alt").?;
    const divider = rowOf(rows, "[bad password]").?;
    const lifeline = colOf(rows[3], "┆");
    for ([_]usize{ top, divider }) |r| {
        try testing.expect(at(rows[r], lifeline) != '┆');
        try testing.expectEqual(@as(u21, '┆'), at(rows[r + 1], lifeline));
    }
    const wall = colOf(rows[top + 1], "│ │");
    try testing.expect(at(rows[top], wall) == '─');
    try testing.expectEqual(@as(u21, '│'), at(rows[top + 1], wall));
}

test "enclosure fidelity: a boundary covers exactly the participants its messages touch" {
    const text = try fixture.drawn(inner_span, 80);
    defer testing.allocator.free(text);
    const rows = try fixture.lines(testing.allocator, text);
    defer testing.allocator.free(rows);
    const top = rowOf(rows, "critical").?;
    const a = colOf(rows[1], "A");
    const b = colOf(rows[1], "B");
    const c = colOf(rows[1], "C");
    const d = colOf(rows[1], "D");
    const left = colOf(rows[top], "┌");
    const right = colOf(rows[top], "┐");
    try testing.expect(a < left and left < b);
    try testing.expect(c < right and right < d);
    try testing.expect(left > a + 1 and right + 1 < d);
    try testing.expectEqual(@as(u21, '┆'), at(rows[top], a));
    try testing.expectEqual(@as(u21, '┆'), at(rows[top], d));
}

test "nested boundary sits one cell inside its parent on every side" {
    var st = try fixture.stages(
        \\sequenceDiagram
        \\    participant C
        \\    participant S
        \\    critical every batch
        \\        alt room
        \\            C->>S: send
        \\        end
        \\    end
    , 3);
    defer st.deinit();
    const outer = st.layout.frames[0];
    const inner = st.layout.frames[1];
    try testing.expectEqual(outer.left + 1, inner.left);
    try testing.expectEqual(outer.right - 1, inner.right);
    try testing.expect(st.rows.frames[1].top > st.rows.frames[0].top);
    try testing.expect(st.rows.frames[1].bottom < st.rows.frames[0].bottom);
}

test "every message kind is distinguishable" {
    const text = try fixture.drawn(every_kind, 80);
    defer testing.allocator.free(text);
    const rows = try fixture.lines(testing.allocator, text);
    defer testing.allocator.free(rows);
    var strokes: [8][]const u8 = undefined;
    for ([_][]const u8{ "solid line", "dashed line", "solid arrow", "dashed arrow", "lost solid", "lost dashed", "async solid", "async dashed" }, 0..) |label, i| {
        strokes[i] = rows[rowOf(rows, label).? + 1];
    }
    for (strokes, 0..) |a, i| for (strokes[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
}

test "names never shortened: a long name breaks at spaces inside its box, a name with no space keeps its full width" {
    const need = (try fixture.fit(spaced_and_unspaced_names, 0)).too_wide;
    const text = try fixture.drawn(spaced_and_unspaced_names, need);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "BackendForFrontendService") != null);
    for ([_][]const u8{ "Frontend", "Web", "Application", "Primary", "Database", "Cluster" }) |word| {
        try testing.expect(std.mem.indexOf(u8, text, word) != null);
    }
    const wide = try fixture.drawn(spaced_and_unspaced_names, 200);
    defer testing.allocator.free(wide);
    try testing.expect(std.mem.indexOf(u8, wide, "Frontend Web Application") != null);
}

test "the comfort margin shrinks before any label breaks" {
    var st = try fixture.stages(one_wide_label, 1);
    defer st.deinit();
    const tight = st.layout.width;
    const text = try fixture.drawn(one_wide_label, tight);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "upload a very large file with a long descriptive message") != null);
    const broken = try fixture.drawn(one_wide_label, tight - 1);
    defer testing.allocator.free(broken);
    try testing.expect(std.mem.indexOf(u8, broken, "upload a very large file with a long descriptive message") == null);
    try testing.expect(std.mem.indexOf(u8, broken, "descriptive") != null);
}

test "the flip comes only after the top-down degradations, and never with activations, fragments or notes" {
    var plain = try fixture.stages(plain_wide, 1);
    defer plain.deinit();
    try testing.expect(plain.layout.width > 60);
    for (plain.s.texts, 0..) |_, t| try testing.expect(!plain.texts.canBreak(@intCast(t)));
    const flipped = try fixture.drawn(plain_wide, 60);
    defer testing.allocator.free(flipped);
    try testing.expect(std.mem.indexOf(u8, flipped, "┆") == null);
    try testing.expect(std.mem.indexOf(u8, flipped, "request") != null);

    var noted = try fixture.stages(noted_wide, 1);
    defer noted.deinit();
    try testing.expect(noted.layout.width > 60);
    try testing.expectEqual(noted.layout.width, (try fixture.fit(noted_wide, 60)).too_wide);
}

test "nothing is dropped at the narrowest drawing: every label word, name, kind and step stays" {
    const need = (try fixture.fit(wide_self_message, 0)).too_wide;
    const text = try fixture.drawn(wide_self_message, need);
    defer testing.allocator.free(text);
    for ([_][]const u8{ "Signed", "Validate", "signature", "size/schema", "limits", "Transaction:", "dedupe", "minimized", "record", "task", "Acknowledge", "Lease", "authoritative", "needed", "Commit", "normalized", "Domain", "event", "Sender", "Ingest", "endpoint", "DataStore", "Worker" }) |word| {
        try testing.expect(std.mem.indexOf(u8, text, word) != null);
    }
    try testing.expectEqual(@as(usize, 7), std.mem.count(u8, text, "►") + std.mem.count(u8, text, "◄"));
}

test "too_wide is exact and fitting is monotonic in the width" {
    for (samples) |source| {
        const need = (try fixture.fit(source, 0)).too_wide;
        try testing.expectEqual(need, (try fixture.fit(source, need - 1)).too_wide);
        var width = need;
        while (width < need + 30) : (width += 1) {
            const text = try fixture.drawn(source, width);
            defer testing.allocator.free(text);
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |line| try testing.expect(unicode.displayWidth(line) <= width);
        }
    }
}

test "no label lands on an activation, lifeline or boundary at any width: the ink overlay refuses it" {
    for (samples) |source| {
        const need = (try fixture.fit(source, 0)).too_wide;
        var width = need;
        while (width < need + 40) : (width += 1) {
            const text = try fixture.drawn(source, width);
            testing.allocator.free(text);
        }
    }
}

test "a note over participants covers their activations: a side sits on a busy lifeline, one column past a bare one" {
    const need = (try fixture.fit(notes_on_a_busy_participant, 0)).too_wide;
    var width = need;
    while (width < need + 20) : (width += 1) {
        const text = try fixture.drawn(notes_on_a_busy_participant, width);
        defer testing.allocator.free(text);
        const rows = try fixture.lines(testing.allocator, text);
        defer testing.allocator.free(rows);
        const a = colOf(rows[1], "A");
        const b = colOf(rows[1], "B");
        const c = colOf(rows[1], "C");
        var both = rowOf(rows, "both").?;
        while (at(rows[both], a - 1) != '┌') both -= 1;
        try testing.expectEqual(@as(u21, '┐'), at(rows[both], b));
        try testing.expectEqual(@as(u21, '│'), at(rows[both + 1], b + 1));
        var other = rowOf(rows, "other").?;
        while (at(rows[other], b) != '┌') other -= 1;
        try testing.expectEqual(@as(u21, '┐'), at(rows[other], c + 1));
        try testing.expectEqual(@as(u21, '│'), at(rows[other + 1], b - 1));
        for ([_][]const u8{ "busy", "here", "both", "them", "other", "two", "right", "left", "think", "over" }) |word| {
            try testing.expect(std.mem.indexOf(u8, text, word) != null);
        }
    }
}

test "a fragment top that follows a step gets one bare row above it" {
    const text = try fixture.drawn(fixture.piercing_alternative(), 80);
    defer testing.allocator.free(text);
    const rows = try fixture.lines(testing.allocator, text);
    defer testing.allocator.free(rows);
    const top = rowOf(rows, "┌─ alt").?;
    try testing.expect(std.mem.indexOf(u8, rows[top - 1], "┄") == null);
    try testing.expect(std.mem.indexOf(u8, rows[top - 2], "◄") != null);
}

test "a bar reopened right after it closes joins the old one at a shared cap row" {
    const text = try fixture.drawn(
        \\sequenceDiagram
        \\    A->>B: one
        \\    activate B
        \\    B->>A: two
        \\    deactivate B
        \\    activate B
        \\    A->>B: three
        \\    deactivate B
    , 80);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "├─┤") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "┌─┐"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "└─┘"));
}

test "a nested bar sits one column right of its parent and covers the parent's right side" {
    const text = try fixture.drawn(
        \\sequenceDiagram
        \\    C->>S: request
        \\    activate S
        \\    S->>S: validate
        \\    activate S
        \\    S-->>S: valid
        \\    deactivate S
        \\    S-->>C: response
        \\    deactivate S
    , 80);
    defer testing.allocator.free(text);
    const rows = try fixture.lines(testing.allocator, text);
    defer testing.allocator.free(rows);
    const top = rowOf(rows, "│┌─┐").?;
    try testing.expect(std.mem.indexOf(u8, rows[top - 1], "│ │◄─┘") != null);
    try testing.expect(std.mem.indexOf(u8, rows[top + 1], "││ │") != null);
    try testing.expect(rowOf(rows, "│└─┘") != null);
}

test "an empty fragment nested in another takes its parent's participants" {
    const text = try fixture.drawn(
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    participant D
        \\    A->>B: x
        \\    loop outer
        \\        C->>D: y
        \\        opt empty
        \\        end
        \\    end
    , 80);
    defer testing.allocator.free(text);
    const rows = try fixture.lines(testing.allocator, text);
    defer testing.allocator.free(rows);
    const outer = rowOf(rows, "┌─ loop").?;
    const inner = rowOf(rows, "┌─ opt").?;
    try testing.expectEqual(colOf(rows[outer], "┌─ loop") + 1, colOf(rows[inner], "┌─ opt"));
}

test "an empty diagram draws nothing" {
    try testing.expectEqualStrings("", (try render.render(testing.allocator, "sequenceDiagram\n", 0)).drawn);
}
