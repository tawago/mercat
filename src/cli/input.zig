const std = @import("std");
const text = @import("text");
const terminal = @import("../platform/terminal.zig");
const detect = @import("../core/mermaid/detect.zig");

pub const stripBom = text.stripBom;

pub fn shouldReadImplicitStdin() bool {
    return !terminal.stdinIsTty();
}

const mermaid_extensions = [_][]const u8{ ".mmd", ".mermaid" };

pub fn isMermaidSource(path: ?[]const u8, content: []const u8) bool {
    if (path) |p| return isMermaidExtension(p);
    return detect.looksLikeBareMermaid(content);
}

pub fn isMermaidExtension(path: []const u8) bool {
    for (mermaid_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

pub const looksLikeBareMermaid = detect.looksLikeBareMermaid;
