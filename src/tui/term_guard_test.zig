const std = @import("std");
const vaxis = @import("vaxis");
const guard = @import("term_guard.zig");
const ctlseqs = vaxis.ctlseqs;

test "restore sequence shows the cursor, resets modes, and leaves the alt screen last" {
    for ([_][]const u8{ ctlseqs.show_cursor, ctlseqs.mouse_reset, ctlseqs.sgr_reset, ctlseqs.csi_u_pop, ctlseqs.bp_reset }) |seq|
        try std.testing.expect(std.mem.indexOf(u8, guard.restore_sequence, seq) != null);
    // Leaving the alt screen comes last so the resets apply to it first.
    try std.testing.expect(std.mem.endsWith(u8, guard.restore_sequence, ctlseqs.rmcup));
}

test "restoreTerminal writes the restore sequence only while installed" {
    const fds = try std.posix.pipe2(.{ .NONBLOCK = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

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
    const fds = try std.posix.pipe2(.{ .NONBLOCK = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
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
    try std.testing.expectEqual(@as(?u8, null), guard.pendingExitSignal());
    try std.testing.expect(guard.wouldForward(SIG.INT));
}

test "SIGTERM while the editor runs waits for the editor instead of resetting its screen" {
    const SIG = std.posix.SIG;
    guard.setChildRunning(true);
    try std.testing.expect(!guard.wouldForward(SIG.TERM));
    try std.testing.expectEqual(@as(?u8, SIG.TERM), guard.pendingExitSignal());
    try std.testing.expect(!guard.wouldForward(SIG.HUP));
    try std.testing.expectEqual(@as(?u8, SIG.HUP), guard.pendingExitSignal());
    // The guard is not installed here, so clearing the flag only drops the
    // pending signal instead of exiting the test runner.
    guard.setChildRunning(false);
    try std.testing.expectEqual(@as(?u8, null), guard.pendingExitSignal());
    try std.testing.expect(guard.wouldForward(SIG.TERM));
    try std.testing.expect(guard.wouldForward(SIG.TSTP));
}

test "anything that is not a terminal with a foreground group counts as foreground" {
    // Another group owns the tty (the shell after Ctrl-Z, or `bg`): hands off.
    try std.testing.expect(!guard.foregroundDecision(7, 42));

    const fds = try std.posix.pipe2(.{});
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    try std.testing.expect(guard.inForeground(fds[1]));
}

test "kill of a suspended process (TERM then CONT) terminates it instead of stopping it again" {
    const posix = std.posix;
    inline for (.{ posix.SIG.TERM, posix.SIG.HUP }) |sig| {
        const fds = try posix.pipe2(.{});
        defer posix.close(fds[0]);
        const pid = try posix.fork();
        if (pid == 0) {
            // A group of its own, with the parent outside it, is not orphaned,
            // so the kernel honours the stop wherever the runner was started.
            posix.setpgid(0, 0) catch posix.exit(2);
            guard.install(fds[1], std.mem.zeroes(posix.termios), null) catch posix.exit(2);
            guard.suspendSelf();
            // Only reached if the exit signal did not end the process.
            posix.exit(3);
        }
        posix.close(fds[1]);
        const stopped = posix.waitpid(pid, posix.W.UNTRACED);
        try std.testing.expect(posix.W.IFSTOPPED(stopped.status));
        // What a shell's `kill %1` does to a stopped job.
        try posix.kill(pid, sig);
        try posix.kill(pid, posix.SIG.CONT);
        const done = posix.waitpid(pid, 0);
        try std.testing.expect(posix.W.IFSIGNALED(done.status));
        try std.testing.expectEqual(@as(u32, sig), posix.W.TERMSIG(done.status));
    }
}

extern "c" fn openpty(master: *c_int, slave: *c_int, name: ?[*]u8, termp: ?*const std.posix.termios, winp: ?*const anyopaque) c_int;

test "an exit signal just as a suspended process resumes leaves the tty cooked" {
    const posix = std.posix;
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.SkipZigTest;
    defer posix.close(master);
    defer posix.close(slave);
    const cooked = try posix.tcgetattr(slave);
    try std.testing.expect(cooked.lflag.ICANON and cooked.lflag.ECHO);

    const pid = try posix.fork();
    if (pid == 0) {
        posix.setpgid(0, 0) catch posix.exit(2);
        // Resuming: the tty is raw again but the suspended flag is still set.
        var raw = cooked;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        posix.tcsetattr(slave, .NOW, raw) catch posix.exit(2);
        guard.install(slave, cooked, null) catch posix.exit(2);
        guard.setSuspendedForTest(true);
        posix.raise(posix.SIG.TERM) catch posix.exit(2);
        posix.exit(3);
    }
    const done = posix.waitpid(pid, 0);
    try std.testing.expect(posix.W.IFSIGNALED(done.status));
    try std.testing.expectEqual(@as(u32, posix.SIG.TERM), posix.W.TERMSIG(done.status));
    const after = try posix.tcgetattr(slave);
    try std.testing.expect(after.lflag.ICANON and after.lflag.ECHO);
}
