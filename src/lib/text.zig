const std = @import("std");

const bom = "\xEF\xBB\xBF";

pub fn stripBom(content: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, content, bom)) content[bom.len..] else content;
}
