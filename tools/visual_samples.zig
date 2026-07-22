//! Visual smoke harness for mermaid_v2.
//!
//! Renders a curated set of small mermaid sources through the v2 pipeline
//! and emits a single self-contained HTML page (`docs/visual-samples.html`)
//! so maintainers can eyeball whether rendering still looks reasonable
//! across diagram-vocabulary categories.
//!
//! Run via:  zig build visual-samples
//!
//! This is purely a structural sanity check — there is no scoring or
//! exact-match against legacy goldens here.

const std = @import("std");
const mermaid_v2 = @import("mermaid_v2");

const Sample = struct {
    name: []const u8,
    description: []const u8,
    source: []const u8,
};

const samples = [_]Sample{
    .{
        .name = "chain_td",
        .description = "Plain top-down chain",
        .source =
        \\flowchart TD
        \\  A --> B
        \\  B --> C
        \\  C --> D
        ,
    },
    .{
        .name = "chain_lr",
        .description = "Plain left-to-right chain",
        .source =
        \\flowchart LR
        \\  A --> B --> C --> D
        ,
    },
    .{
        .name = "chain_bt",
        .description = "Bottom-up chain",
        .source =
        \\flowchart BT
        \\  A --> B
        \\  B --> C
        ,
    },
    .{
        .name = "branch_diamond",
        .description = "Diamond decision branching with two outgoing edges",
        .source =
        \\flowchart TD
        \\  A{Decision} --> B[Yes]
        \\  A --> C[No]
        \\  B --> D
        \\  C --> D
        ,
    },
    .{
        .name = "branch_fanout",
        .description = "Single source fanning out to three siblings",
        .source =
        \\flowchart TD
        \\  Root --> A
        \\  Root --> B
        \\  Root --> C
        ,
    },
    .{
        .name = "loop_small",
        .description = "Small 3-node cycle",
        .source =
        \\flowchart TD
        \\  A --> B
        \\  B --> C
        \\  C --> A
        ,
    },
    .{
        .name = "loop_self",
        .description = "Self-loop on a single node",
        .source =
        \\flowchart TD
        \\  A --> A
        \\  A --> B
        ,
    },
    .{
        .name = "subgraph_single",
        .description = "Single subgraph cluster",
        .source =
        \\flowchart TD
        \\  A --> B
        \\  subgraph S1 [Group One]
        \\    B --> C
        \\    C --> D
        \\  end
        \\  D --> E
        ,
    },
    .{
        .name = "subgraph_nested",
        .description = "Two-deep nested subgraphs",
        .source =
        \\flowchart TD
        \\  A --> B
        \\  subgraph Outer
        \\    B --> C
        \\    subgraph Inner
        \\      C --> D
        \\    end
        \\    D --> E
        \\  end
        ,
    },
    .{
        .name = "subgraph_two",
        .description = "Two sibling subgraphs connected by an edge",
        .source =
        \\flowchart LR
        \\  subgraph Left
        \\    A --> B
        \\  end
        \\  subgraph Right
        \\    C --> D
        \\  end
        \\  B --> C
        ,
    },
    .{
        .name = "edges_dotted",
        .description = "Mix of solid and dotted edges",
        .source =
        \\flowchart TD
        \\  A --> B
        \\  B -.-> C
        \\  C -.-> D
        ,
    },
    .{
        .name = "edges_thick",
        .description = "Mix of solid and thick edges",
        .source =
        \\flowchart LR
        \\  A ==> B
        \\  B --> C
        \\  C ==> D
        ,
    },
    .{
        .name = "shapes_mixed",
        .description = "Rectangle, round, stadium, and diamond shapes",
        .source =
        \\flowchart TD
        \\  A[Rect] --> B(Round)
        \\  B --> C([Stadium])
        \\  C --> D{Diamond}
        ,
    },
    .{
        .name = "labels_edges",
        .description = "Edges carrying text labels",
        .source =
        \\flowchart TD
        \\  A -->|yes| B
        \\  A -->|no| C
        \\  B --> D
        \\  C --> D
        ,
    },
    .{
        .name = "labels_nodes",
        .description = "Nodes with multi-word labels",
        .source =
        \\flowchart LR
        \\  A[Start here] --> B[Process step]
        \\  B --> C[End point]
        ,
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try writeHeader(allocator, &out);

    var fallback_count: usize = 0;

    for (samples) |sample| {
        const result = mermaid_v2.render(allocator, sample.source, .{}) catch |err| {
            try writeErrorSample(allocator, &out, sample, @errorName(err));
            fallback_count += 1;
            continue;
        };
        defer if (!result.is_fallback) allocator.free(result.output);

        try writeSample(allocator, &out, sample, result);
        if (result.is_fallback) fallback_count += 1;
    }

    try writeFooter(allocator, &out, samples.len, fallback_count);

    // Make sure docs/ exists.
    std.fs.cwd().makePath("docs") catch |err| {
        const stderr = std.fs.File.stderr();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "warn: makePath docs failed: {s}\n", .{@errorName(err)}) catch "warn: makePath docs failed\n";
        try stderr.writeAll(msg);
    };

    var file = try std.fs.cwd().createFile("docs/visual-samples.html", .{ .truncate = true });
    defer file.close();
    try file.writeAll(out.items);

    const stderr = std.fs.File.stderr();
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "wrote docs/visual-samples.html ({d} samples, {d} fallbacks, {d} bytes)\n", .{
        samples.len,
        fallback_count,
        out.items.len,
    }) catch "wrote docs/visual-samples.html\n";
    try stderr.writeAll(msg);
}

fn writeHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<title>mermaid_v2 — Visual Samples</title>
        \\<style>
        \\  :root {
        \\    --bg: #faf8f5; --fg: #1d1d1f; --muted: #6b6b70; --rule: #e6e2dc;
        \\    --accent: #b14a3c; --accent2: #2c5f8d; --code-bg: #f1ede5;
        \\    --warn: #b8762a;
        \\  }
        \\  html { background: var(--bg); color: var(--fg); }
        \\  body { max-width: 1100px; margin: 2rem auto 5rem; padding: 0 1.5rem;
        \\    font: 15px/1.55 "Charter","Iowan Old Style",Georgia,serif; }
        \\  h1 { font-size: 1.8rem; margin: 0 0 .25rem; letter-spacing:-.01em; }
        \\  .subtitle { color: var(--muted); margin: 0 0 2rem; font-style: italic;
        \\    font-size: .92rem; }
        \\  h2 { font-size: 1.05rem; margin: 2.2rem 0 .3rem; color: var(--accent2);
        \\    font-family: "JetBrains Mono","SF Mono",Menlo,monospace; }
        \\  .desc { color: var(--muted); font-size: .9rem; margin: 0 0 .6rem; }
        \\  code, pre { font-family: "JetBrains Mono","SF Mono",Menlo,monospace;
        \\    font-size: .82em; }
        \\  pre { background: var(--code-bg); padding: .7rem .9rem; border-radius: 5px;
        \\    overflow-x: auto; line-height: 1.35; margin: .3rem 0; }
        \\  pre.render { background: white; border: 1px solid var(--rule);
        \\    line-height: 1.15; }
        \\  hr { border: none; border-top: 1px dashed var(--rule); margin: .4rem 0; }
        \\  .stats { color: var(--muted); font-size: .8rem; margin: .3rem 0 1rem; }
        \\  .fallback { color: var(--warn); font-weight: 600; }
        \\  .summary { background: white; border: 1px solid var(--rule); border-radius: 5px;
        \\    padding: .7rem 1rem; margin: 1rem 0 2rem; font-size: .9rem; }
        \\  .footer { color: var(--muted); font-size: .8rem; margin-top: 3rem;
        \\    padding-top: 1rem; border-top: 1px solid var(--rule); }
        \\</style>
        \\</head>
        \\<body>
        \\<h1>mermaid_v2 — Visual Samples</h1>
        \\<p class="subtitle">Generated by <code>zig build visual-samples</code> · timestamps and exact-match against legacy goldens are NOT shown — this is a structural sanity check.</p>
        \\
    );
}

fn writeFooter(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    total: usize,
    fallbacks: usize,
) !void {
    var buf: [512]u8 = undefined;
    const summary = try std.fmt.bufPrint(&buf,
        \\<div class="summary">
        \\  <strong>{d}</strong> samples rendered · <strong>{d}</strong> fallback(s)
        \\</div>
        \\<p class="footer">Self-contained artifact. Re-generate any time with <code>zig build visual-samples</code>.</p>
        \\</body>
        \\</html>
        \\
    , .{ total, fallbacks });
    try out.appendSlice(allocator, summary);
}

fn writeSample(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    sample: Sample,
    result: mermaid_v2.RenderResult,
) !void {
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf,
        \\<h2>{s}</h2>
        \\<p class="desc">{s}</p>
        \\
    , .{ sample.name, sample.description });
    try out.appendSlice(allocator, header);

    try out.appendSlice(allocator, "<pre><code>");
    try appendEscaped(allocator, out, sample.source);
    try out.appendSlice(allocator, "</code></pre>\n<hr>\n");

    try out.appendSlice(allocator, "<pre class=\"render\">");
    try appendEscaped(allocator, out, result.output);
    try out.appendSlice(allocator, "</pre>\n");

    var stats_buf: [256]u8 = undefined;
    if (result.is_fallback) {
        const reason = result.fallback_reason orelse "fallback";
        const stats = try std.fmt.bufPrint(&stats_buf,
            "<p class=\"stats\"><span class=\"fallback\">fallback:</span> {s}</p>\n",
            .{reason},
        );
        try out.appendSlice(allocator, stats);
    } else {
        const stats = try std.fmt.bufPrint(&stats_buf,
            "<p class=\"stats\">width: {d} · height: {d}</p>\n",
            .{ result.width, result.height },
        );
        try out.appendSlice(allocator, stats);
    }
}

fn writeErrorSample(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    sample: Sample,
    err_name: []const u8,
) !void {
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf,
        \\<h2>{s}</h2>
        \\<p class="desc">{s}</p>
        \\
    , .{ sample.name, sample.description });
    try out.appendSlice(allocator, header);

    try out.appendSlice(allocator, "<pre><code>");
    try appendEscaped(allocator, out, sample.source);
    try out.appendSlice(allocator, "</code></pre>\n<hr>\n");

    var err_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&err_buf,
        "<p class=\"stats\"><span class=\"fallback\">render error:</span> {s}</p>\n",
        .{err_name},
    );
    try out.appendSlice(allocator, msg);
}

fn appendEscaped(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    src: []const u8,
) !void {
    for (src) |c| {
        switch (c) {
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '&' => try out.appendSlice(allocator, "&amp;"),
            else => try out.append(allocator, c),
        }
    }
}
