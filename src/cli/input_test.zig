const std = @import("std");
const input = @import("input.zig");

const looksLikeBareMermaid = input.looksLikeBareMermaid;

test "bare flowchart is detected" {
    try std.testing.expect(looksLikeBareMermaid("flowchart LR\n  A-->B\n"));
    try std.testing.expect(looksLikeBareMermaid("graph TD;\n  A-->B;\n"));
    try std.testing.expect(looksLikeBareMermaid("flowchart LR\r  A-->B\r"));
    try std.testing.expect(looksLikeBareMermaid("\xEF\xBB\xBFflowchart LR\n  A-->B\n"));
}

test "other diagram keywords are detected" {
    try std.testing.expect(looksLikeBareMermaid("sequenceDiagram\n  A->>B: hi\n"));
    try std.testing.expect(looksLikeBareMermaid("classDiagram\n  A <|-- B\n"));
    try std.testing.expect(looksLikeBareMermaid("erDiagram\n  A ||--o{ B : has\n"));
    try std.testing.expect(looksLikeBareMermaid("stateDiagram\n  [*] --> A\n"));
    try std.testing.expect(looksLikeBareMermaid("stateDiagram-v2\n  [*] --> A\n"));
}

test "leading blank lines and %% comments are skipped" {
    try std.testing.expect(looksLikeBareMermaid("\n\n  %% a comment\n%%{init: {}}%%\nflowchart LR\n  A-->B\n"));
    try std.testing.expect(looksLikeBareMermaid("   \ngraph LR\n  A-->B\n"));
}

test "normal markdown is untouched" {
    try std.testing.expect(!looksLikeBareMermaid("# Title\n\nSome text.\n"));
    try std.testing.expect(!looksLikeBareMermaid("Just a paragraph about diagrams.\n"));
    try std.testing.expect(!looksLikeBareMermaid(""));
    try std.testing.expect(!looksLikeBareMermaid("\n\n"));
}

test "prose that merely mentions graph is untouched" {
    try std.testing.expect(!looksLikeBareMermaid("graph theory is a branch of mathematics\n"));
    try std.testing.expect(!looksLikeBareMermaid("flowchart diagrams are useful for docs\n"));
    try std.testing.expect(!looksLikeBareMermaid("graphs are everywhere\n"));
    try std.testing.expect(!looksLikeBareMermaid("stateDiagrams are nice\n"));
}

test "bare graph/flowchart without a direction stays markdown" {
    try std.testing.expect(!looksLikeBareMermaid("graph\nis a nonlinear data structure.\n"));
    try std.testing.expect(!looksLikeBareMermaid("flowchart\nof the release process\n"));
}

test "indented first line is a markdown code block, not a diagram" {
    try std.testing.expect(!looksLikeBareMermaid("    graph TD\n    A-->B\n\n# Title\n"));
    try std.testing.expect(!looksLikeBareMermaid("\tflowchart LR\n  A-->B\n"));
}

test "already-fenced mermaid is untouched" {
    try std.testing.expect(!looksLikeBareMermaid("```mermaid\nflowchart LR\n  A-->B\n```\n"));
    try std.testing.expect(!looksLikeBareMermaid("# Doc\n\n```mermaid\ngraph TD\n  A-->B\n```\n"));
    try std.testing.expect(!looksLikeBareMermaid("~~~mermaid\ngraph TD\n  A-->B\n~~~\n"));
}

test "mermaid extension detection" {
    try std.testing.expect(input.isMermaidExtension("a/b/diagram.mmd"));
    try std.testing.expect(input.isMermaidExtension("diagram.mermaid"));
    try std.testing.expect(!input.isMermaidExtension("README.md"));
}

test "isMermaidSource dispatches on path vs content" {
    try std.testing.expect(input.isMermaidSource("d.mmd", "# not a diagram"));
    try std.testing.expect(!input.isMermaidSource("d.md", "flowchart LR\n  A-->B\n"));
    try std.testing.expect(input.isMermaidSource(null, "flowchart LR\n  A-->B\n"));
    try std.testing.expect(!input.isMermaidSource(null, "# Title\n"));
}

// The routing vocabulary is owned here, at the cli level, by design: it must
// cover every diagram type the mermaid renderers dispatch on. When a new
// diagram type is added, extend `distinct_keywords` in input.zig and add a
// sample below.
test "one accepted sample per supported diagram type" {
    const samples = [_][]const u8{
        "flowchart LR\n  A-->B\n",
        "graph TD\n  A-->B\n",
        "sequenceDiagram\n  A->>B: hi\n",
        "classDiagram\n  A <|-- B\n",
        "erDiagram\n  A ||--o{ B : has\n",
        "stateDiagram\n  [*] --> A\n",
        "stateDiagram-v2\n  [*] --> A\n",
    };
    for (samples) |src| {
        try std.testing.expect(looksLikeBareMermaid(src));
    }
}

// Pull lib/text.zig's own tests into the test binary (it is only reached
// through imports, which does not collect tests on its own).
test {
    _ = @import("../lib/text.zig");
}
