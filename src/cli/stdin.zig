const terminal = @import("../platform/terminal.zig");

pub fn shouldReadImplicitStdin() bool {
    return !terminal.stdinIsTty();
}
