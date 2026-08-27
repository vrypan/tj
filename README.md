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

## Showing the number in your prompt

Inside a session the plugin exports `TJ_NEXT`, the number the command you
are about to type will get. Reading it costs nothing per prompt, and it is
unset outside a session, so a prompt that uses it is unchanged elsewhere.

For [starship](https://starship.rs), add an `env_var` module:

```toml
[env_var.TJ_NEXT]
format = '[@$env_value]($style) '
style = 'dimmed white'
```

`$all` picks it up automatically. To put it at the far left instead, name it
explicitly at the front of your format:

```toml
format = """
${env_var.TJ_NEXT}$all\
$character"""
```

For a plain zsh prompt:

```zsh
setopt promptsubst
PS1='[@${TJ_NEXT}] '"$PS1"
```

Scrolling back, every command is then headed by the reference that names it.

## Reading a recording

`tj cat` prints what a reference names, resolving it itself — so it works
from bash, from a script, or from a shell that is not running under tj:

```sh
tj cat @42                # what interaction 42 printed
tj cat @42/cmd            # the command line
tj cat @41 @43 | diff - -
```

Piped, it renders the recording as text a person would have read: escape
sequences removed, and a progress meter that rewrote its line thirty times
reduced to the line it settled on. Straight to a terminal it writes the
bytes as recorded, so colours still render. `--plain` and `--raw` force
either behaviour.

## Full-screen programs

Editors, pagers and monitors switch the terminal to its alternate screen
before painting and switch back on exit, which is why your prompt reappears
intact after quitting vim — that buffer is not part of scrollback.

`out` follows the same rule. What a full-screen program paints is not
recorded, so `vi notes.txt` leaves a `cmd`, an `rc` and a near-empty `out`,
which is exactly what you would find scrolling back. Anything the program
printed before or after is ordinary output and is kept, and `meta.json`
notes what was dropped:

```json
"fullscreen": {"regions": 1, "suppressed_bytes": 2249}
```

This is detected from the switch sequences, never from a list of program
names, so it also covers `git log` paging through `less` and your own
tools. It applies to recording only: the program renders exactly as it
would without tj.

## Storage

The journal is plain files under `~/.tj` (override with `$TJ_HOME` or
`--home`), so nothing needs to understand tj to read it:

```
~/.tj/<session-ulid>/42/
├── cmd        the command line as entered
├── out        what you could scroll back to, escape sequences and all
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

Full-screen programs are kept out of the journal, and `tj cat` reads a
recording back as either bytes or plain text.

Still to come: OSC 5107 semantic output resources, which let a program mark
spans of its own output as named files under `@42/files/`.
