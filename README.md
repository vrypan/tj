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

Add the shell integration to `~/.zshrc`, which is what tells tj where one
command ends and the next begins:

```sh
source /path/to/tj.plugin.zsh
```

Then start a session:

```sh
tj                        # run $SHELL under the journal
tj -- zsh -f              # run a specific command instead
```

Each command becomes a numbered interaction in the journal:

```sh
tj sessions               # every session, newest first
tj list                   # interactions of this session: number, status, command
tj current                # this session's id
tj last                   # the last interaction that completed
```

## References

Interactions have names, the way files do. Write them on any command line
and the shell integration turns them into paths before the command runs:

```sh
curl -s https://example.com/data.json     # interaction 41
jq .items @41/out                         # read what it printed, without rerunning
diff @41/out @43/out
cat @-/cmd                                # the last command that completed
```

| Reference | Names |
|---|---|
| `@42/out` | interaction 42 of this session |
| `@-/out` | the last interaction that *completed*, never the one running |
| `@pgsd.42/out` | interaction 42 of another session, by a suffix of its id |

Suffixes rather than prefixes, because every session started in the same
millisecond shares the ULID's timestamp prefix and only the tail tells them
apart. The most recent match wins, so short suffixes are for interactive
use; anything that must stay valid should use the full id.

`@42/<TAB>` completes to the resources that interaction actually has. Words
that merely contain an `@`, quoted text, and `user@host` are left alone, and
a reference that cannot be resolved reaches the command literally rather
than being silently dropped.

The journal records the line you typed; `meta.json` keeps what actually ran
when expansion changed it.

## Storage

The journal is plain files under `~/.tj` (override with `$TJ_HOME` or
`--home`), so nothing needs to understand tj to read it:

```
~/.tj/<session-ulid>/42/
├── cmd        the command line as entered
├── out        what the terminal saw, escape sequences and all
├── rc         exit status; absent means the command never finished
└── meta.json
```

Directories are `0700` and files `0600`: the journal holds whatever
appeared on your terminal, so treat it like shell history.

## Status

The proxy is transparent: `tj -- <command>` is indistinguishable from
running the command directly. The pty is allocated and sized from the outer
terminal, both byte streams are forwarded unchanged, `SIGWINCH` propagates,
signals sent to `tj` reach the shell, and the terminal is handed back with
its original settings on every exit path.

Recording works for `cmd`, `out` and `rc`, and the `@` namespace resolves,
expands and completes. Recording never gets in the way of the terminal: if
the journal cannot be written, the session says so once and carries on as a
plain proxy.

Still to come: OSC 5107 semantic output resources, which let a program mark
spans of its own output as named files under `@42/files/`.
