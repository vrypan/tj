//! Integration tests. Each suite lives in its own file; this root exists so
//! the build runs them all from one test binary.

test {
    _ = @import("it_cli.zig");
    _ = @import("it_recording.zig");
    _ = @import("it_namespace.zig");
    _ = @import("it_fullscreen.zig");
    _ = @import("it_empty.zig");
    _ = @import("it_resources.zig");
    _ = @import("it_replay.zig");
    _ = @import("it_tui.zig");
}
