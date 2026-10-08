const std = @import("std");
const input = @import("input.zig");

test "looksLikeBareMermaid: diagram keywords vs markdown" {
    const cases = [_]struct { src: []const u8, want: bool }{
        // Every supported diagram keyword, with LF, CR and a BOM.
        .{ .src = "flowchart LR\n  A-->B\n", .want = true },
        .{ .src = "graph TD;\n  A-->B;\n", .want = true },
        .{ .src = "flowchart LR\r  A-->B\r", .want = true },
        .{ .src = "\xEF\xBB\xBFflowchart LR\n  A-->B\n", .want = true },
        .{ .src = "sequenceDiagram\n  A->>B: hi\n", .want = true },
        .{ .src = "classDiagram\n  A <|-- B\n", .want = true },
        .{ .src = "erDiagram\n  A ||--o{ B : has\n", .want = true },
        .{ .src = "stateDiagram\n  [*] --> A\n", .want = true },
        .{ .src = "stateDiagram-v2\n  [*] --> A\n", .want = true },
        // Leading blank lines and %% comments are skipped.
        .{ .src = "\n\n  %% a comment\n%%{init: {}}%%\nflowchart LR\n  A-->B\n", .want = true },
        .{ .src = "   \ngraph LR\n  A-->B\n", .want = true },
        // Normal markdown and empty input.
        .{ .src = "# Title\n\nSome text.\n", .want = false },
        .{ .src = "Just a paragraph about diagrams.\n", .want = false },
        .{ .src = "", .want = false },
        .{ .src = "\n\n", .want = false },
        // Prose that merely mentions a keyword.
        .{ .src = "graph theory is a branch of mathematics\n", .want = false },
        .{ .src = "flowchart diagrams are useful for docs\n", .want = false },
        .{ .src = "graphs are everywhere\n", .want = false },
        .{ .src = "stateDiagrams are nice\n", .want = false },
        // graph/flowchart without a direction stays markdown.
        .{ .src = "graph\nis a nonlinear data structure.\n", .want = false },
        .{ .src = "flowchart\nof the release process\n", .want = false },
        // An indented first line is a code block.
        .{ .src = "    graph TD\n    A-->B\n\n# Title\n", .want = false },
        .{ .src = "\tflowchart LR\n  A-->B\n", .want = false },
        // Already-fenced mermaid is left to the markdown renderer.
        .{ .src = "```mermaid\nflowchart LR\n  A-->B\n```\n", .want = false },
        .{ .src = "# Doc\n\n```mermaid\ngraph TD\n  A-->B\n```\n", .want = false },
        .{ .src = "~~~mermaid\ngraph TD\n  A-->B\n~~~\n", .want = false },
    };
    for (cases) |case| {
        if (input.looksLikeBareMermaid(case.src) != case.want) {
            std.debug.print("looksLikeBareMermaid({f}) != {}\n", .{ std.zig.fmtString(case.src), case.want });
            return error.TestUnexpectedResult;
        }
    }
}

test "isMermaidSource dispatches on path vs content" {
    try std.testing.expect(input.isMermaidSource("d.mmd", "# not a diagram"));
    try std.testing.expect(input.isMermaidSource("a/b/diagram.mermaid", "# not a diagram"));
    try std.testing.expect(!input.isMermaidSource("d.md", "flowchart LR\n  A-->B\n"));
    try std.testing.expect(input.isMermaidSource(null, "flowchart LR\n  A-->B\n"));
    try std.testing.expect(!input.isMermaidSource(null, "# Title\n"));
}

test {
    _ = @import("text");
}
