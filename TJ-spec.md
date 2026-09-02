# Terminal Journal (TJ)

*A proposal for making terminal entries persistent, addressable,
and reusable.*

------------------------------------------------------------------------

# Motivation

Unix shells are excellent at **executing** commands, but comparatively
poor at **remembering** them.

Traditional shell history stores commands:

``` sh
git status
go test ./...
kubectl get pods
```

while terminal scrollback stores a transient rendering of their output.

Once output scrolls away, it becomes difficult to reference, reuse, or
discuss. Users resort to screenshots, copy/paste, temporary files, or
rerunning commands.

A **Terminal Journal** treats every command as a first-class journal entry.

Rather than viewing the terminal as a stream of characters, TJ models it
as an append-numbered journal of computational entries. Numbers are never
reassigned; explicit removal may leave holes.

Each entry receives an identifier. Journal references use `@N`;
`@-` refers to the immediately preceding entry.

Every entry exposes core resources:

``` text
@42/
├── cmd
├── cwd
├── out
├── prompt
└── rc
```

`cmd` is the command line as entered. `cwd` is the absolute logical `$PWD` at
the command boundary, stored without a trailing newline; it is absent in
journals recorded without cwd-aware shell integration. `out` is the terminal output as
rendered: the bytes the program wrote to the tty, including escape
sequences. `prompt` is the exact terminal byte sequence zsh rendered before
the command, including dynamic prompt-engine output; it is absent in journals
recorded without prompt-aware shell integration. `rc` is the exit status.

Programs may also mark semantic spans within their output as named
resources:

``` text
@42/
├── cmd
├── cwd
├── out
├── prompt
├── rc
└── files/
    ├── data.csv
    └── script.sh
```

This notation is shared with `stash`, which also uses `@N` for relative
references, so the two tools compose without a mental mode switch.

The terminal becomes something closer to a filesystem of previous
computations than a disposable scrollback buffer.

------------------------------------------------------------------------

# 1. New User Flows

## Post-hoc composition

Today, Unix pipelines must be designed before execution.

``` sh
curl ... | jq ...
```

With a Terminal Journal, composition can happen afterwards.

``` sh
$ curl ...
$ jq . @42/out
```

or

``` sh
$ pi use @42/out to summarize the response
```

The output has already been captured and can be reused without rerunning
the command.

Note that `@42/out` is what the terminal saw, not what a pipe would have
seen. Programs that detect a tty may emit colors, progress meters, or
column layouts. TJ does not try to hide this. If a user needs
pipe-clean output, the answer is the same as it has always been: use a
pipe.

## Addressable history

Instead of saying:

> Look at the error above.

users can write:

``` sh
pi explain @87
```

or

``` sh
diff @42/out @87/out
```

Entries become stable references rather than anonymous text.

## Computational objects

Commands no longer produce only terminal output.

They produce reusable objects.

The core resources are directly addressable:

``` text
@103/cmd
@103/cwd
@103/out
@103/prompt
@103/rc
```

Programs can additionally expose meaningful parts of their output as
named resources:

``` text
@103/
├── cmd
├── cwd
├── out
├── prompt
├── rc
└── files/
    ├── data.csv
    └── script.sh
```

These resources can be consumed later by ordinary CLI tools:

``` sh
python @103/files/script.sh
cat @103/files/data.csv
```

## A second namespace

Unix currently has one universal namespace:

``` text
/etc/passwd
src/main.go
```

A Terminal Journal introduces another:

``` text
@42/out
@42/files/data.csv
@-/out
```

One namespace represents persistent files.

The other represents previous computations.

------------------------------------------------------------------------

# 2. Working with Agents

Today's coding agents typically create their own execution environment.

``` text
Agent
 └── Shell
```

A Terminal Journal suggests the opposite architecture.

``` text
Shell
 ├── Git
 ├── Docker
 ├── Go
 ├── Vim
 └── Agent
```

The shell remains the execution environment.

The agent becomes another CLI tool.

## The journal as context

Users work normally.

``` sh
git pull
go test
vim parser.go
go test
```

When reasoning is needed:

``` sh
pi explain @42
```

The agent receives the referenced journal entries as context.

The journal becomes the long-lived memory.

The agent becomes stateless.

## Composing across time

``` sh
pi use the code from @100/code to parse @300/out
```

The terminal resolves both references before invoking the model.

Unlike Unix pipes, the dependency graph is no longer constrained by
execution order.

## Interchangeable agents

``` sh
claude explain @42
codex optimize @42
gemini review @42
```

Every model receives identical context because the context belongs to
the journal rather than the model.

------------------------------------------------------------------------

# 3. Proof of Concept

## Semantic PTY proxy

A first implementation does not require modifying a terminal emulator.

``` text
Ghostty
   │
   ▼
tj
   │
   ▼
zsh
```

The proxy:

1.  Allocates the pseudo-terminal.
2.  Transparently forwards terminal traffic.
3.  Records entries.

A PTY carries a single byte stream: the program's stdout and stderr are
already merged by the time TJ sees them. TJ therefore does not attempt
to separate them. There is no `err` core resource; a program that wants
to expose its errors as a distinct resource can do so with OSC ELLO
(see below).

## Journals and numbering

A journal is a durable named directory. A `tjctl` writer process is temporary
and attaches to one journal. Canonical names are 1–63 bytes, begin and end
with a lowercase ASCII letter or digit, and otherwise contain lowercase ASCII
letters, digits, or hyphens. Dots are forbidden because they separate a
journal selector from an entry selector.

`tjctl new [NAME]` creates a journal. Without `NAME`, it generates
`YYMMDD-RANDOM`: a UTC date, hyphen, and six lowercase Crockford characters.
The date is a human clue only; journal identity, ordering, and retention never
derive from it. A collision is retried for a generated name and rejected for
an explicit name.

Continuation is append-only. It launches a fresh shell or requested command
using the caller's cwd and environment. It restores no cwd, environment,
shell options, functions, history, jobs, file descriptors, processes, or
other state from previous writers.

`tj-new` and `tj-use` are zsh helpers supplied by `tj.plugin.zsh`. Outside a
writer they delegate to `tjctl new/use`. Inside a direct TJ shell, they do not
nest a second proxy: `tjctl` emits private `OSC 3110;HANDOFF` control traffic
after standard locked target selection succeeds, and the active proxy moves
recording to that target while zsh remains running. `tjctl new/use` themselves
reject in-writer use and direct the user to the helpers. A failed target
selection leaves the source writer running. Handoff is rejected from tmux and
GNU Screen and does not accept `--home` or a child command after `--`.

`tjctl new --temp` makes a journal temporary. The active proxy removes an
unsaved temporary journal when its writer ends or hands off. `tjctl save`
emits private `OSC 3110;SAVE` control traffic; the proxy removes the
journal-local temporary marker and the journal then remains persistent.

Interactive writers show the startup splash unless `--no-splash` is present
or inherited `TJ_NO_SPLASH` parses as true (`true`, `yes`, or `1`; false forms
are `false`, `no`, and `0`). Non-interactive writers do not
show it.

After the startup splash has been dismissed and before launching that fresh
child, `tjctl use` replays the selected journal to the outer terminal by
default. It uses the ordinary replay rendering, but
with command typing delays, recorded command durations, and gaps all set to
zero. Non-visual background-colour and cursor-position queries are suppressed
so their terminal replies cannot become input to the fresh child. OSC 0, OSC 1,
and OSC 2 window and tab-title changes are also omitted, including markers
split across reads, so replay cannot replace the title selected for the new
writer. Standalone BEL bytes are omitted so historical alerts do not fire
again; BEL remains intact when it terminates an OSC sequence. The replay
bypasses the new writer's scanner and is not recorded again. `--no-replay`
suppresses this startup replay.

`tjctl new` and `tjctl use` accept one `-t`/`--title FORMAT`. An explicit format
takes precedence; otherwise `TJ_TITLE` is read from the environment, followed
by the default literal format `TJ | %3~`. `none` disables all TJ title
handling. The writer exports the selected literal format as `TJ_TITLE`. On a
terminal, an enabled writer pushes the previous title and initially displays
`JOURNAL`; the blinking marker makes the recording indicator independent of
shell integration. The zsh plugin evaluates `TJ_TITLE` with zsh's nested shell
expansion at each prompt, allowing
parameter, arithmetic, and command substitutions, then applies zsh prompt
expansion so escapes such as `%3~` work. It removes BEL, ESC, and C1 ST from
the result and emits that exact result with OSC 0, updating both the window and
icon/tab title on terminals that distinguish them. At `preexec`, the plugin
emits `COMMAND`, using the original typed command with control bytes
removed and without evaluating it as shell or prompt syntax. Later title
changes from the running application become the current title, and the next
prompt restores the configured format. The previous title is restored on
normal, signal, and panic exits. `none` emits no fallback, performs no
title-stack operation, and makes the plugin leave titles alone.

Title handling defaults to a 1500 ms recording-marker interval. An explicit
`--title-blink=MS` takes precedence over
`TJ_TITLE_BLINK`, followed by `1500`; the selected decimal value is exported
as `TJ_TITLE_BLINK`. A positive interval makes the proxy intercept complete,
bounded OSC 0, OSC 1, and OSC 2 sequences, retain separate last window and
icon/tab titles, and forward them with alternating fixed-width `●` and `○`
prefixes. It redraws the last titles on that interval from the existing proxy
poll loop. The original sequences, rather than the decorated ones, remain in
`out`. An oversized or unrecognized sequence remains byte-transparent.
`--title-blink=0` disables interception, decoration, and periodic refresh.
`TJ_TITLE=none` disables the entire title lifecycle and exports a blink
interval of `0`; an explicit blink value is still syntax-checked.

Entries start at 1. Every later writer starts at one greater than the
highest valid numeric entry directory. A missing `rc` means unfinished,
but that directory still consumes its number. Gaps are never filled and old
entries are never overwritten.

At most one cooperating writer may attach to a journal. A nonblocking,
exclusive advisory lock in `~/.tj/.locks/<journal-name>` is held for the
writer's lifetime and is closed on exec in the child. Readers do not take
this lock. Locking, selection, and number exhaustion fail before the child is
started.

Journal-directory identity changes use advisory locks in this fixed order:

``` text
root namespace
  -> source lifetime writer lock
  -> source exclusive mutation lock
  -> destination lifetime writer lock (rename only)
```

Creation owns the namespace and destination lifetime name before exposing the
new directory. Whole-journal removal and rename hold the namespace while they
resolve the exact/unique source and prove it inactive. Rename validates an
absent destination, acquires its lifetime name, and atomically renames the
complete directory on the same filesystem. That rename is the identity commit
point: failures before it leave the old journal usable; afterward the complete
journal exists under the new name. Old unlocked lock files are removed
best-effort. A visible journal is never copied piecemeal.

The two flat command surfaces are explicit:

``` text
tj tui
tj hist|cat|grep|name|tag|pin|rm|last|resolve|complete|noout ...

tjctl new [options] [NAME] [-- COMMAND...]
tjctl use [options] JOURNAL [-- COMMAND...]
tjctl ls [-l] [-n NUMBER]
tjctl mv JOURNAL NEW-NAME
tjctl rm JOURNAL [--force]
tjctl du [JOURNAL] [--chart] [--bytes]
tjctl replay JOURNAL [options]
tjctl current
tjctl complete [PREFIX]
```

Each binary has its own compile-time-validated flat command schema. `tj` owns
entry and resource operations; `tjctl` owns journal lifecycle and management.
Commands are not aliased between the two binaries. A bare command or `--help`
prints application help, and `COMMAND --help` prints command help. Help is
written to standard output and returns status 0.

Command options accept `--option value` and `--option=value` when the option
requires a value. A required-value option without one is invalid; there is no
implicit value for options such as `grep --color`. `--` ends TJ option parsing
where a command accepts dash-prefixed operands. For `tjctl new` and `use`, it
is the only way to begin child argv. Thus `tjctl new make` creates the journal
named `make`; it does not execute `make`. For `noout`, the separator is also
mandatory. Neither binary parses options in child argv after that boundary.

Every command enforces the arity in its published usage. Unknown commands,
unknown options, missing option values, and missing or extra operands are
command-line usage errors: they print the relevant generated help to standard
error and return status 2. Operational and storage failures retain status 1,
as do commands with a documented negative result such as a grep with no
matches.

The writer exports `TJ_JOURNAL`, `TJ_NEXT`, `TJ_TITLE`, `TJ_TITLE_BLINK`,
`TJ_HOME`, `TJ`, and `TJCTL`. The title variables have the format and interval
semantics above. `TJ` is the sibling entry binary when installed beside
`tjctl`, with the literal command name as a development fallback; `TJCTL` is
the running control binary.
The zsh integration derives `TJ_REF` as
`@${TJ_JOURNAL}.${TJ_NEXT}`. These variables describe the selected durable
journal and its next unused entry; they are not a snapshot of prior process
state.

Within the current journal, `@42` refers to entry 42. To refer to
an entry in another journal (for example, another terminal pane,
or a journal that has already ended), the reference is qualified with
the journal's complete canonical name or an unambiguous suffix:

``` text
@42/out                                  entry 42, current journal
@build-failure/out                       named entry, current journal
@release-build.42/out                    entry 42, complete journal name
@build.42/out                            same, using a unique suffix
@release-build.build-failure/out         named entry in that journal
@-/out                                   previous entry, current journal
```

Every journal selector follows one rule: an exact valid directory name wins;
otherwise exactly one canonical name must end with the selector. Zero matches
return `NoSuchJournal`, and multiple matches return `AmbiguousJournal`.
Matching is lowercase and case-sensitive. This applies to reads, `use`, `mv`,
`rm`, `du`, replay, history, completion, and zsh dynamic directories. Printed
cross-journal references always use the complete name. `tjctl mv` is an
intentional identity change and leaves no alias, so old qualified references
stop resolving.

`tj grep --all` traverses journals in ascending lexicographic canonical-name
order. Directory names have no chronological meaning. `tjctl replay` therefore
always requires a journal selector.

`tjctl ls` orders journals by their latest remaining completed-entry timestamp,
newest first, with canonical name as the tie-breaker and journals without valid
timing metadata last. Its default form prints one complete name per line. `-l`
adds the current-journal marker, entry count, and first- and last-entry UTC
dates. `-n NUMBER` limits either form after sorting. `tjctl current` prints the
complete `TJ_JOURNAL` value and fails outside a writer. `tjctl du` retains
logical-byte, chart, color, and noout behavior described below. `tjctl replay`
retains the recorded-prompt, range, pacing, duration, and inside-writer rules;
only its mandatory selector and command owner change. `tjctl rm` prompts on a
terminal unless forced, refuses pins unless forced, and never removes an active
journal. `tjctl mv` never prompts, refuses active sources and existing destinations,
and preserves the directory's entries, resources, database, sidecars, logs,
and private trash without editing their contents.

An all-digit reference (`@42`) always means the current journal and is
never interpreted as a suffix.

An entry name begins with lowercase ASCII, contains only lowercase
ASCII, digits, and internal hyphens, ends with lowercase ASCII or a digit, and
is at most 63 bytes. It is therefore disjoint from numbers and `@-`. A dot
separates a journal selector from a numeric or named entry selector.
Names are resolved from the selected journal's annotations. An unassigned
name is unresolved.

## Zsh integration

A small zsh plugin provides two functions:

1.  semantic command boundaries for the journal
2.  resolution and completion of the journal namespace

### Command boundaries

The plugin uses `preexec`, `precmd`, and a composable `zle-line-init` hook,
augmented by OSC 133 shell integration, to tell TJ when an entry starts
and finishes. `precmd` emits `OSC 133;A ST` immediately before zsh renders a
prompt. Once zsh has painted `PROMPT` and `RPROMPT`, `zle-line-init` emits
`OSC 133;B ST`. TJ retains the intervening terminal bytes as the prompt for
the next command that actually starts. It does not read or re-evaluate prompt
variables, so prompt substitutions and external engines such as Starship are
captured exactly as displayed.

At `preexec`, the plugin emits one `OSC ELLO;CONTEXT;PAYLOAD ST` marker, where
`ELLO` is the mnemonic for numeric OSC code 3110. `PAYLOAD` is the base64
encoding of an ASCII header followed by its three concatenated fields:

``` text
1;<cmd-bytes>;<cwd-bytes>;<expanded-flag>;<expanded-bytes>;<cmd><cwd><expanded>
```

Lengths count bytes; the flag is `0` or `1`. This preserves arbitrary command
text without letting field contents collide with the envelope. The recorder
strips the marker, uses the decoded fields when the following `OSC 133;C` opens
the entry, and writes `cwd` without a trailing newline. Continuing a journal
does not restore this directory.

If `OSC 133;C` arrives without a preceding TJ command-line marker, the
recorder still opens an entry with an empty `cmd` and writes one journal
warning during that writer run. An explicit marker containing an empty command
line is present and does not trigger the warning.

The pending prompt is replaced if zsh draws another prompt before a command
starts, and an unfinished prompt is discarded at the command boundary. The B
marker itself is not stored in `prompt`. Prompt capture is bounded at 64 KiB;
exceeding that limit omits the resource and records a journal warning. The
`zle-line-init` callback is registered through `add-zle-hook-widget`, preserving
existing callbacks and avoiding duplicate registration.

Each completed entry becomes a journal entry:

``` text
@42/
├── cmd
├── cwd
├── out
├── prompt
└── rc
```

### Journal namespace

TJ references are shell-neutral identifiers accepted by TJ commands:

``` text
@10
@build-failure
@release-build.10
@release-build.build-failure
@-
```

The canonical zsh filesystem namespace uses dynamic named directories. The
name inside the brackets identifies an entry directory; resource paths
are ordinary filesystem suffixes:

``` text
~[@10]/out
~[@build-failure]/out
~[@10]/files/data.csv
~[@release-build.10]/out
~[@release-build.build-failure]/out
~[@-]/out
```

Ordinary programs do not need to understand either form. zsh expands the
canonical dynamic named directory during normal command parsing and passes an
ordinary filesystem path to the program.

Conceptually:

``` text
~[@10]/out                 → ~/.tj/<journal>/10/out
~[@10]/files/data.csv      → ~/.tj/<journal>/10/files/data.csv
~[@release-build.10]/out   → ~/.tj/release-build/10/out
~[@-]/out                  → ~/.tj/<journal>/<previous>/out
```

Thus:

``` sh
cat ~[@10]/out
```

is executed equivalently to:

``` sh
cat ~/.tj/<journal>/10/out
```

and `cat` remains completely unaware of TJ.

This is zsh named-directory expansion rather than a parallel emulation:

``` text
~name/path       static named filesystem location
~[@N]/path       dynamic named journal entry
```

For interactive convenience, an accept-line widget canonicalizes valid,
unquoted shorthand at the start of shell words. It changes only the reference
head and preserves the resource suffix:

``` text
@10/out       → ~[@10]/out
@build-failure/out → ~[@build-failure]/out
@-/out        → ~[@-]/out
@release-build.10/out  → ~[@release-build.10]/out
```

Quoted references, malformed references, and words such as `user@host` are
unaffected. A syntactically valid named shorthand is rewritten only after
`tj resolve` confirms that the name is assigned; unresolved `@handles` remain
literal. Explicit `~[@REF]` input is already canonical and is not rewritten.
The widget never inserts a storage path. Its canonical buffer is what the
terminal accepts and zsh history stores.

The plugin registers its handler by appending it once to
`zsh_directory_name_functions`; it does not replace the special
`zsh_directory_name` function or other array handlers. In `n` mode it accepts
an `@` name, calls `tj resolve` for that entry reference, and returns the
entry directory as the single global `reply` element. `d` mode is not
implemented and returns failure, so paths are not abbreviated back to names.

`preexec` runs before dynamic named-directory expansion. Its first argument is
the accepted/history line; its third argument is the full executable shell
text with aliases expanded, but it still contains `~[@REF]`. The widget saves
pre-canonical shorthand in `_TJ_TYPED`, which is recorded as `cmd`. For
`expanded_cmd`, the plugin starts from `$3` and safely resolves only unquoted
canonical TJ directory tokens for diagnostic metadata. It never evaluates the
command line, and zsh remains solely responsible for the expansion used by the
actual process.

The plugin defines `tjcd REF` as a zsh function because a subprocess cannot
change its parent shell's directory. For a simple `tjcd @REF` line, the
accept-line widget exempts the target from shorthand canonicalization. The
function resolves the literal reference. In compound command lines and for an
explicit `tjcd ~[@REF]`, zsh may instead pass the already-expanded entry
directory; the function accepts that form directly. It then reads `cwd`,
requires an absolute path naming an existing directory, and invokes
`builtin cd --`. Qualified references work when no current journal is active.
Missing `cwd` resources in older entries are reported rather than inferred.

### Completion

Dynamic-directory `c` mode completes entry names inside `~[...]` and
appends the closing bracket:

``` sh
cat ~[@<TAB>
```

Once the bracket is closed, ordinary zsh filesystem completion operates on
the resolved entry directory. For example:

``` sh
cat ~[@10]/<TAB>
```

can offer:

``` text
cmd  cwd  files/  out  prompt  rc
```

and:

``` sh
cat ~[@10]/files/<TAB>
```

can offer resources published by the program.

The global shorthand completer remains available for `@10/<TAB>`. Normal zsh
completion runs before that fallback so dynamic named-directory and ordinary
filesystem completion retain their native behavior.

The installed command-completion scripts use `tj complete` for positional
entry-reference arguments accepted by TJ commands. Thus `tj cat @10/<TAB>`
and the equivalent reference positions in `hist`, `resolve`, `name`, `tag`,
`pin`, and `rm` use the same journal-local candidates in bash, zsh, and fish.
This is separate from zsh's global shorthand fallback, which completes
references in arbitrary command lines.

A separate generated completion set serves `tjctl`. Journal operands for
`use`, the source of `mv`, `rm`, `du`, and `replay` call `tjctl complete` and
receive complete canonical names matching the typed prefix.
The `new` name and `mv` destination are free new names and do not complete
existing journals. Bash, zsh, and fish scripts for both binaries are installed;
the host-only generator is not a runtime program.

Numeric and assigned-name candidates are offered in both completion paths.
Resources below a named entry complete exactly as resources below its
numeric identity.

The suffix after `~[@REF]` has ordinary filesystem semantics, including `.`
and `..`. This differs deliberately from `tj resolve @REF/subpath`, whose
shell-neutral reference subpath remains containment-validated by TJ.

This makes the journal namespace behave like a filesystem from the
user's perspective while allowing TJ to change its underlying storage
implementation later.

## Entry annotations

Names, tags, and pins are user annotations on one entry in one journal.
They are not recording-time metadata and are never stored in an entry's
`meta.json`.

``` text
tj name @42 build-failure
tj name @42
tj name --remove build-failure
tj name

tj tag @42 bug parser
tj tag @42 @47 @50..@55 bug parser
tj tag --remove @42 @47 parser
tj tag @42 @47
tj tag @40..@45 bug
tj tag

tj pin @42
tj pin --remove @42
tj pin @40..@45
tj pin
```

One entry has at most one name. Assigning another name renames it; a
name already owned by another entry in the same journal is rejected.
The same name may exist independently in another journal.

Tags are 1-63 ASCII bytes and normalize to lowercase. Their first and last
bytes are alphanumeric; interior bytes may additionally be `.`, `_`, or `-`.
Adding an existing tag and removing a missing tag are successful no-ops. Tags
are stored uniquely and sorted. `tj hist --tag TAG` is repeatable and multiple
filters use AND semantics. `tj hist --pinned`, with `--pin` as an alias,
restricts history to pinned entries and combines with every tag filter using
AND semantics.

With no operands, `tj hist` selects every entry in the current journal. With
operands, it accepts entry references, inclusive unqualified numeric ranges,
and journal selectors, processing them from left to right. A journal selector
has the form `@SUFFIX.`; the trailing dot distinguishes the journal itself
from `@NAME.ENTRY`. Bare journal names and suffixes are not accepted. Ranges
skip numbering holes and fail when they select no existing entry. Entries
selected from another journal use `@SUFFIX.N` in the reference column so a
mixed listing remains unambiguous.

History renders each entry as:

```text
[flags] [entry-reference] [out-size] [UTC date] command @name #tag !N
```

`flags` is exactly four positional cells: `*` when pinned, `@` when named,
`#` when tagged, and `!` when the exit status is nonzero, with a space for each
absent property. Entry reference and size are
right-aligned across the selected entries, and every column is separated by
one space. Size is the logical byte length of
the `out` resource, formatted in powers of 1024 with `b`, `k`, `M`, `G`, and
larger suffixes; `-` means the resource is absent and `0b` means present but
empty. The 12-cell date uses the
recorded UTC start time, showing `Mon DD HH:MM` during the current UTC year and
`Mon DD  YYYY` otherwise; missing or malformed timing is `--- -- --:--`.
The optional name is `@name`, each tag is `#tag`, and a nonzero exit status is
`!N`. Continuation lines begin beneath the command
field. Non-terminal output keeps the same fields on one physical line without
presentation styling. On a color-capable terminal, `*`, `@`, and `#` keep the
default foreground, while a present `!` is red. Numbers are yellow, sizes and
name/tag metadata are green, dates are blue, and failures are red.

For terminal output, TJ obtains the width with `TIOCGWINSZ`, reserves the fixed
columns, and word-wraps the command and suffix in the remaining cells.
Oversized words are hard-wrapped. When stdout is a terminal and a current
journal exists, history lazily encloses the listing in one OSC ELLO `NOOUT`
region. No markers are emitted when filters select no entries. Redirected or
piped history is one physical line per entry, with no styling or OSC markers.
Before layout, recorded command text is sanitized as untrusted terminal input:
escape sequences, unsafe control bytes, and encoded C1 controls are removed;
horizontal tab and valid UTF-8 are preserved, and malformed UTF-8 is replaced.
Width calculation, wrapping, and styling operate only on that safe text. ANSI
sequences emitted by history itself are therefore the only terminal controls
in the rendered listing.

`tjctl du [JOURNAL]` reports the selected journal's total logical byte length,
or the current journal when no selector is supplied, formatted
with the same base-1024 `b`, `k`, `M`, `G`, and larger suffixes as history.
Logical length is the sum of file lengths, not allocated filesystem blocks;
directory metadata is not counted, symlinks are not followed, and their link
length is counted. The total includes journal-level files as well as entries.

`tjctl du --chart` prints that total followed by one row for every valid
numeric entry directory, sorted by entry number. An entry row sums every file
beneath that entry, including core and published resources. The largest entry
fills the available terminal width; every nonempty smaller entry receives at
least one full-block chart cell, and an empty entry has no bar. Journal-level
files contribute only to the total. Terminal output uses a noout region and
automatic color subject to `NO_COLOR`, except that bars retain the terminal's
default foreground; redirected output has neither styling nor OSC markers and
uses an 80-column chart width.

`tjctl du --bytes` without `--chart` emits one `@ENTRY BYTES` row per valid
numeric entry, in entry order, using exact decimal logical byte counts and no
total row. When a selected journal differs from the current journal, entry
references use its complete canonical name. With `--chart`, `--bytes`
preserves the chart layout and bars but
formats both the journal total and every entry size as exact decimal bytes
instead of compact human-readable units.

A pin is an idempotent boolean annotation. It appears as `*` beside the
entry number in history. Pins protect entries and their output
from entry-level removal unless `--force` is present. They have no
retention semantics. Whole-journal removal is refused while pins remain unless
`--force` is present.

`@N..@M` selects the inclusive numeric interval in the current journal for
`tag` and `pin`. Endpoints are unqualified numeric references with `N <= M`;
names, `@-`, resources, and qualified journals are invalid. Missing numbers
inside the interval are skipped. Tagging, untagging, pinning, and unpinning
use one database transaction, so the selected existing entries in one range
change atomically.

`tj tag` accepts one or more leading entry or range targets, followed by one
or more tags. Literal references begin with `@`, which is not valid in a tag;
zsh-expanded targets are paths beneath the journal root and remain equally
distinct. With no trailing tags, every target is queried. Multiple targets
are processed from left to right, while each range is processed atomically;
range query results appear in numeric order.

Targeted name and tag queries may read qualified references. Every annotation
write is restricted to the journal whose complete name is in `TJ_JOURNAL`.
Syntactically qualified references and canonical paths belonging to another
journal are rejected before mutation. To annotate another journal, a user
continues it and runs the annotation command there.

### Interactive entry browser

`tj tui` is the full-screen frontend for entry history and annotations. It
accepts no operands, requires both stdin and stdout to be terminals, and
requires a nonempty `TJ_JOURNAL`. It never selects another journal. The
running entry that invoked the browser is excluded, and the initial cursor is
the highest remaining entry number.

The browser retains only the numeric index. It reads commands, sizes, status,
and annotations for visible rows when rendering rather than keeping every
command resident. Recorded command text passes through the same control-byte
sanitizer as history before reaching the terminal. Rows use history's four
annotation/failure flags, entry number, compact output size, command, name,
tags, and nonzero status.

Arrow keys and `j`/`k` move; Home/`g`, End/`G`, Page Up, and Page Down navigate
the index. Space toggles the focused entry's selection state. Shift+Up/Down
starts an inclusive range at the current row and extends or shrinks it as the
cursor moves. Entries individually selected before the range remain selected.
Escape clears the complete selection in normal list mode. The header reports
the selection count. Selected rows use ANSI cyan for their primary text,
matching Zooi's browser convention; a row that is both focused and selected
combines cyan text with reverse video. Selection survives refreshes by entry
number and automatically loses entries that have been removed.

`p`, `t`, `T`, and `d` operate on every selected entry, or on the focused entry
when the selection is empty. If all targets are pinned, `p` unpins all of them;
otherwise it pins all of them. `t` prompts for one tag to add to every target;
`T` removes one tag from every target. Each multi-entry annotation action uses
one SQLite transaction. `n` remains a focused-entry operation because names
are unique per entry; it prompts with the current name and an empty submission
removes it. `r` reloads the numeric index.

Enter opens the focused entry's detail view. `d` removes unpinned targets
without confirmation. If any target is pinned, a single prompt asks whether
the pinned entries should also be deleted. `y` removes every target; `n` or
Enter skips the pinned entries while removing the others. Escape cancels the
whole operation. Removal uses the same staged, transactional operation as
`tj rm`, so entry resources and annotations are removed consistently and
numbering holes remain holes. `q` and Ctrl-C exit. Escape cancels an active
input prompt. Annotation actions share the command-layer operations used by
`tj name`, `tj tag`, and `tj pin`, so validation, normalization, idempotency,
uniqueness, mutation locking, and SQLite transactions are identical.

The detail view contains the complete command, exit status, recorded working
directory, start and end timestamps, duration, output size, resource names,
name, tags, pin state, and plain-rendered output. Every logical detail line is
a selectable list item, including metadata, working directory, command, and
each output line. Long lines are clipped to the viewport rather than wrapped;
their complete safe display values remain available when selected. Up/Down
and `j`/`k` move the focused item; Home/`g`, End/`G`, Page Up, and Page Down
move through the same logical-line index. Space toggles individual items and
Shift+Up/Down extends an inclusive range using the list view's selection
semantics. Enter restores the terminal, prints selected values in display
order (or the focused value when no selection exists), and exits. Escape
clears an existing selection before returning to the list; `q` returns
directly. The preview renders at most 2 MiB of recorded output and directs the
user to `tj cat @N` when truncated.

Zooi owns raw mode, resize input, retained rendering, synchronized output, and
the alternate screen. Normal and error returns restore the terminal through
Zooi teardown; the process panic path and fatal `SIGTERM`/`SIGHUP` paths call
Zooi's allocation-free restoration hook. The complete terminal session,
including alternate-screen teardown, is inside one OSC ELLO `NOOUT` region.
Consequently the browser remains visible but its entry records one
`<tj:noout>` placeholder rather than screen frames. After teardown TJ closes
the region before returning control to the shell.

Journal-local mutable metadata is held in `journal.sqlite3`, separately from
recording-time `meta.json`. TJ embeds SQLite; users need no system SQLite
library or executable. Schema version 1 has three sparse tables: one unique
name per entry, multiple normalized tags per entry, and pinned entry numbers.
An entry without annotations has no database row. Indexed queries stream rows
with a deliberately small page cache rather than materializing all annotations
in Zig memory.

Every existing database is checked for TJ's application id, schema version,
and exact tables/index. A corrupt, incompatible, or malformed database fails
closed. Transactions use persistent WAL mode, `synchronous=FULL`, and a
five-second busy timeout. `journal.sqlite3-wal` and `journal.sqlite3-shm` are
part of live database state while present, so an inactive journal must be
copied as one directory. Concurrent WAL users are supported only on the same
host, not across a network filesystem.

The lifetime writer lock does not serialize child commands. Shared advisory
guards at `.locks/<journal-name>.mutation` allow annotation updates to overlap;
SQLite serializes their short write transactions. Entry/output and whole-
journal removal take the exclusive guard. Removal first renames entry
directories into journal-local trash, then transactionally removes name, tag,
and pin rows, then deletes the staged bytes. Recovery removes stale rows for a
staged entry before clearing its trash. Readers ignore annotation rows whose
numeric entry directory is absent. A separate `.metadata` guard serializes
only connection setup and lazy WAL/schema initialization; it is released
before the annotation transaction begins.

## Entry ranges for reading

`tj cat @N..@M` concatenates the default `out` resource of every existing
entry in the inclusive current-journal interval, in numeric order and
without inserting separators. Numbering holes are skipped. A head or tail
window is applied independently to each selected output, matching the existing
behavior for multiple explicit references.

Cat ranges have the same conservative grammar as annotation and removal
ranges: unqualified numeric endpoints only, with no resource suffix. A range
that contains the entry running `cat` is refused before output begins,
preventing its output from feeding back into the file it is reading.

## Explicit removal

``` text
tj rm @42
tj rm @42/out
tj rm @2..@10
tj rm @12 @15/out @20..@25
tj rm --force @42
tjctl rm <name-or-suffix> [--force]
tjctl mv <name-or-suffix> <new-name>
```

Entry and output removal require a current journal and may target only
that journal. One invocation accepts one or more targets, processed from left
to right; entry, output, and range targets may be mixed, and `--force` applies
to the complete list. Each target number must be lower than the highest numeric
entry present while the mutation lock is held. In normal use the
removal command itself has already become that newer entry, which both
refuses the running command and preserves monotonic numbering without a
high-water manifest. Removed entries leave holes; remaining entries
are never renumbered.

An entry pin protects both whole-entry and output-only removal.
A pinned single target is skipped successfully with a diagnostic. Range
removal skips each pinned member while removing the unpinned members. Passing
`--force` overrides this protection. Pin checks happen after acquiring the
mutation lock and before staging any protected entry or output.

`tj rm @N..@M` removes every existing whole entry in the inclusive
numeric interval. Both endpoints must be unqualified current-journal numeric
references with `N <= M`; names, `@-`, resource suffixes, and qualified
cross-journal endpoints are rejected. Existing holes and, without `--force`,
pinned entries are skipped. The command validates that the interval does
not contain the protected highest entry before staging any removal.

Removing an entry first renames its directory into private journal
trash, removes its annotation entry atomically, and deletes the staged tree.
Readers ignore stale annotations whose numeric directory is absent, so a crash
after the rename cannot restore the entry or reserve its old name.

`tj rm @42/out` removes `out` and every published resource named by
`meta.json.resources`. Before the first rename it creates `out.removed`; this
marker is a one-way deletion boundary. It then preserves unknown metadata,
removes the resource map, and sets `out_removed` to true. `cmd`, `rc`, the
entry, and user annotations remain. Removing an individual resource is
unsupported because it would not redact that resource's bytes from `out`.

Whole-journal removal is a lifecycle operation available only when
`TJ_JOURNAL` is unset. It selects one journal unambiguously, prompts on a TTY
unless `--force` is present, acquires the existing writer lock nonblockingly,
then takes the journal mutation lock, and refuses an active journal. Without
`--force`, it also refuses a journal containing pinned entries; the pin
check is repeated while holding the mutation lock. Successful removal renames
the journal directory to root-private trash before recursive deletion. `--force`
skips confirmation and overrides pin protection only; it never bypasses
selection, locking, or other validation.

## Native journal search

The portable search command is:

``` text
tj grep [--all] [--cmd] [--out] [-i|--ignore-case]
        [--color WHEN] [--tui] [--] PATTERN
```

`PATTERN` is one non-empty literal byte string, not a regular expression. It
must not contain a newline. `--` ends option parsing and permits a leading
dash. Case-insensitive matching folds ASCII `A` through `Z` only; all other
bytes compare exactly.

The current journal is searched by default and `TJ_JOURNAL` is required in
that mode. `--all` searches every persisted journal and works outside a
writer. Both `cmd` and `out` are selected initially. The first `--cmd` or
`--out` clears that default pair and selects its resource; later selectors
form a union, so `--cmd --out` selects both. No other entry files,
published resources, annotations, private trash, or lock data are searched.
A missing `out` is skipped.

`--tui` searches the current journal and opens the entry browser over the
matching entry numbers. Each entry appears once regardless of how many lines
or selected resources match. The resulting subset retains numeric entry order
and the browser's normal annotation and deletion operations. Browser refreshes
retain the original matching subset while removing entries deleted since the
search. No-match status is 1 and does not open the browser. `--tui` is
incompatible with `--all` and with an explicitly supplied `--color` option.

Color behavior uses GNU grep's three modes. With no color option, highlighting
is disabled. `--color` and `--colour` require `WHEN`, supplied as the next
argument or with `=`; bare `--color` is invalid. `WHEN` is `never`, `auto`, or
`always`. Auto mode enables color only when stdout is a terminal and non-empty
`TERM` is not `dumb`. Always mode emits SGR sequences even to redirected or
piped stdout, and never mode emits none. Selected non-empty, non-overlapping
matches default to the same yellow as entry references (`33`). When `GREP_COLORS` is set, valid
decimal/semicolon `mt` and `ms` capabilities are applied in order, with the
later selected-match value winning; an empty selected-match value disables
match styling. These modes control match highlighting independently of the
yellow reference and other layout colors.

Iteration uses the storage model rather than recursive filesystem traversal:
journals are in ascending canonical-name order, entries are numeric ascending, resources are
`cmd` then `out`, and matching lines retain source order. Matching does not
cross a newline. Each matching source line is emitted once even if it contains
the literal more than once. Matching operates on original stored bytes. For
presentation, a terminal line-ending carriage return and leading or trailing
horizontal whitespace are omitted, while internal spaces and tabs collapse to
one space. Stored escape sequences, C0/C1 controls, DEL, and malformed UTF-8
are removed or replaced before output; other valid UTF-8 is preserved.
Match highlighting is added after this boundary, so only TJ-generated SGR can
reach the result stream. Results use history's row grammar:

``` text
*@#! 42 < matching source line @name #tag !1
     @release-build.42 > matching command line under --all
```

The four positional flags match history. `>` denotes `cmd` and `<` denotes
`out`. Optional name and tags, and nonzero status come from the same journal-local
annotations and entry metadata as history. Current-journal results use a plain right-aligned number. Every `--all` result qualifies the
number with its journal's complete canonical name, including results from the
writer's current journal. A final unterminated source line is still searchable.

On a terminal, TJ obtains the width with `TIOCGWINSZ` and emits one physical
row per result. If the full row does not fit, it finds the first match with a
bounded positional scan, selects context on both sides, and uses `…` for each
omitted side. The complete match is never cut; when the fixed columns, metadata,
and match cannot fit together, the row may exceed the width. The resource
direction is dimmed, references are yellow, names and tags are green, and
failures are red. Piped and redirected results use the same fields without
trimming or presentation styling. Explicit `--color=always` still styles
selected matches when redirected, as described above.

When `TJ_JOURNAL` is set and decimal `TJ_NEXT` is greater than one, entry
`TJ_NEXT - 1` in that exact journal is treated as the command currently
executing and excluded. A missing or malformed counter does not cause another
entry to be guessed or excluded.

Search streams each resource in fixed-size chunks with matcher state carried
across reads and reset at line boundaries. Matching-line and terminal-window
spans are copied by positional reads, so memory use is proportional to the
pattern and fixed buffers rather than to the resource, line, or match count.

When stdout is a terminal and a current journal exists, search lazily encloses
all result lines in one OSC ELLO `NOOUT` region. No markers are emitted for help,
errors, or no matches. Redirected or piped stdout is plain marker-free data.
The result is status 0 when any line matched, 1 for no matches, and 2 for grep
argument errors or current-journal mode without a current journal. Storage and
I/O errors use TJ's ordinary status-1 diagnostic path.

The optional `tj-grep` companion remains the ripgrep-powered interface for
regular expressions, context, line numbers, and arbitrary `rg` options; it is
not part of the native fixed-string contract.

## Semantic output regions

TJ can preserve structure that would otherwise be lost when a program
writes human-readable output, and can explicitly keep visible output out of
the recorded resource.

A cooperating program marks the beginning and end of a resource using
**OSC ELLO**, where `ELLO` is the mnemonic for numeric OSC code 3110 (`3110`
reads as `ELLO` in leetspeak). `ELLO` is written as `3110` on the wire; message
names are uppercase and case-sensitive, and there is no additional namespace
field. ELLO messages end with `ST`. The resource contents remain ordinary
program output; TJ interprets the control sequences as annotations over that
output.

The four message forms have distinct producers and roles:

-   `CONTEXT` is a self-contained message normally emitted by
    `tj.plugin.zsh` once per command from `preexec`; it does not open a region.
-   `RESOURCE` is normally emitted by a cooperating program or an output
    wrapper such as `tj-fence`; it opens a published-resource region.
-   `NOOUT` is emitted by `tj noout`, by TJ's terminal reports (`hist`, `grep`,
    `du`, and `tui`), or by a cooperating program; it opens an omitted-output
    region.
-   `END` is emitted by the program or wrapper that opened a `RESOURCE` or
    `NOOUT` region and closes that region.

The protocol is:

``` text
OSC ELLO ; RESOURCE ; <path> [ ; <mime> ] ST
<ordinary output bytes>
OSC ELLO ; END ST
```

The same non-nesting protocol has a noout region:

``` text
OSC ELLO ; NOOUT ST
<ordinary output bytes>
OSC ELLO ; END ST
```

TJ removes both markers before forwarding output. On `NOOUT`, it writes the
fixed text `<tj:noout>` once to the entry's `out`, without displaying
that text. Bytes inside the region are forwarded to the terminal but are not
written to `out` or to a published resource. Normal recording resumes after
the generic `END` marker.

For example, an agent might produce a reply containing a CSV data set
and a shell script:

``` text
OSC ELLO ; RESOURCE ; files/data.csv ; text/csv ST
date,amount
2026-08-01,12.50
2026-08-02,19.20
OSC ELLO ; END ST

OSC ELLO ; RESOURCE ; files/script.sh ; text/x-shellscript ST
#!/bin/sh
awk -F, '{ sum += $2 } END { print sum }'
OSC ELLO ; END ST
```

The user still sees normal terminal output. TJ additionally exposes:

``` text
@42/files/data.csv
@42/files/script.sh
```

The resources are spans of `@42/out`; TJ does not need a separate data
channel or duplicate the underlying bytes.

The same mechanism lets a program publish its own error output as a
resource, for example:

``` text
OSC ELLO ; RESOURCE ; err ; text/plain ST
parse error at line 12
OSC ELLO ; END ST
```

exposing `@42/err`. Whether such a resource exists is up to the program.

The v1 protocol has deliberately simple rules:

-   no nesting
-   one open region at a time, either a resource or noout
-   the first open region wins when another `RESOURCE` or `NOOUT` is received
-   `END` closes whichever region is open
-   resource names are relative paths
-   absolute paths and `..` are rejected
-   `cmd`, `cwd`, `out`, `prompt`, `rc`, `meta.json`, and private removal bookkeeping names are
    reserved and rejected as resource names
-   the bytes between `RESOURCE` and `END` are exactly the resource
    contents
-   OSC markers are control metadata and are not part of `@N/out`
-   `ST` (`ESC \`) terminates the OSC sequence
-   an unfinished resource is closed and marked truncated at the entry
    boundary; an unfinished noout region is cleared without metadata so it
    cannot affect the next entry
-   noout payload sizes or flags are not stored in `meta.json`

By default, TJ strips OSC ELLO sequences from the stream before
forwarding it to the terminal emulator. An option keeps them in the
forwarded stream, for debugging or for emulators and multiplexers that
want to interpret them.

Programs that do not emit OSC ELLO still work normally and expose the core
resources produced by their shell integration.

`tj noout -- command args...` is the user-facing wrapper for a whole command.
It requires an active journal and a controlling terminal, writes the region
markers to that terminal, executes the supplied argv directly without a shell,
and otherwise inherits the caller's cwd, environment, standard streams,
terminal, and process group. Its result is the child's exit status, or
`128 + signal` when the child dies from a signal. The wrapper makes a best
effort to emit `END` after it has emitted `NOOUT`; entry-boundary reset
handles cases where the wrapper itself dies before it can do so.

Noout is explicit and is not inferred from the PTY ECHO flag. Input typed with
echo disabled is already absent from `out`, and disabling echo is not in
itself evidence that a program's output is secret.

This allows richer programs, particularly agents, to turn parts of
otherwise ordinary textual responses into reusable Unix resources
without replacing stdout with a separate structured-output protocol.
This is a deliberate choice: TJ keeps plain text as the interchange
format and adds addressability on top, rather than introducing
structured output in the style of nushell or PowerShell.

## Storage

``` text
~/.tj/
├── .locks/
│   ├── .namespace
│   ├── <journal>
│   ├── <journal>.mutation
│   └── <journal>.metadata
└── <journal>/
    ├── journal.sqlite3
    ├── journal.sqlite3-wal  (while present)
    ├── journal.sqlite3-shm  (while present)
    └── 42/
        ├── cmd
        ├── cwd
        ├── out
        ├── rc
        └── files/
```

Recorded resources remain ordinary files. The embedded journal database is
created lazily on the first annotation write; it is versioned for future
journal-local state but version 1 stores only names, tags, and pins. A newly
created journal that records no entry or log may be removed as noise. A journal used
again with `tjctl use` is never deleted by an empty writer run. Journal
directories are canonical names; renaming one atomically changes its identity
without rewriting its contents.

At writer shutdown, `tjctl` writes a diagnostic to standard error when the
journal contains no entry. The diagnostic is not stored and does not prevent
empty-new cleanup.

This immediately enables shell completion.

``` sh
python @42/<TAB>
```

Future implementations may replace this directory representation with a
virtual filesystem or an internal storage engine without changing the
user-facing interface.

## Open questions

-   Retention. `cmd` captures secrets typed on the command line, and the
    journal is exactly what gets fed to agents. Explicit removal and pins do
    not define an automatic retention policy. Deferred for now.
-   Interactive programs (editors, pagers, TUIs) produce large `out`
    entries consisting mostly of escape sequences. Whether the plugin
    should mark these as opaque is not yet decided.

------------------------------------------------------------------------

# Why this matters

The Terminal Journal is not simply a better shell history.

It introduces a persistent namespace for previous computations.

This unlocks:

-   post-hoc composition
-   addressable debugging journals
-   reusable computational artifacts
-   agent-friendly context
-   model-independent workflows
-   reproducible investigations

Rather than becoming the environment in which work happens, AI
assistants become Unix-style tools that reason over a shared execution
journal.

The shell remains the operating environment.

The Terminal Journal becomes its memory.
