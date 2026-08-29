# tj — Terminal Journal

> [!WARNING] 
> **PRE-ALPHA**
>
> This project is under heavy development and many things will change.

Makes terminal entries persistent, addressable, and reusable. See
[TJ-spec.md](TJ-spec.md) for the design.

## Install

Building needs Zig 0.16.0. Running tj needs nothing.

```sh
git clone <this repo> ~/src/tj
cd ~/src/tj
make install                          # tj and contrib tools into ~/.local/bin
```

`PREFIX=/usr/local make install` to put them elsewhere; anywhere on your
`$PATH` will do.

Check they landed:

```sh
tj --version                          # tj 0.2.1
tj-fence < /dev/null && echo ok       # used by the agent wrappers below
```

`make install` installs the runtime plugin, companion tools, and generated
command and option completions under the selected prefix:

```text
bin/tj-fence
bin/tj-grep
bin/tj-tape
share/tj/tj.plugin.zsh
share/bash-completion/completions/tj
share/zsh/site-functions/_tj
share/fish/vendor_completions.d/tj.fish
```

These complete static CLI syntax such as `tj <TAB>`, `tj hist --<TAB>`, and
the values of `tj grep --color=<TAB>`. Journal-reference completion remains
the responsibility of the zsh integration described below.

## Set up zsh

tj records by watching the terminal, but a pty carries a single
undifferentiated byte stream: the prompt, your keystrokes echoing back, and
a command's output all arrive as one flow with nothing marking where one
command ends and the next begins. The zsh plugin supplies those marks, and
it also canonicalizes `@41/out` as `~[@41]/out` so zsh can expand the dynamic
named directory before a command runs.

Add one line to `~/.zshrc`:

```sh
source ~/.local/share/tj/tj.plugin.zsh
```

If your zsh setup does not already include your installation prefix's
`site-functions` directory, add it to `fpath` before it runs `compinit`:

```zsh
fpath=(~/.local/share/zsh/site-functions $fpath)
```

Adjust the path for the prefix passed to `make install`. The plugin starts
with a guard on `$TJ_JOURNAL`, so outside a tj journal writer it does nothing
at all — loading it unconditionally is safe, and it costs nothing in shells
that never run under tj.

**Without this line tj still runs and your terminal still behaves normally,
but nothing is recorded** and `tj hist` comes back empty. That is the one
setup step worth not skipping.

### SSH and terminal descriptions

TJ preserves `$TERM` when it starts its shell. This matters with terminals
whose SSH support is provided by an automatically injected shell function:
that function is not inherited by the new shell unless its integration is
also sourced from the shell's startup files. For example, Ghostty may normally
make a remote session use `xterm-256color`, while plain `ssh` inside a journal
forwards `xterm-ghostty` instead.

The best fix is to install the real terminal description on each remote host,
so applications retain Ghostty's full capabilities rather than using the
`xterm-256color` fallback:

```sh
infocmp -x xterm-ghostty | ssh HOST 'tic -x -'
ssh HOST 'infocmp -x xterm-ghostty >/dev/null && echo installed'
```

The warning that an older `tic` may treat the description field as an alias is
harmless. Reconnect after installation so the remote shell initializes with
the new entry. See [Ghostty's terminfo guidance](https://ghostty.org/docs/help/terminfo)
for alternatives and platform-specific caveats.

## Create or continue a journal

Create a journal and attach a writer to it:

```sh
tj new                    # run a fresh $SHELL, writing a new journal
tj new -- zsh -f          # run a specific command instead
```

Append a later writer run to an existing journal:

```sh
tj continue 01knxf1n5ffvk9jsm8wve1pgsd
tj continue pgsd -- zsh -f
tj continue --no-replay pgsd
```

`new` always creates a fresh journal. `continue` requires exactly one existing
journal: a unique suffix is accepted, but an ambiguous suffix is refused.
Only one writer can attach to a journal at a time.

By default, `continue` first replays the journal into the terminal, then starts
the fresh shell or command. This replay is immediate: recorded pauses and
typing delays are ignored. Use `--no-replay` when the existing transcript is
already visible or should not be redrawn. Replayed bytes go directly to the
terminal and are not appended to the journal again.

Continuing is append-only, not process resumption. It starts a fresh shell or
command with the caller's current directory and environment. It does not
restore paths, environment mutations, shell state, history, jobs, file
descriptors, or processes from an earlier writer.

Starting a writer takes an explicit lifecycle command. `tj` on its own prints
help rather than putting you somewhere you did not mean to be.

Every command has focused help generated from the same command definition used
to parse it:

```sh
tj --help
tj cat --help
tj grep --help
```

Everything inside behaves as it always did. Check that recording works:

```sh
echo hello
tj hist                   # 1  0  6  -  -  echo hello
tj cat @1                 # hello
```

Each command becomes a numbered entry:

```sh
tj hist                   # number/pin, status, size, name, tags, command
tj journal list           # every journal, newest first
tj current                # this journal's id
tj last                   # the last entry that completed
```

## References

Entries have names, the way files do. TJ's shell-neutral reference form
is `@REF`; commands such as `tj cat` and `tj resolve` accept it directly. In
zsh, the canonical filesystem namespace uses dynamic named directories:

```sh
~[@42]/out                 # entry 42 of this journal
~[@build-failure]/out      # a named entry in this journal
~[@-]/out                  # the last completed entry
~[@pgsd.42]/out            # entry 42 of another journal
~[@pgsd.build-failure]/out # a named entry in another journal
```

For interactive use, `@REF` remains shorthand. When a shorthand reference is
an unquoted shell word, the accept-line widget changes only its reference
component to canonical notation:

```text
@42/out       -> ~[@42]/out
@build-failure/out -> ~[@build-failure]/out
@-/out        -> ~[@-]/out
@pgsd.42/out  -> ~[@pgsd.42]/out
```

zsh then performs its normal named-directory and filesystem expansion while
parsing the command, so ordinary programs receive full paths:

```sh
curl -s https://example.com/data.json     # entry 41
jq .items @41/out                         # read what it printed, without rerunning
diff @41/out @43/out
cat @-/cmd                                # the last command that completed
```

| TJ reference | Canonical zsh name | Names |
|---|---|---|
| `@42` | `~[@42]` | entry 42 of this journal |
| `@build-failure` | `~[@build-failure]` | the entry with that journal-local name |
| `@-` | `~[@-]` | the last entry that *completed*, never the one running |
| `@pgsd.42` | `~[@pgsd.42]` | entry 42 of another journal, by a suffix of its id |
| `@pgsd.build-failure` | `~[@pgsd.build-failure]` | a named entry in another journal |

Suffixes rather than prefixes, because every journal started in the same
millisecond shares the ULID's timestamp prefix and only the tail tells them
apart. The most recent match wins, so short suffixes are for interactive
use; anything that must stay valid should use the full id.

`~[@<TAB>` completes dynamic entry names and appends `]`.
`~[@42]/<TAB>` uses ordinary filesystem completion for `cmd`, `out`, `prompt`,
`rc`, `files/`, and published resources. The shorthand `@42/<TAB>` remains
available, including beneath assigned names. An unresolved name such as
`@someone` stays literal, so commands that use `@handles` keep working. Words
that merely contain an `@`, quoted text, and `user@host` are left alone.

The accepted line shown by the terminal and stored in zsh history uses
`~[@REF]`, never TJ's internal storage path. The journal's `cmd` preserves the
original shorthand you typed; `meta.json` keeps a diagnostic `expanded_cmd`
with the resolved filesystem path.

## Names, tags, and pins

Annotations belong to entries in one journal:

```sh
tj name @42 build-failure       # assign or replace the one name
tj name @42                     # query it
tj name --remove build-failure
tj name                         # list names in this journal

tj tag @42 bug parser           # add normalized tags
tj tag --remove @42 parser
tj tag @42                      # query tags
tj tag @40..@45 bug             # tag every existing entry in the range
tj tag                          # list tagged entries

tj pin @42
tj pin --remove @42
tj pin @40..@45                 # pin every existing entry in the range
tj pin                          # list pins
```

Names are lowercase words made from letters, digits, and internal hyphens;
they begin with a letter and are unique within their journal. One entry
has at most one name. Tags are normalized to lowercase, may also contain `.`,
`_`, and `-`, and are idempotent. Pins are idempotent markers and protect an
entry, including its output, from ordinary entry removal. They do
not define retention. Whole-journal removal is refused while any pins remain
unless `--force` is present.

Tag and pin ranges use two unqualified numeric references in the current
journal. They are inclusive and skip numbering holes. A tag range with no tag
arguments queries tagged entries in the interval; adding or removing
tags and pinning or unpinning updates every existing entry atomically.

`tj hist --tag bug --tag parser` shows entries having every requested
tag. History marks a pin with `*` after the number and shows the name and
comma-separated tags before the command.

Qualified references are read-only. You can read and complete
`@pgsd.build-failure/out`, but names, tags, pins, and entry/output
deletion may modify only `$TJ_JOURNAL`. Continue that journal first if it needs
changing; the mutation command is then recorded there like any other command.

## Removing recorded data

```sh
tj rm @42                    # the entire entry
tj rm @42/out                # output and resources derived from it
tj rm @2..@10                # every existing entry in this inclusive range
tj rm --force @42            # override a pin
tj journal rm pgsd           # prompt before removing an inactive journal
tj journal rm pgsd --force   # override pins and skip confirmation
```

Entry and output removal are current-journal-only, do not prompt, and
refuse the currently running entry. A pinned target is skipped unless
`--force` is present. Removing an entry also removes its annotations and
resources. Removing only `out` preserves `cmd`, `rc`, the entry
annotations, and other recording metadata, but removes every published
resource derived from that output. Individual published resources cannot be
removed because their bytes would still remain in `out`.

Ranges use two unqualified numeric references, are inclusive, and remove whole
entries only. Existing numbering holes and pinned entries inside a
range are skipped; `--force` includes pinned entries. A range that
includes the currently running entry is refused before any entry
is removed.

An entry removal leaves a numbering hole. The removal command itself is
already a newer entry in the same journal, so later numbers continue
upward and the hole is never reused. Whole-journal removal is allowed only
outside a tj writer, requires a unique selector, and refuses an active journal
or, without `--force`, a journal containing pinned entries.

## Showing the reference in your prompt

Inside a journal writer these are exported, so a prompt can show them without
running anything:

| | |
|---|---|
| `TJ_REF` | `@fgpc.43` — a reference to the command about to be typed |
| `TJ_NEXT` | `43` — just the number |
| `TJ_JOURNAL_SHORT` | `fgpc` — the shortest suffix naming this journal |
| `TJ_JOURNAL` | the full 26-character journal id |

`TJ_REF` is qualified by journal, so it stays valid when you type it in
another pane. Four characters of a ULID's random tail separates a handful
of journals; use `$TJ_JOURNAL` where that is not enough.

All of them are unset outside a journal writer, so a prompt that uses them is
unchanged elsewhere.

For [starship](https://starship.rs), add an `env_var` module to
`~/.config/starship.toml`:

```toml
format = '$all${env_var.TJ_NEXT}$character'

[env_var.TJ_REF]
format = '[$env_value]($style) '
style = 'dimmed white'

[env_var.TJ_NEXT]
format = '[@$env_value]($style) '
style = 'dimmed white'
```

`$all` picks it up automatically, so nothing else needs changing:

```
tj on git main via zig v0.16.0  @fgpc.43
@43 >
```

Outside a tj journal writer the variable is unset and the module renders nothing,
leaving your prompt exactly as it was.

For a plain zsh prompt:

```zsh
setopt promptsubst
PS1='[${TJ_REF}] '"$PS1"
```

Scrolling back, every command is then headed by the reference that names it.

## Giving an agent the journal

An agent invoked from a journal writer can find out what happened without
being told, and without anything being pasted or re-run. `$TJ_JOURNAL`,
`$TJ` and `$TJ_HOME` are already in its environment; the journal is plain
files; `tj hist` is a few hundred tokens and says what exists.

[skill/SKILL.md](skill/SKILL.md) teaches that. For Claude Code, from inside
your clone, so the path is right:

```sh
mkdir -p ~/.claude/skills/tj
ln -sfn "$PWD/skill/SKILL.md" ~/.claude/skills/tj/SKILL.md
ls -l ~/.claude/skills/tj/SKILL.md    # check it resolves; a dangling
                                      # symlink fails silently
```

Then let the agent run `tj`, and nothing else. Either per invocation:

```sh
cl() { claude -p "$*" --allowedTools "Bash(tj *)" | tj-fence; }
```

or once, in `~/.claude/settings.json`, after which the wrapper is just
`claude -p "$*"`:

```json
{ "permissions": { "allow": ["Bash(tj *)"] } }
```

Three details are load-bearing, each of which fails quietly:

- **`tj` must be on `$PATH`.** The rule matches the literal name, so an
  agent invoking `"$TJ"` — an expanded variable — never matches it.
- **The prompt goes before `--allowedTools`.** That flag is variadic and
  swallows every word after it, leaving no prompt: Claude then reports
  "Input must be provided either through stdin or as a prompt argument".
- **Quote a prompt containing `?` or `*`**, or zsh globs it and the command
  never runs.

A pipeline does not match a narrow rule either, which is why the skill tells
the agent to use `tj cat --tail 20` rather than piping to `tail`.

### Other agents

The journal is not Claude-specific; only the wrapper is. For
[pi](https://pi.dev):

```sh
ask() {
  command pi -p \
    --append-system-prompt ~/Devel/tj/skill/SKILL.md \
    --tools bash \
    -- "$*" | tj-fence
}
```

Three differences from the Claude wrapper:

- **Load the skill with `--append-system-prompt <file>`, not `--skill`.**
  `--skill` accepted a path that did not exist without complaining, and the
  model then answered from invention; `--append-system-prompt` puts the file
  in front of it and the answers come out right.
- **`--tools` allowlists by tool name, not by command.** `--tools bash` is
  the narrowest it goes, so pi cannot be given `tj` and nothing else the way
  `Bash(tj *)` does for Claude Code.
- **`--` before the prompt**, since messages are positional there. Name the
  function something other than `pi`, or call `command pi` inside it, or it
  recurses.

pi has its own `@file` syntax, which does not collide: the shell integration
canonicalizes `@42/out` as `~[@42]/out`, then zsh supplies a plain path before
pi sees the word.

With it loaded, a reference is optional. `@-` is the last *completed*
entry, and the agent's own invocation is still running, so it reliably
names the command you just ran:

```sh
$ curl -s https://api.example.com/thing | jq .items
$ pi what does this mean?
```

The economics are the reason to read the index first: across one journal
here, every command and status came to about 340 tokens, while every
entry's output came to 69,000. The median entry is 185 bytes and
a handful are 50K, which is what `tj hist`'s size column and `tj cat --tail`
are for.

What the journal cannot supply is intent. It records what happened, not what
you were trying to do or what you already ruled out — so the prompt still
carries the goal, exactly as in `pi explain @42`.

## Publishing an agent's answer

An agent's reply is usually markdown, and the fenced blocks in it are exactly
the parts worth keeping as files. [contrib/tj-fence](contrib/tj-fence) turns
them into published resources, which is the `| tj-fence` in the wrappers
above:

```
$ cl give me a 3-row csv of fruit and price, and a command that sums them
```csv
fruit,price
apple,1.25
...
```

$ tj cat '@2/files/1.csv' | tail -n +2 | cut -d, -f2 | paste -sd+ - | bc
4.75
```

The display is unchanged — tj strips its own markers before the terminal sees
them — and the blocks are now `@2/files/1.csv` and `@2/files/2.sh`, with mime
types taken from the fence language.

Nothing is asked of the model, deliberately. Asked to emit the control
sequences itself it refuses, which is the right instinct: writing raw escape
sequences into a terminal is what terminal injection looks like. And a
command it runs cannot emit them either, because a coding agent's shell tool
captures stdout rather than connecting it to the terminal, and `/dev/tty`
from inside that tool does not reach the journal. Marking happens in the
wrapper, on output the agent has already produced, where it needs no
permission and no cooperation.

## Searching a journal

`tj grep` searches stored command and output lines for a literal byte string:

```sh
tj grep panic                    # cmd and out in this journal
tj grep --cmd 'docker compose'   # commands only
tj grep --out 'connection reset' # output only
tj grep -i 'permission denied'   # ASCII-only case folding
tj grep --color auto panic       # highlight on a color-capable terminal
tj grep --all example.com        # every journal, newest first
tj grep -- --starts-with-a-dash
```

This is fixed-string search, not regular expressions. A matching line is
printed once with a reusable reference:

```text
@42/out: error: connection reset by peer
```

Current-journal results use short `@N/resource` references. `--all` works
outside a writer and uses full journal IDs, such as `@01K...XYZ.42/out`, so
saved results remain unambiguous. Use `--cmd` and `--out` together to select
both explicitly. Exit status 0 means at least one line matched, 1 means no
match, and 2 means invalid grep arguments or no current journal without
`--all`.

Highlighting uses GNU grep's three color modes and is off by default. `--color`
(also `--colour`) requires `never`, `auto`, or `always`, supplied either as the
next argument or with `=`. Auto enables match highlighting only when stdout is
a terminal and `TERM` indicates color support. Always emits ANSI styling even
through a pipe or redirect, while never disables it. Selected matches default
to bold red and honor the `mt` or `ms` selected-match capability in
`GREP_COLORS`.

When results go directly to a terminal inside a journal writer, TJ wraps them
in a noout region: they remain visible but the current entry records
only `<tj:noout>`, so one search does not feed the next. Redirected and piped
results are ordinary marker-free bytes.

For regular expressions, context lines, line numbers, or other ripgrep
options, use the optional `tj-grep` companion. It requires `rg`; native
`tj grep` has no external dependency.

## Reading a recording

`tj cat` prints what a reference names, resolving it itself — so it works
from bash, from a script, or from a shell that is not running under tj:

```sh
tj cat @42                # what entry 42 printed
tj cat @42/cmd            # the command line
tj cat @40..@45           # concatenate existing outputs in numeric order
tj cat --tail 20 @42      # just the end, where errors are
tj cat --head 5 @42       # just the beginning
tj cat @41 @43 | diff - -
```

`--head` and `--tail` count lines of what you would have seen. When they hide
something, tj says so on stderr, so a fragment is never mistaken for the
whole.

Cat ranges use the same inclusive, unqualified numeric syntax and skip holes.
Each selected entry contributes its default `out`, with no added
separator; `--head` and `--tail` apply to each output independently. A range
containing the currently running entry is refused, since reading and
simultaneously appending to that entry's `out` would feed back forever.
Resource-qualified and cross-journal ranges are not supported.

Piped, it renders the recording as text a person would have read: escape
sequences removed, and a progress meter that rewrote its line thirty times
reduced to the line it settled on. Straight to a terminal it writes the
bytes as recorded, so colours still render. `--plain` and `--raw` force
either behaviour.

It takes a path as readily as a reference, which is what makes `tj cat @42`
work everywhere. Inside a journal writer, unquoted shorthand becomes
`~[@42]` and zsh expands that named directory before tj executes; outside one,
tj resolves `@42` itself.

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

## Showing output without recording it

Some output is useful to see now but harmful as input to later searches or
agents. Run that command through `tj noout` from inside a journal writer:

```sh
tj noout -- command args...
```

The command keeps the caller's terminal, standard streams, environment,
working directory, arguments, exit status, and signal result. Its stdout and
stderr remain visible, but `out` contains the fixed text `<tj:noout>` once in
their place. The marker itself is not displayed or recorded.

Cooperating programs can mark only part of their output directly:

```sh
printf '\033]5107;tj;noout\033\\'
printf 'visible now, omitted from out\n'
printf '\033]5107;tj;end\033\\'
```

Resource and noout regions share the same non-nesting OSC 5107 state. The
generic `end` closes whichever kind is open, and an unfinished noout region is
discarded when the entry ends so it cannot suppress the next command.
`--keep-osc` forwards TJ's markers for protocol debugging, but they are still
never written to `out`.

This is an explicit recording control, not a secrecy boundary. TJ does not
infer it from the PTY's ECHO flag: password input with echo disabled is already
absent from output, while many non-secret interactive programs also disable
echo. A tool such as `tj-grep` may emit the markers itself when its displayed
results should not feed later searches.

## Publishing resources

A program can mark spans of its own output as named files. The output still
appears on the terminal exactly as it would; tj additionally exposes the
marked spans under the entry.

```sh
printf '\033]5107;tj;begin;files/data.csv;text/csv\033\\'
printf 'date,amount\n2026-08-01,12.50\n'
printf '\033]5107;tj;end\033\\'
```

That entry then holds `@42/files/data.csv`, addressable and
completable like any other resource, and usable by anything:

```sh
sh @42/files/script.sh < @42/files/data.csv
```

The point is that a program which prints a table, a diff or a script can
make it directly reusable without inventing a side channel or a structured
output mode. Plain text stays the interchange format; the marks only add
addressability.

Publishing and noout use one non-nesting region state. A begin marker received
while either kind is already open is refused; the first region remains open
until the next generic end marker.

Names are the program's choice, so they are checked: a name cannot escape
its entry directory, and cannot be `cmd`, `out`, `prompt`, `rc`, `meta.json` or
TJ's private removal bookkeeping. Refusals are recorded in the journal log. `files/` is a convention,
not a rule — `err` is a resource too.

Line endings are normalised: a program writes `\n`, the terminal turns it
into `\r\n` in transit, and the resource gets back the `\n` the program
meant, so a published script is executable.

Binary works too. The normalisation is the exact inverse of the terminal's
translation, so data that really contains `CRLF` survives it, and a PNG
round-trips byte for byte. Two caveats: data containing tj's own end marker
ends the resource there, which no in-band protocol without escaping can
avoid; and a terminal with `oxtabs` set expands tabs before tj sees them,
which cannot be undone. The bytes still reach your screen and will make a
mess of it, exactly as they would without tj.

## Replaying a journal

`tj replay` plays a recording back into the terminal — the prompt, the command
typing itself out, then the output as it was captured, colours and all. With
the zsh plugin, each entry keeps the exact prompt bytes zsh rendered
before it: prompt substitutions, Starship output, colours, multiple lines, and
the right prompt are replayed rather than evaluated again. Older journals use
`$ ` as a fallback. Non-visual background-colour and cursor-position queries
are omitted so their terminal replies cannot become shell input:

```sh
tj replay                     # the most recent journal
tj replay fgpc                # another, by a suffix of its id
tj replay fgpc --from 4 --to 9 --speed 2
```

**Replay only runs outside a journal writer.** Inside one, the recording would be
fed back into the journal: the replayed shell-integration markers read as
real command boundaries, which truncates the recording of the replay itself
and pins the replayed exit status onto it — and `tj hist` shows a
plausible-looking entry, so nothing tells you. So exit the writer first, or
replay from another pane. With no journal named, the most recent one plays.

Nothing is re-executed. What cannot be reconstructed is *when* each byte
arrived, since only the start and end of each entry were recorded — so
output appears at once, and the pacing comes from the real command durations
and the real gaps between commands. Those gaps get capped (`--max-pause`,
default 2s), because a journal where you stared at the screen for a minute
does not make a watchable demo.

| | |
|---|---|
| `--speed X` | divide every delay |
| `--typing MS` | per character of the command line; `0` shows it at once |
| `--max-pause MS` | longest single pause, however long the real one was |
| `--prompt S` | override every captured prompt; also the fallback for entries without one |
| `--from N` `--to N` | replay part of a journal |
| `--duration` | print the seconds it would take, and play nothing; allowed inside a journal writer, since it emits no recording |

For a GIF, [contrib/tj-tape](contrib/tj-tape) emits a
[vhs](https://github.com/charmbracelet/vhs) tape that records the replay:

```sh
tj-tape fgpc demo.gif --speed 2 --from 4 --to 9 > demo.tape
vhs demo.tape
```

The tape plays the recording rather than re-running the commands, so the GIF
shows what actually happened — and a journal containing `rm -rf` does not
re-run it to make a demo. It asks `tj replay --duration` how long the replay
takes, since vhs cannot wait for a process to exit.

## Storage

The journal is plain files under `~/.tj` (override with `$TJ_HOME` or
`--home`), so nothing needs to understand tj to read it:

```
~/.tj/<journal-ulid>/42/
├── cmd        the command line as entered
├── out        what you could scroll back to, escape sequences and all
├── prompt     exact rendered zsh prompt; absent in older journals
├── rc         exit status; absent means the command never finished
└── meta.json
```

Journal-local user annotations are separate from recording metadata:

```text
~/.tj/<journal-ulid>/annotations.json
```

The versioned file maps entry numbers to their optional name, sorted
tags, and pin. It is replaced atomically under one short-lived journal mutation
lock, so concurrent annotation child processes cannot lose one another's
updates. Copying or deleting a journal carries its annotations with it.

Writer coordination uses private `~/.tj/.locks/<journal-ulid>` files. The
file's held advisory lock—not its mere presence—indicates a live writer.
Read-only commands remain available while that lock is held.

Directories are `0700` and files `0600`: the journal holds whatever
appeared on your terminal, so treat it like shell history.

Journals outlive every writer process attached to them — that is the point, and
`@pgsd.42/out` is meant to keep working after the pane it belonged to is
gone. Entry numbering resumes at one greater than the highest existing
numeric directory. An unfinished entry has no `rc`, but still consumes
its number; gaps are never filled.

A journal newly created by `tj new` may be removed when that writer records
nothing. An existing journal opened by `tj continue` is never deleted merely
because the new writer was empty. A journal that logged why it could not
record is also kept, because that log is the explanation.

## Development

```sh
make              # native debug build
make check        # fmt + tests, the gates every change must pass
zig build test    # the tests alone: unit, plus pty-driven end to end
```

The build uses a host-only `tj-completion` helper to generate ready-to-install
bash, zsh, and fish scripts in `zig-out/share`. The helper itself is neither
installed nor included in release archives.

Cross-compiles with nothing installed on the host:

```sh
make list         # the target list
make -j6 all      # every target -> dist/<target>/bin/tj
make package      # complete install trees as dist/tj-<version>-<target>.tar.gz
```

Targets: `{aarch64,x86_64}` × `{macos, linux-musl, linux-gnu}`. The musl
builds are static. Override `OPTIMIZE` (default `ReleaseSafe`) or `ZIG`
to change how they are built.

The build fetches the exactly pinned, std-only Zecli 0.2.0 source package on
first use. Zecli is compiled into `tj`; release binaries remain self-contained
and have no Zecli runtime dependency.

The proxy uses `std.posix` wherever Zig 0.16 provides the call. Process
control, `ioctl`, and the pty grant/unlock sequence have no `std`
equivalent in this release, so `src/sys.zig` declares them against plain
libc—no libutil or any other add-on runtime library—which keeps cross builds
self-contained.

## Status

The proxy is transparent: `tj new -- <command>` is indistinguishable from
running the command directly. The pty is allocated and sized from the outer
terminal, both byte streams are forwarded unchanged, `SIGWINCH` propagates,
signals sent to `tj` reach the shell, and the terminal is handed back with
its original settings on every exit path.

Recording works for `cmd`, `out`, `prompt` and `rc`; zsh canonicalizes interactive
`@REF` shorthand into the `~[@REF]` dynamic named-directory namespace, then
resolves and completes it through normal filesystem behavior. Selecting,
locking, and numbering a journal are strict startup requirements and fail
before the child starts. After acquisition, individual recording failures are
logged while the PTY keeps forwarding.

Full-screen programs are kept out of the journal, and `tj cat` reads a
recording back as either bytes or plain text.

Programs can publish spans of their output as named resources. All four
milestones in the implementation spec are done; [TODO.md](TODO.md) keeps the
remaining open ends.
