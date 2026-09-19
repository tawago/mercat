const unicode = @import("unicode");

pub const Error = unicode.MeasureError;

pub fn displayWidth(text: []const u8) Error!usize {
    return unicode.rawDisplayWidth(text);
}

pub fn displayWidthFrom(text: []const u8, initial_column: usize) Error!usize {
    const end = try unicode.rawDisplayWidthFrom(text, initial_column);
    return end - initial_column;
}

pub fn takeWidth(text: []const u8, width: usize, initial_column: usize) Error!usize {
    var iterator = unicode.Iterator.initAt(text, initial_column);
    var byte_end: usize = 0;
    while (try iterator.next()) |grapheme| {
        if (grapheme.column_end - initial_column > width) break;
        byte_end = grapheme.byte_end;
    }
    return byte_end;
}

pub fn firstGraphemeLength(text: []const u8, initial_column: usize) Error!usize {
    var iterator = unicode.Iterator.initAt(text, initial_column);
    return if (try iterator.next()) |grapheme| grapheme.byte_end else 0;
}

test {
    _ = @import("geometry_test.zig");
}
