//! A node's bracketed shape and label, read after its id.

const sg = @import("../sem_graph.zig");
const scanner = @import("scanner.zig");
const token = @import("token.zig");

const Scanner = scanner.Scanner;

pub const Shaped = struct { shape: sg.NodeShape, label: []const u8 };

/// Reads the shape that starts at the next token, which must be an `open` token.
pub fn read(sc: *Scanner) Shaped {
    const open = token.next(sc).bracket;
    const second = token.peek(sc.*);
    const double = second.kind == .open;
    if (double and open == '[') {
        _ = token.next(sc);
        return switch (second.bracket) {
            '[' => .{ .shape = .subroutine, .label = sc.rawUntilStr("]]") },
            '(' => .{ .shape = .cylinder, .label = sc.rawUntilStr(")]") },
            else => .{ .shape = .rect, .label = sc.rawUntilStr("]") },
        };
    }
    if (double and open == '(') {
        _ = token.next(sc);
        return switch (second.bracket) {
            '(' => {
                const third = token.peek(sc.*);
                if (third.kind == .open and third.bracket == '(') {
                    _ = token.next(sc);
                    return .{ .shape = .double_circle, .label = sc.rawUntilStr(")))") };
                }
                return .{ .shape = .circle, .label = sc.rawUntilStr("))") };
            },
            '[' => .{ .shape = .stadium, .label = sc.rawUntilStr("])") },
            else => .{ .shape = .round, .label = sc.rawUntilStr(")") },
        };
    }
    if (double and open == '{') {
        _ = token.next(sc);
        return .{ .shape = .hexagon, .label = sc.rawUntilStr("}}") };
    }
    return switch (open) {
        '[' => switch (sc.at(0)) {
            '/', '\\' => slanted(sc),
            else => .{ .shape = .rect, .label = sc.rawUntil(']') },
        },
        '(' => .{ .shape = .round, .label = sc.rawUntil(')') },
        '{' => .{ .shape = .rhombus, .label = sc.rawUntil('}') },
        '>' => .{ .shape = .asymmetric_right, .label = sc.rawUntil(']') },
        else => unreachable,
    };
}

/// `[/.../]`, `[\...\]`, `[/...\]`, `[\.../]`; one that is not closed is a rect.
fn slanted(sc: *Scanner) Shaped {
    const lead = sc.at(0);
    sc.skip(1);
    const start = sc.pos;
    while (!sc.done()) {
        const c = sc.at(0);
        if (c == '"') {
            sc.skipQuoted();
            continue;
        }
        if ((c == '/' or c == '\\') and sc.at(1) == ']') break;
        if (c == '\n') break;
        sc.skip(1);
    }
    const label = scanner.unquote(sc.src[start..sc.pos]);
    if (sc.done()) return .{ .shape = .rect, .label = label };
    const close = sc.at(0);
    const shape: sg.NodeShape = if (close == '/')
        (if (lead == '/') .parallelogram else .trapezoid_alt)
    else if (close == '\\')
        (if (lead == '/') .trapezoid else .parallelogram_alt)
    else
        .rect;
    sc.skip(1);
    if (sc.at(0) == ']' and !sc.done()) sc.skip(1);
    return .{ .shape = shape, .label = label };
}
