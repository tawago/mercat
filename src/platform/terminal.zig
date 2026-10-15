const std = @import("std");
const host = @import("host.zig");

pub fn stdinIsTty() bool {
    return std.Io.File.stdin().isTty(host.io()) catch false;
}

/// Whether stdin is a pipe or socket (`cat x | mercat`), as opposed to a
/// redirected file or a terminal.
pub fn stdinIsPipe() bool {
    const st = std.Io.File.stdin().stat(host.io()) catch return false;
    return st.kind == .named_pipe or st.kind == .unix_domain_socket;
}

pub fn stderrIsTty() bool {
    return std.Io.File.stderr().isTty(host.io()) catch false;
}

pub fn stdoutIsTty() bool {
    return std.Io.File.stdout().isTty(host.io()) catch false;
}

pub fn hasControllingTty() bool {
    const file = host.openFile("/dev/tty", .{ .mode = .read_write }) catch return false;
    file.close(host.io());
    return true;
}

pub fn stdoutWidth() usize {
    if (tmuxPaneWidth()) |width| return width;

    if (host.environ().getAlloc(std.heap.page_allocator, "COLUMNS")) |columns_text| {
        defer std.heap.page_allocator.free(columns_text);
        const parsed = std.fmt.parseInt(usize, columns_text, 10) catch 0;
        if (parsed > 0) return parsed;
    } else |_| {}

    if (fdWidth(std.Io.File.stdout().handle)) |width| return width;
    if (fdWidth(std.Io.File.stderr().handle)) |width| return width;
    if (fdWidth(std.Io.File.stdin().handle)) |width| return width;

    if (ttyWidth()) |width| return width;

    return 80;
}

fn tmuxPaneWidth() ?usize {
    if (host.environ().getAlloc(std.heap.page_allocator, "TMUX")) |tmux_value| {
        defer std.heap.page_allocator.free(tmux_value);
    } else |_| {
        return null;
    }

    const result = std.process.run(std.heap.page_allocator, host.io(), .{
        .argv = &.{ "tmux", "display-message", "-p", "#{pane_width}" },
    }) catch return null;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    if (!result.term.success()) return null;

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;

    const parsed = std.fmt.parseInt(usize, trimmed, 10) catch return null;
    if (parsed > 0) return parsed;
    return null;
}

fn fdWidth(fd: std.posix.fd_t) ?usize {
    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(rc) == .SUCCESS and winsize.col > 0) {
        return winsize.col;
    }
    return null;
}

fn ttyWidth() ?usize {
    const file = host.openFile("/dev/tty", .{ .mode = .read_write }) catch return null;
    defer file.close(host.io());
    return fdWidth(file.handle);
}
