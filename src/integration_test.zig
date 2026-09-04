//! Integration tests. Each suite lives in its own file; this root exists so
//! the build runs them all from one test binary.

comptime {
    _ = @import("tests/it_cli.zig");
    _ = @import("tests/it_recording.zig");
    _ = @import("tests/it_namespace.zig");
    _ = @import("tests/it_fullscreen.zig");
    _ = @import("tests/it_empty.zig");
    _ = @import("tests/it_resources.zig");
    _ = @import("tests/it_contrib.zig");
    _ = @import("tests/it_replay.zig");
    _ = @import("tests/it_tui.zig");
    _ = @import("tests/it_fish.zig");
}
