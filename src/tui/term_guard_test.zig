const std = @import("std");
const vaxis = @import("vaxis");
const guard = @import("term_guard.zig");
const ctlseqs = vaxis.ctlseqs;
const posix = std.posix;
const c = std.c;

fn openPipe(nonblock: bool) ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.SystemResources;
    if (nonblock) for (fds) |fd| {
        const flags = c.fcntl(fd, posix.F.GETFL);
        _ = c.fcntl(fd, posix.F.SETFL, flags | @as(c_int, @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })))));
    };
    return fds;
}

fn ttyMode(fd: posix.fd_t) !posix.termios {
    var mode: posix.termios = undefined;
    const rc = posix.system.tcgetattr(fd, &mode);
    if (posix.errno(rc) != .SUCCESS) {
        std.debug.print("tcgetattr({d}): {t}\n", .{ fd, posix.errno(rc) });
        return error.NotATerminal;
    }
    return mode;
}

fn waitStatus(pid: posix.pid_t, options: c_int) u32 {
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, options);
    return @bitCast(status);
}

test "restore sequence shows the cursor, resets modes, and leaves the alt screen last" {
    for ([_][]const u8{ ctlseqs.show_cursor, ctlseqs.mouse_reset, ctlseqs.sgr_reset, ctlseqs.csi_u_pop, ctlseqs.bp_reset }) |seq|
        try std.testing.expect(std.mem.indexOf(u8, guard.restore_sequence, seq) != null);
    // Leaving the alt screen comes last so the resets apply to it first.
    try std.testing.expect(std.mem.endsWith(u8, guard.restore_sequence, ctlseqs.rmcup));
}

test "restoreTerminal writes the restore sequence only while installed" {
    const fds = try openPipe(true);
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);

    var buf: [256]u8 = undefined;
    guard.restoreTerminal();
    try std.testing.expectError(error.WouldBlock, std.posix.read(fds[0], &buf));

    try guard.install(fds[1], std.mem.zeroes(std.posix.termios), null);
    try std.testing.expect(guard.isActive());
    guard.restoreTerminal();
    const n = try std.posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(guard.restore_sequence, buf[0..n]);

    guard.uninstall();
    try std.testing.expect(!guard.isActive());
    guard.restoreTerminal();
    try std.testing.expectError(error.WouldBlock, std.posix.read(fds[0], &buf));
}

test "uninstall restores the fatal-signal handlers that were there before" {
    const fds = try openPipe(true);
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    var before: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.SEGV, null, &before);

    try guard.install(fds[1], std.mem.zeroes(std.posix.termios), null);
    var during: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.SEGV, null, &during);
    try std.testing.expect(during.handler.sigaction != before.handler.sigaction);
    guard.uninstall();

    var after: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.SEGV, null, &after);
    try std.testing.expectEqual(before.handler.sigaction, after.handler.sigaction);
}

test "Ctrl-C exits, Ctrl-Z suspends, and in an editor Ctrl-C is ignored and Ctrl-Z only stops" {
    const SIG = std.posix.SIG;
    try std.testing.expectEqual(guard.Response.stop_only, guard.respond(SIG.TSTP, true));
    try std.testing.expectEqual(guard.Response.ignore, guard.respond(SIG.INT, true));
    try std.testing.expectEqual(guard.Response.ignore, guard.respond(SIG.QUIT, true));
    try std.testing.expectEqual(guard.Response.restore_and_exit, guard.respond(SIG.INT, false));
    try std.testing.expectEqual(guard.Response.restore_and_exit, guard.respond(SIG.QUIT, false));
    try std.testing.expectEqual(guard.Response.suspend_and_resume, guard.respond(SIG.TSTP, false));
}

test "Ctrl-C that also kills the editor is dropped when it arrives, not when handled" {
    const SIG = std.posix.SIG;
    guard.setChildRunning(true);
    // The handler decides while the child flag is still set...
    try std.testing.expect(!guard.wouldForward(SIG.INT));
    try std.testing.expect(!guard.wouldForward(SIG.QUIT));
    // ...so the editor exiting (and clearing the flag) cannot turn it into an exit.
    guard.setChildRunning(false);
    try std.testing.expectEqual(@as(?posix.SIG, null), guard.pendingExitSignal());
    try std.testing.expect(guard.wouldForward(SIG.INT));
}

test "SIGTERM while the editor runs waits for the editor instead of resetting its screen" {
    const SIG = std.posix.SIG;
    guard.setChildRunning(true);
    try std.testing.expect(!guard.wouldForward(SIG.TERM));
    try std.testing.expectEqual(@as(?posix.SIG, .TERM), guard.pendingExitSignal());
    try std.testing.expect(!guard.wouldForward(SIG.HUP));
    try std.testing.expectEqual(@as(?posix.SIG, .HUP), guard.pendingExitSignal());
    // The guard is not installed here, so clearing the flag only drops the
    // pending signal instead of exiting the test runner.
    guard.setChildRunning(false);
    try std.testing.expectEqual(@as(?posix.SIG, null), guard.pendingExitSignal());
    try std.testing.expect(guard.wouldForward(SIG.TERM));
    try std.testing.expect(guard.wouldForward(SIG.TSTP));
}

test "anything that is not a terminal with a foreground group counts as foreground" {
    // Another group owns the tty (the shell after Ctrl-Z, or `bg`): hands off.
    try std.testing.expect(!guard.foregroundDecision(7, 42));

    const fds = try openPipe(false);
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    try std.testing.expect(guard.inForeground(fds[1]));
}

test "kill of a suspended process (TERM then CONT) terminates it instead of stopping it again" {
    inline for (.{ posix.SIG.TERM, posix.SIG.HUP }) |sig| {
        const fds = try openPipe(false);
        defer _ = c.close(fds[0]);
        const pid = c.fork();
        if (pid == 0) {
            // A group of its own, with the parent outside it, is not orphaned,
            // so the kernel honours the stop wherever the runner was started.
            if (c.setpgid(0, 0) != 0) c._exit(2);
            guard.install(fds[1], std.mem.zeroes(posix.termios), null) catch c._exit(2);
            guard.suspendSelf();
            // Only reached if the exit signal did not end the process; wait
            // as the app would rather than racing the signal to exit.
            _ = c.nanosleep(&.{ .sec = 2, .nsec = 0 }, null);
            c._exit(3);
        }
        _ = c.close(fds[1]);
        const stopped = waitStatus(pid, posix.W.UNTRACED);
        try std.testing.expect(posix.W.IFSTOPPED(stopped));
        // What a shell's `kill %1` does to a stopped job.
        try posix.kill(pid, sig);
        try posix.kill(pid, posix.SIG.CONT);
        const done = waitStatus(pid, 0);
        try std.testing.expect(posix.W.IFSIGNALED(done));
        try std.testing.expectEqual(sig, posix.W.TERMSIG(done));
    }
}

extern "c" fn openpty(master: *c_int, slave: *c_int, name: ?[*]u8, termp: ?*const std.posix.termios, winp: ?*const anyopaque) c_int;

test "an exit signal just as a suspended process resumes leaves the tty cooked" {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.SkipZigTest;
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const cooked = try ttyMode(slave);
    try std.testing.expect(cooked.lflag.ICANON and cooked.lflag.ECHO);

    const pid = c.fork();
    if (pid == 0) {
        if (c.setpgid(0, 0) != 0) c._exit(2);
        // Resuming: the tty is raw again but the suspended flag is still set.
        var raw = cooked;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        posix.tcsetattr(slave, .NOW, raw) catch c._exit(2);
        guard.install(slave, cooked, null) catch c._exit(2);
        guard.setSuspendedForTest(true);
        posix.raise(posix.SIG.TERM) catch c._exit(2);
        c._exit(3);
    }
    const done = waitStatus(pid, 0);
    if (!posix.W.IFSIGNALED(done)) std.debug.print("child status 0x{x}\n", .{done});
    try std.testing.expect(posix.W.IFSIGNALED(done));
    try std.testing.expectEqual(posix.SIG.TERM, posix.W.TERMSIG(done));
    const after = try ttyMode(slave);
    try std.testing.expect(after.lflag.ICANON and after.lflag.ECHO);
}
