//! Unit-test root. Production tests stay beside the code they exercise; this
//! file makes the set of executable roots explicit and prevents omissions.

comptime {
    _ = @import("main.zig");
    _ = @import("tjctl_main.zig");
    _ = @import("terminal/title.zig");
    _ = @import("child.zig");
    _ = @import("commands/tui.zig");
    _ = @import("tui/detail.zig");
    _ = @import("tui/detail_layout.zig");
    _ = @import("tui/model.zig");
    _ = @import("tui/render.zig");
}
