const std = @import("std");

pub fn stdinIsTty() bool {
    return std.fs.File.stdin().isTty();
}

pub fn stdoutIsTty() bool {
    return std.fs.File.stdout().isTty();
}

pub fn hasControllingTty() bool {
    const file = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write }) catch return false;
    file.close();
    return true;
}

pub fn stdoutWidth() usize {
    if (tmuxPaneWidth()) |width| return width;

    if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLUMNS")) |columns_text| {
        defer std.heap.page_allocator.free(columns_text);
        const parsed = std.fmt.parseInt(usize, columns_text, 10) catch 0;
        if (parsed > 0) return parsed;
    } else |_| {}

    if (fdWidth(std.fs.File.stdout().handle)) |width| return width;
    if (fdWidth(std.fs.File.stderr().handle)) |width| return width;
    if (fdWidth(std.fs.File.stdin().handle)) |width| return width;

    if (ttyWidth()) |width| return width;

    return 80;
}

fn tmuxPaneWidth() ?usize {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "TMUX")) |tmux_value| {
        defer std.heap.page_allocator.free(tmux_value);
    } else |_| {
        return null;
    }

    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "tmux", "display-message", "-p", "#{pane_width}" },
    }) catch return null;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    if (result.term.Exited != 0) return null;

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
    const file = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write }) catch return null;
    defer file.close();
    return fdWidth(file.handle);
}
