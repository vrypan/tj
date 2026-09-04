//! Unit-test root. Production tests stay beside the code they exercise; this
//! file makes the set of executable roots explicit and prevents omissions.

comptime {
    _ = @import("main.zig");
    _ = @import("tjctl_main.zig");
    _ = @import("terminal/title.zig");
}
