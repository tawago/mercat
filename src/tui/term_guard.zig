//! Keeps the terminal usable when the TUI is interrupted from outside.
//!
//! Signal handlers only write the signal number to a self-pipe; a watcher
//! thread does the real work outside signal context:
//! - SIGTERM / SIGHUP / SIGINT / SIGQUIT: restore the terminal, then re-raise
//!   the signal with its default action so the exit status is unchanged.
//!   While an editor runs, INT/QUIT are ignored and TERM/HUP are passed to
//!   the editor and acted on after it exits (`setChildRunning`).
//! - SIGTSTP: restore the terminal, stop the process, and on SIGCONT put the
//!   tty back in raw mode and ask the app to redraw (`Hooks.on_resume`).
//!   Continued in the background (`bg`), it stops again until it is brought
//!   to the foreground: touching the tty from there would raise SIGTTOU.
//!   An exit signal that arrives while suspended ends the process straight
//!   from the handler, since the terminal was already restored (this is how
//!   a shell's `kill %1`, TERM followed by CONT, reaches a stopped job).
//! A panic handler (`panicHandler`) and a hook on fatal signals (SIGSEGV,
//! SIGBUS, SIGILL, SIGFPE) restore the terminal before reporting the crash.
const std = @import("std");
const host = @import("../platform/host.zig");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const posix = std.posix;
const ctlseqs = vaxis.ctlseqs;

pub const issue_url = "https://github.com/tawago/mercat/issues";

/// Undo everything the TUI may have enabled, independent of vaxis state:
/// kitty keyboard, mouse, bracketed paste, in-band resize, color-scheme and
/// unicode modes, attributes, hidden cursor, and the alternate screen.
pub const restore_sequence = ctlseqs.csi_u_pop ++
    ctlseqs.mouse_reset ++
    ctlseqs.bp_reset ++
    ctlseqs.in_band_resize_reset ++
    ctlseqs.color_scheme_reset ++
    ctlseqs.unicode_reset ++
    ctlseqs.sgr_reset ++
    ctlseqs.show_cursor ++
    ctlseqs.rmcup;

/// Signals that end the program; each restores the terminal first.
pub const exit_signals = [_]posix.SIG{ .TERM, .HUP, .INT, .QUIT };

/// Crash signals: restore the terminal, report, then hand over to whatever
/// handler was installed before (Zig's stack-trace dumper by default).
pub const fatal_signals = [_]posix.SIG{ .SEGV, .BUS, .ILL, .FPE };

pub const Hooks = struct {
    context: *anyopaque,
    /// Called on the watcher thread after the process continues from a
    /// suspend; must be thread safe (e.g. post an event to the loop).
    on_resume: *const fn (context: *anyopaque) void,
};

const shutdown_byte: u8 = 0;

var active = std.atomic.Value(bool).init(false);
var tty_fd: posix.fd_t = -1;
var cooked_termios: posix.termios = undefined;
var raw_termios: posix.termios = undefined;
var pipe_fds: [2]posix.fd_t = .{ -1, -1 };
var watcher: ?std.Thread = null;
var hooks: ?Hooks = null;
var saved_fatal: [fatal_signals.len]posix.Sigaction = undefined;
/// Child (editor) state, read and written from signal handlers: bit 0 is set
/// while a child owns the terminal, bits 8..15 hold an exit signal (TERM or
/// HUP) that arrived meanwhile and is acted on once the child is gone.
var child_state = std.atomic.Value(u32).init(0);
var child_pid = std.atomic.Value(i32).init(0);
/// Set while the process is suspended with the terminal restored, from just
/// before it stops until it is back in the foreground in raw mode.
var suspended = std.atomic.Value(bool).init(false);

extern "c" fn tcgetpgrp(fd: c_int) posix.pid_t;
extern "c" fn getpgrp() posix.pid_t;
const child_running_bit: u32 = 1;

/// Arms the guard for `fd`, whose current (raw) mode is captured for resume;
/// `cooked` is the mode to restore on exit or suspend.
pub fn install(fd: posix.fd_t, cooked: posix.termios, app_hooks: ?Hooks) !void {
    if (active.load(.acquire)) return;
    tty_fd = fd;
    cooked_termios = cooked;
    raw_termios = posix.tcgetattr(fd) catch cooked;
    hooks = app_hooks;
    pipe_fds = try openPipe();
    errdefer closePipe();
    watcher = try std.Thread.spawn(.{}, watch, .{});
    active.store(true, .release);
    for (exit_signals) |sig| setHandler(sig, forwardSignal);
    setHandler(posix.SIG.TSTP, forwardSignal);
    for (fatal_signals, 0..) |sig, i| {
        var act = posix.Sigaction{
            .handler = .{ .sigaction = onFatalSignal },
            .mask = emptyMask(),
            .flags = posix.SA.SIGINFO,
        };
        posix.sigaction(sig, &act, &saved_fatal[i]);
    }
}

/// Restores default signal dispositions and stops the watcher thread.
pub fn uninstall() void {
    if (!active.load(.acquire)) return;
    for (exit_signals) |sig| setHandler(sig, null);
    setHandler(posix.SIG.TSTP, null);
    for (fatal_signals, 0..) |sig, i| posix.sigaction(sig, &saved_fatal[i], null);
    active.store(false, .release);
    writeAllFd(pipe_fds[1], &.{shutdown_byte});
    if (watcher) |thread| thread.join();
    watcher = null;
    hooks = null;
    closePipe();
}

pub fn isActive() bool {
    return active.load(.acquire);
}

/// Writes `restore_sequence` and restores the cooked tty mode. Safe to call
/// from any thread, including a panicking one; a no-op when not installed.
///
/// Skipped while the process is in the background: tcsetattr there raises
/// SIGTTOU and would stop the process instead of letting it exit. The only
/// way to get there with the TUI up is a suspend, which already restored it.
pub fn restoreTerminal() void {
    if (!active.load(.acquire)) return;
    if (!inForeground(tty_fd)) return;
    writeAllFd(tty_fd, restore_sequence);
    posix.tcsetattr(tty_fd, .NOW, cooked_termios) catch {};
}

/// Puts the tty back into the raw mode captured at install time.
pub fn reenterRawMode() void {
    if (!active.load(.acquire)) return;
    if (!inForeground(tty_fd)) return;
    posix.tcsetattr(tty_fd, .NOW, raw_termios) catch {};
}

/// Restores the cooked tty mode only (the caller already reset the screen).
pub fn enterCookedMode() void {
    if (!active.load(.acquire)) return;
    if (!inForeground(tty_fd)) return;
    posix.tcsetattr(tty_fd, .NOW, cooked_termios) catch {};
}

/// Stops the whole process like a shell's Ctrl-Z, returning after SIGCONT.
/// The caller is responsible for restoring and re-entering the screen.
pub fn stopProcess() void {
    setHandler(posix.SIG.TSTP, null);
    raiseUnblocked(posix.SIG.TSTP);
    if (active.load(.acquire)) setHandler(posix.SIG.TSTP, forwardSignal);
}

/// Whether this process's group owns the terminal `fd`. Anything that is not
/// a terminal with a foreground group (a pipe in tests, a hung-up tty) counts
/// as foreground so restoring is still attempted there.
pub fn inForeground(fd: posix.fd_t) bool {
    const owner = tcgetpgrp(fd);
    return foregroundDecision(owner, getpgrp());
}

/// `owner` is tcgetpgrp's result (negative on error), `own` our group.
pub fn foregroundDecision(owner: posix.pid_t, own: posix.pid_t) bool {
    return owner <= 0 or owner == own;
}

/// After SIGCONT: while a shell's `bg` keeps us in the background, stop again
/// (as a background read would, SIGTTIN) until `fg`. The sleep keeps an
/// orphaned process group, whose stop signals the kernel discards, from
/// spinning.
fn waitForForeground() void {
    while (!inForeground(tty_fd)) {
        raiseUnblocked(posix.SIG.TTIN);
        if (!inForeground(tty_fd)) host.io().sleep(.fromMilliseconds(100), .awake) catch {};
    }
}

/// Ctrl-Z from the keyboard (raw mode delivers it as a key, not a signal):
/// restore the terminal, stop, and return in raw mode after SIGCONT. The
/// caller then re-enters its screen.
pub fn suspendSelf() void {
    if (!active.load(.acquire)) return;
    restoreTerminal();
    suspended.store(true, .release);
    stopProcess();
    waitForForeground();
    reenterRawMode();
    suspended.store(false, .release);
}

/// Test hook: whether the process is suspended with the terminal restored.
pub fn isSuspended() bool {
    return suspended.load(.acquire);
}

/// Panic hook: restore the terminal, explain where to report, then defer to
/// the default handler for the stack trace.
pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    restoreTerminal();
    var buf: [512]u8 = undefined;
    writeAllFd(posix.STDERR_FILENO, std.fmt.bufPrint(&buf, "mercat crashed: {s}\nPlease report this at {s}\n", .{ msg, issue_url }) catch "mercat crashed\n");
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// "mercat crashed: ..." text for a fatal signal; static so it can be
/// written from a signal handler.
pub fn fatalSignalMessage(sig: posix.SIG) []const u8 {
    const tail = "\nPlease report this at " ++ issue_url ++ "\n";
    return switch (sig) {
        .SEGV => "mercat crashed: segmentation fault (SIGSEGV)" ++ tail,
        .BUS => "mercat crashed: bus error (SIGBUS)" ++ tail,
        .ILL => "mercat crashed: illegal instruction (SIGILL)" ++ tail,
        .FPE => "mercat crashed: arithmetic exception (SIGFPE)" ++ tail,
        else => "mercat crashed: fatal signal" ++ tail,
    };
}

fn onFatalSignal(signal: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    restoreTerminal();
    writeAllFd(posix.STDERR_FILENO, fatalSignalMessage(signal));
    for (fatal_signals, 0..) |fatal, i| {
        if (fatal == signal) posix.sigaction(signal, &saved_fatal[i], null);
    }
    // Sent with kill()/raise(): there is no faulting instruction to re-run,
    // so re-raise for the previous handler. A real fault simply returns and
    // faults again under the previous handler, which then sees the true context.
    if (info.code <= 0) posix.raise(signal) catch {};
}

fn emptyMask() posix.sigset_t {
    return switch (builtin.os.tag) {
        .macos => 0,
        else => posix.sigemptyset(),
    };
}

fn addSignal(set: *posix.sigset_t, sig: posix.SIG) void {
    switch (builtin.os.tag) {
        .macos => set.* |= @as(posix.sigset_t, 1) << @intCast(@intFromEnum(sig) - 1),
        else => posix.sigaddset(set, sig),
    }
}

/// Raises `sig` at the calling thread with it unblocked there, then puts the
/// thread's mask back. The watcher thread blocks the guarded signals, and a
/// handler blocks its own signal; on macOS a signal raised while blocked
/// stays pending instead of taking its default action.
fn raiseUnblocked(sig: posix.SIG) void {
    var set = emptyMask();
    addSignal(&set, sig);
    var old: posix.sigset_t = undefined;
    _ = std.c.pthread_sigmask(posix.SIG.UNBLOCK, &set, &old);
    posix.raise(sig) catch {};
    _ = std.c.pthread_sigmask(posix.SIG.SETMASK, &old, &old);
}

/// Blocks the signals the guard handles in the calling thread.
fn blockGuardedSignals() void {
    var set = emptyMask();
    for (exit_signals) |sig| addSignal(&set, sig);
    addSignal(&set, posix.SIG.TSTP);
    var old: posix.sigset_t = undefined;
    _ = std.c.pthread_sigmask(posix.SIG.BLOCK, &set, &old);
}

fn forwardSignal(sig: posix.SIG) callconv(.c) void {
    const byte: u8 = @intCast(@intFromEnum(sig));
    // Decide now, not when the watcher gets to it: by then the child may have
    // died from the very same Ctrl-C and cleared the flag.
    if (!deferOrDrop(sig)) return;
    // Suspended: the terminal is restored and the process may be stopped or
    // in the background, so nothing needs the watcher. Die now, before the
    // suspended thread can stop the process again. Resuming puts the tty
    // back in raw mode just before clearing the flag, so restore the cooked
    // mode (tcsetattr is async-signal-safe) when we own the terminal.
    if (suspended.load(.acquire) and isExitSignal(sig)) {
        if (inForeground(tty_fd)) posix.tcsetattr(tty_fd, .NOW, cooked_termios) catch {};
        setHandler(sig, null);
        raiseUnblocked(sig);
        return;
    }
    const fd = pipe_fds[1];
    if (fd < 0) return;
    _ = posix.system.write(fd, @ptrCast(&byte), 1);
}

/// Called in signal context. Returns true when the watcher should handle
/// `sig`; false when it was dropped (INT/QUIT typed into the editor) or
/// deferred until the editor exits (TERM/HUP, also passed on to the editor).
fn deferOrDrop(sig: posix.SIG) bool {
    var state = child_state.load(.acquire);
    while (true) {
        switch (respond(sig, state & child_running_bit != 0)) {
            .ignore => return false,
            .defer_until_child_exits => {
                const next = (state & ~@as(u32, 0xff00)) | (@as(u32, @intFromEnum(sig)) << 8);
                state = child_state.cmpxchgWeak(state, next, .acq_rel, .acquire) orelse {
                    const pid = child_pid.load(.acquire);
                    if (pid > 0) _ = std.c.kill(pid, sig);
                    return false;
                };
            },
            else => return true,
        }
    }
}

fn isExitSignal(sig: posix.SIG) bool {
    return std.mem.indexOfScalar(posix.SIG, &exit_signals, sig) != null;
}

fn watch() void {
    // Process-directed signals then always reach the main thread. On macOS
    // a TERM pending across a stop could otherwise run its handler here
    // while the main thread clears `suspended` and carries on.
    blockGuardedSignals();
    var byte: [1]u8 = undefined;
    while (true) {
        const n = posix.read(pipe_fds[0], &byte) catch return;
        if (n == 0 or byte[0] == shutdown_byte) return;
        handleSignal(@enumFromInt(byte[0]));
    }
}

/// While a child (the editor) owns the terminal, keys like Ctrl-C or Ctrl-\
/// typed into a cooked-mode editor signal mercat too (same process group).
/// Like other tools that launch an editor, mercat ignores those until the
/// child exits. SIGTERM / SIGHUP are passed on to the child (see
/// `setChildPid`) and acted on only after it exits, so the editor's screen is
/// never reset under it. Call with `false` from the thread that owns the
/// screen, before redrawing: a deferred exit signal ends the process here.
pub fn setChildRunning(running: bool) void {
    if (running) {
        child_state.store(child_running_bit, .release);
        return;
    }
    child_pid.store(0, .release);
    const pending: u8 = @truncate(child_state.swap(0, .acq_rel) >> 8);
    if (pending != 0 and active.load(.acquire)) exitForSignal(@enumFromInt(pending));
}

/// Records the running child's pid so deferred exit signals reach it too.
pub fn setChildPid(pid: posix.pid_t) void {
    child_pid.store(pid, .release);
}

/// Test hook: marks the process suspended, as `suspendSelf` does while
/// stopped, without stopping it.
pub fn setSuspendedForTest(value: bool) void {
    suspended.store(value, .release);
}

/// Test hook: the exit signal waiting for the child to finish, if any.
pub fn pendingExitSignal() ?posix.SIG {
    const pending: u8 = @truncate(child_state.load(.acquire) >> 8);
    return if (pending == 0) null else @enumFromInt(pending);
}

/// Test hook: runs the signal handler's decision for `sig` in the current
/// state; true when it would be handed to the watcher thread.
pub fn wouldForward(sig: posix.SIG) bool {
    return deferOrDrop(sig);
}

pub const Response = enum { ignore, stop_only, suspend_and_resume, defer_until_child_exits, restore_and_exit };

/// What to do with a signal, given whether a child owns the terminal.
pub fn respond(sig: posix.SIG, child_owns_terminal: bool) Response {
    if (sig == .TSTP) return if (child_owns_terminal) .stop_only else .suspend_and_resume;
    if (child_owns_terminal and (sig == .INT or sig == .QUIT)) return .ignore;
    if (child_owns_terminal and (sig == .TERM or sig == .HUP)) return .defer_until_child_exits;
    return .restore_and_exit;
}

fn handleSignal(sig: posix.SIG) void {
    // Only SIGTSTP is still undecided here; the handler already filtered or
    // deferred everything else when it arrived.
    const child = sig == .TSTP and child_state.load(.acquire) & child_running_bit != 0;
    switch (respond(sig, child)) {
        .ignore, .defer_until_child_exits => return,
        // The child's screen is not ours to reset; just stop alongside it.
        .stop_only => return stopProcess(),
        .suspend_and_resume => {
            suspendSelf();
            if (hooks) |h| h.on_resume(h.context);
            return;
        },
        .restore_and_exit => exitForSignal(sig),
    }
}

fn exitForSignal(sig: posix.SIG) void {
    restoreTerminal();
    setHandler(sig, null);
    raiseUnblocked(sig);
    // A default action that does not terminate (should not happen for these
    // signals) still must not leave the user stuck in a dead UI.
    std.process.exit(@intCast(128 + @intFromEnum(sig)));
}

fn setHandler(sig: posix.SIG, handler: ?posix.Sigaction.handler_fn) void {
    var act = posix.Sigaction{
        .handler = .{ .handler = handler orelse posix.SIG.DFL },
        .mask = emptyMask(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(sig, &act, null);
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (rc < 0) {
            if (std.c.errno(rc) == .INTR) continue;
            return;
        }
        if (rc == 0) return;
        written += @intCast(rc);
    }
}

fn openPipe() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.ProcessFdQuotaExceeded;
    for (fds) |fd| _ = std.c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
    return fds;
}

fn closePipe() void {
    for (&pipe_fds) |*fd| {
        if (fd.* >= 0) _ = std.c.close(fd.*);
        fd.* = -1;
    }
}

test {
    _ = @import("term_guard_test.zig");
}
