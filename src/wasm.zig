//! WebAssembly entry for the site's playground: the mermaid renderer behind a flat C ABI.
//! JS writes the source into `alloc`ed memory, calls `render`, then reads `output` and `warnings`;
//! both stay valid until the next `render`.

const std = @import("std");
const mermaid = @import("core/mermaid/mermaid.zig");

pub const std_options: std.Options = .{ .logFn = collectLog };

const gpa = std.heap.wasm_allocator;
var arena = std.heap.ArenaAllocator.init(gpa);
var out: []const u8 = "";
var log_buf: [4096]u8 = undefined;
var log_len: usize = 0;

fn collectLog(comptime level: std.log.Level, comptime _: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(std.log.Level.warn)) return;
    const line = std.fmt.bufPrint(log_buf[log_len..], format ++ "\n", args) catch return;
    log_len += line.len;
}

export fn alloc(len: usize) ?[*]u8 {
    return (gpa.alloc(u8, len) catch return null).ptr;
}

export fn free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// Draws `source` within `width` columns; returns 1 when drawn, 0 when mercat shows the source instead.
export fn render(ptr: [*]const u8, len: usize, width: u32) u32 {
    _ = arena.reset(.free_all);
    log_len = 0;
    out = "";
    switch (mermaid.render(arena.allocator(), ptr[0..len], .{ .max_width = width })) {
        .drawn => |text| {
            out = text;
            return 1;
        },
        .not_drawn => |failure| {
            if (failure.banner) |reason| out = reason;
            return 0;
        },
    }
}

export fn output() [*]const u8 {
    return out.ptr;
}

export fn outputLen() usize {
    return out.len;
}

export fn warnings() [*]const u8 {
    return &log_buf;
}

export fn warningsLen() usize {
    return log_len;
}
