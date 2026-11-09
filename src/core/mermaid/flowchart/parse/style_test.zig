const std = @import("std");
const style = @import("style.zig");

const t = std.testing;
const Rgb = @import("prim").Rgb;

test "the stroke property is found among the others" {
    try t.expectEqual(@as(?Rgb, .{ .r = 0x12, .g = 0x34, .b = 0x56 }), style.strokeOf("fill:#fff,stroke:#123456,color:#000"));
}

test "a three-digit hex colour expands each digit" {
    try t.expectEqual(@as(?Rgb, .{ .r = 0xaa, .g = 0xbb, .b = 0xcc }), style.strokeOf("stroke:#abc"));
}

test "stroke-width and stroke-dasharray are not the stroke" {
    try t.expectEqual(@as(?Rgb, null), style.strokeOf("stroke-width:2px,stroke-dasharray:5 5"));
}

test "blanks and upper-case hex are read" {
    try t.expectEqual(@as(?Rgb, .{ .r = 0xff, .g = 0, .b = 0xab }), style.strokeOf("  stroke : #FF00AB ; "));
}

test "an !important flag is read past" {
    try t.expectEqual(@as(?Rgb, .{ .r = 0xff, .g = 0, .b = 0 }), style.strokeOf("stroke:#f00 !important,fill:#fff"));
    try t.expectEqual(@as(?Rgb, .{ .r = 0xff, .g = 0, .b = 0 }), style.strokeOf("stroke:#f00!important"));
}

test "a malformed or named colour gives none" {
    for ([_][]const u8{ "stroke:#12", "stroke:#ggg", "stroke:red", "stroke:", "stroke:#1234567" }) |text| {
        try t.expectEqual(@as(?Rgb, null), style.strokeOf(text));
    }
}

test "linkProps drops a leading interpolate curve and nothing else" {
    try t.expectEqualStrings(" stroke:#f00", style.linkProps(" interpolate basis stroke:#f00"));
    try t.expectEqualStrings("", style.linkProps(" interpolate linear"));
    try t.expectEqualStrings(" interpolated:#f00", style.linkProps(" interpolated:#f00"));
    try t.expectEqualStrings(" stroke:#f00", style.linkProps(" stroke:#f00"));
}
