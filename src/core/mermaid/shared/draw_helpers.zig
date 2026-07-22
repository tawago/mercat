/// Shared canvas drawing helpers used by multiple diagram renderers.
const std = @import("std");
const types = @import("../types.zig");
const canvas_mod = @import("canvas.zig");

const RenderOptions = types.RenderOptions;
const Rect = types.Rect;

const Canvas = canvas_mod.Canvas;

/// Process label to handle HTML entities like <br/>
pub fn processLabel(label: []const u8, buf: []u8) []const u8 {
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < label.len and out_idx < buf.len) {
        // Check for <br/> or <br> tags
        if (i + 4 < label.len and std.mem.eql(u8, label[i .. i + 4], "<br>")) {
            buf[out_idx] = ' ';
            out_idx += 1;
            i += 4;
        } else if (i + 5 <= label.len and std.mem.eql(u8, label[i .. i + 5], "<br/>")) {
            buf[out_idx] = ' ';
            out_idx += 1;
            i += 5;
        } else {
            buf[out_idx] = label[i];
            out_idx += 1;
            i += 1;
        }
    }
    return buf[0..out_idx];
}

pub fn processedLabelLen(label: []const u8) usize {
    var buf: [256]u8 = undefined;
    return processLabel(label, &buf).len;
}

pub fn drawWrappedTextCentered(canvas: *Canvas, rect: Rect, raw_label: []const u8, options: RenderOptions, top_inset: i32) void {
    var storage: [8][128]u8 = undefined;
    var lines: [8][]const u8 = undefined;
    const line_count = wrapLabelLines(raw_label, options.max_label_width, &storage, &lines);
    if (line_count == 0) return;

    const box_height: i32 = @intCast(rect.height);
    const content_height = @max(box_height - 2 - top_inset, 1);
    const start_y = rect.y + 1 + top_inset + @divFloor(content_height - @as(i32, @intCast(line_count)), 2);

    for (lines[0..line_count], 0..) |line, idx| {
        const line_len: i32 = @intCast(line.len);
        const x = rect.x + @divFloor(@as(i32, @intCast(rect.width)) - line_len, 2);
        canvas.drawText(x, start_y + @as(i32, @intCast(idx)), line, .node_text);
    }
}

pub fn wrapLabelLines(raw_label: []const u8, max_label_width: ?u32, storage: *[8][128]u8, out_lines: *[8][]const u8) usize {
    var processed_buf: [256]u8 = undefined;
    const processed = processLabel(raw_label, &processed_buf);
    const wrap_width: usize = if (max_label_width) |w| @intCast(@max(w, 1)) else processed.len;

    var line_count: usize = 0;
    var line_len: usize = 0;
    var i: usize = 0;

    while (i < processed.len and line_count < out_lines.len) {
        while (i < processed.len and processed[i] == ' ' and line_len == 0) : (i += 1) {}
        if (i >= processed.len) break;

        var word_end = i;
        while (word_end < processed.len and processed[word_end] != ' ') : (word_end += 1) {}
        const word = processed[i..word_end];

        if (line_len > 0 and line_len + 1 + word.len > wrap_width) {
            out_lines[line_count] = storage[line_count][0..line_len];
            line_count += 1;
            line_len = 0;
            if (line_count >= out_lines.len) break;
        }

        if (word.len > wrap_width and wrap_width > 0) {
            var consumed: usize = 0;
            while (consumed < word.len and line_count < out_lines.len) {
                if (line_len > 0) {
                    out_lines[line_count] = storage[line_count][0..line_len];
                    line_count += 1;
                    line_len = 0;
                    if (line_count >= out_lines.len) break;
                }

                const chunk_len = @min(wrap_width, word.len - consumed);
                @memcpy(storage[line_count][0..chunk_len], word[consumed .. consumed + chunk_len]);
                out_lines[line_count] = storage[line_count][0..chunk_len];
                line_count += 1;
                consumed += chunk_len;
            }
        } else {
            if (line_len > 0) {
                storage[line_count][line_len] = ' ';
                line_len += 1;
            }
            @memcpy(storage[line_count][line_len .. line_len + word.len], word);
            line_len += word.len;
        }

        i = word_end;
        while (i < processed.len and processed[i] == ' ') : (i += 1) {}
    }

    if (line_len > 0 and line_count < out_lines.len) {
        out_lines[line_count] = storage[line_count][0..line_len];
        line_count += 1;
    }

    return line_count;
}

pub fn drawDiamondNode(canvas: *Canvas, rect: Rect, label: []const u8, options: RenderOptions) void {
    const x = rect.x;
    const y = rect.y;
    const w: i32 = @intCast(rect.width);
    const h: i32 = @intCast(rect.height);
    const mid_y = y + @divFloor(h, 2);
    const mid_x = x + @divFloor(w, 2);

    // Draw < on left, > on right
    canvas.setChar(x, mid_y, '<', .node_border);
    canvas.setChar(x + w - 1, mid_y, '>', .node_border);

    // Draw single macron at top center, single underscore at bottom center
    if (h >= 3) {
        canvas.setChar(mid_x, y, 0x00AF, .node_border); // ¯ (macron)
        canvas.setChar(mid_x, y + h - 1, '_', .node_border); // _
    }

    drawWrappedTextCentered(canvas, rect, label, options, 0);
}
