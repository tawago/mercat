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
pub const exit_signals = [_]u8{ posix.SIG.TERM, posix.SIG.HUP, posix.SIG.INT, posix.SIG.QUIT };

/// Crash signals: restore the terminal, report, then hand over to whatever
/// handler was installed before (Zig's stack-trace dumper by default).
pub const fatal_signals = [_]u8{ posix.SIG.SEGV, posix.SIG.BUS, posix.SIG.ILL, posix.SIG.FPE };

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
    pipe_fds = try posix.pipe2(.{ .CLOEXEC = true });
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
    _ = posix.write(pipe_fds[1], &.{shutdown_byte}) catch {};
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
    posix.raise(posix.SIG.TSTP) catch {};
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
        posix.raise(posix.SIG.TTIN) catch {};
        if (!inForeground(tty_fd)) std.Thread.sleep(100 * std.time.ns_per_ms);
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
    var buf: [256]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    stderr.interface.print("mercat crashed: {s}\nPlease report this at {s}\n", .{ msg, issue_url }) catch {};
    stderr.interface.flush() catch {};
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// "mercat crashed: ..." text for a fatal signal; static so it can be
/// written from a signal handler.
pub fn fatalSignalMessage(sig: u8) []const u8 {
    const tail = "\nPlease report this at " ++ issue_url ++ "\n";
    return switch (sig) {
        posix.SIG.SEGV => "mercat crashed: segmentation fault (SIGSEGV)" ++ tail,
        posix.SIG.BUS => "mercat crashed: bus error (SIGBUS)" ++ tail,
        posix.SIG.ILL => "mercat crashed: illegal instruction (SIGILL)" ++ tail,
        posix.SIG.FPE => "mercat crashed: arithmetic exception (SIGFPE)" ++ tail,
        else => "mercat crashed: fatal signal" ++ tail,
    };
}

fn onFatalSignal(sig: c_int, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    const signal: u8 = @intCast(sig);
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

fn forwardSignal(sig: c_int) callconv(.c) void {
    const byte: u8 = @intCast(sig);
    // Decide now, not when the watcher gets to it: by then the child may have
    // died from the very same Ctrl-C and cleared the flag.
    if (!deferOrDrop(byte)) return;
    // Suspended: the terminal is already restored and the process may be
    // stopped or in the background, so nothing needs the watcher. Die now,
    // before the suspended thread can stop the process again.
    if (suspended.load(.acquire) and isExitSignal(byte)) {
        setHandler(byte, null);
        _ = posix.system.kill(posix.system.getpid(), sig);
        return;
    }
    const fd = pipe_fds[1];
    if (fd < 0) return;
    _ = posix.system.write(fd, @ptrCast(&byte), 1);
}

/// Called in signal context. Returns true when the watcher should handle
/// `sig`; false when it was dropped (INT/QUIT typed into the editor) or
/// deferred until the editor exits (TERM/HUP, also passed on to the editor).
fn deferOrDrop(sig: u8) bool {
    var state = child_state.load(.acquire);
    while (true) {
        switch (respond(sig, state & child_running_bit != 0)) {
            .ignore => return false,
            .defer_until_child_exits => {
                const next = (state & ~@as(u32, 0xff00)) | (@as(u32, sig) << 8);
                state = child_state.cmpxchgWeak(state, next, .acq_rel, .acquire) orelse {
                    const pid = child_pid.load(.acquire);
                    if (pid > 0) _ = posix.system.kill(pid, sig);
                    return false;
                };
            },
            else => return true,
        }
    }
}

fn isExitSignal(sig: u8) bool {
    return std.mem.indexOfScalar(u8, &exit_signals, sig) != null;
}

fn watch() void {
    var byte: [1]u8 = undefined;
    while (true) {
        const n = posix.read(pipe_fds[0], &byte) catch return;
        if (n == 0 or byte[0] == shutdown_byte) return;
        handleSignal(byte[0]);
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
    if (pending != 0 and active.load(.acquire)) exitForSignal(pending);
}

/// Records the running child's pid so deferred exit signals reach it too.
pub fn setChildPid(pid: posix.pid_t) void {
    child_pid.store(pid, .release);
}

/// Test hook: the exit signal waiting for the child to finish, if any.
pub fn pendingExitSignal() ?u8 {
    const pending: u8 = @truncate(child_state.load(.acquire) >> 8);
    return if (pending == 0) null else pending;
}

/// Test hook: runs the signal handler's decision for `sig` in the current
/// state; true when it would be handed to the watcher thread.
pub fn wouldForward(sig: u8) bool {
    return deferOrDrop(sig);
}

pub const Response = enum { ignore, stop_only, suspend_and_resume, defer_until_child_exits, restore_and_exit };

/// What to do with a signal, given whether a child owns the terminal.
pub fn respond(sig: u8, child_owns_terminal: bool) Response {
    if (sig == posix.SIG.TSTP) return if (child_owns_terminal) .stop_only else .suspend_and_resume;
    if (child_owns_terminal and (sig == posix.SIG.INT or sig == posix.SIG.QUIT)) return .ignore;
    if (child_owns_terminal and (sig == posix.SIG.TERM or sig == posix.SIG.HUP)) return .defer_until_child_exits;
    return .restore_and_exit;
}

fn handleSignal(sig: u8) void {
    // Only SIGTSTP is still undecided here; the handler already filtered or
    // deferred everything else when it arrived.
    const child = sig == posix.SIG.TSTP and child_state.load(.acquire) & child_running_bit != 0;
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

fn exitForSignal(sig: u8) void {
    restoreTerminal();
    setHandler(sig, null);
    posix.raise(sig) catch {};
    // A default action that does not terminate (should not happen for these
    // signals) still must not leave the user stuck in a dead UI.
    std.process.exit(128 + sig);
}

fn setHandler(sig: u8, handler: ?*const fn (c_int) callconv(.c) void) void {
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
        const n = posix.write(fd, bytes[written..]) catch return;
        if (n == 0) return;
        written += n;
    }
}

fn closePipe() void {
    for (&pipe_fds) |*fd| {
        if (fd.* >= 0) posix.close(fd.*);
        fd.* = -1;
    }
}

test {
    _ = @import("term_guard_test.zig");
}
