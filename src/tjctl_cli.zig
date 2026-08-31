//! Canonical command tags generated from the journal-control specification.

const zecli = @import("zecli");
const cli_spec = @import("tjctl_spec.zig");

pub const CommandName = zecli.CommandEnum(cli_spec.application);
