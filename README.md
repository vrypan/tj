# tj — Terminal Journal

Makes terminal interactions persistent, addressable, and reusable. See
[TJ-spec.md](TJ-spec.md) for the design.

## Build

Requires Zig 0.16.0.

```sh
zig build                 # builds zig-out/bin/tj
zig build test            # unit + pty integration tests
zig fmt --check .         # formatting gate
```

Cross-compiles with nothing installed on the host. The Makefile wraps the
release matrix:

```sh
make              # native debug build
make check        # fmt + tests, the gates every change must pass
make list         # the target list
make -j6 all      # every target -> dist/<target>/bin/tj
make package      # the same, as dist/tj-<version>-<target>.tar.gz
```

Targets: `{aarch64,x86_64}` × `{macos, linux-musl, linux-gnu}`. The musl
builds are static. Override `OPTIMIZE` (default `ReleaseSafe`) or `ZIG`
to change how they are built.

The proxy uses `std.posix` wherever Zig 0.16 provides the call. Process
control, `ioctl`, and the pty grant/unlock sequence have no `std`
equivalent in this release, so `src/sys.zig` declares them against plain
libc - no libutil or any other add-on library, which is what keeps the
cross builds dependency-free.

## Use

```sh
tj                        # run $SHELL under the journal
tj -- zsh -f              # run a specific command instead
tj --help
```

## Status

The proxy works: `tj -- <command>` is indistinguishable from running the
command directly. The pty is allocated and sized from the outer terminal,
both byte streams are forwarded unchanged, `SIGWINCH` propagates, signals
sent to `tj` reach the shell, and the terminal is handed back with its
original settings on every exit path.

Nothing is recorded yet. The journal itself — sessions, `cmd`/`out`/`rc`
on disk, `@N` references with zsh expansion and completion, and OSC 5107
output resources — is still to come, so the subcommands listed in
`tj --help` exit 2 until there is a journal to read.
