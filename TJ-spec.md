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
├── out
├── prompt
└── rc
```

`cmd` is the command line as entered. `out` is the terminal output as
rendered: the bytes the program wrote to the tty, including escape
sequences. `prompt` is the exact terminal byte sequence zsh rendered before
the command, including dynamic prompt-engine output; it is absent in journals
recorded without prompt-aware shell integration. `rc` is the exit status.

Programs may also mark semantic spans within their output as named
resources:

``` text
@42/
├── cmd
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
@103/out
@103/prompt
@103/rc
```

Programs can additionally expose meaningful parts of their output as
named resources:

``` text
@103/
├── cmd
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
to expose its errors as a distinct resource can do so with OSC 5107
(see below).

## Journals and numbering

A journal is a durable ULID directory. A `tj` process is a temporary writer
attached to one journal. `tj new` always generates a new ULID; `tj continue
<id-or-suffix>` attaches to one existing journal and rejects zero or multiple
matches. ULIDs are 26-character Crockford base32 strings: a 48-bit millisecond
timestamp followed by 80 random bits. If a generated ULID already exists in
the store, TJ generates another one.

Continuation is append-only. It launches a fresh shell or requested command
using the caller's cwd and environment. It restores no cwd, environment,
shell options, functions, history, jobs, file descriptors, processes, or
other state from previous writers.

Before launching that fresh child, continuation replays the selected journal
to the outer terminal by default. It uses the ordinary replay rendering, but
with command typing delays, recorded command durations, and gaps all set to
zero. Non-visual background-colour and cursor-position queries are suppressed
so their terminal replies cannot become input to the fresh child. The replay
bypasses the new writer's scanner and is not recorded again. `--no-replay`
suppresses this startup replay.

Entries start at 1. Every later writer starts at one greater than the
highest valid numeric entry directory. A missing `rc` means unfinished,
but that directory still consumes its number. Gaps are never filled and old
entries are never overwritten.

At most one cooperating writer may attach to a journal. A nonblocking,
exclusive advisory lock in `~/.tj/.locks/<journal-ulid>` is held for the
writer's lifetime and is closed on exec in the child. Readers do not take
this lock. Locking, selection, and number exhaustion fail before the child is
started.

The lifecycle CLI is explicit:

``` text
tj new [--keep-osc] [-- command ...]
tj continue [--keep-osc] [--no-replay] <id-or-suffix> [-- command ...]
tj journal list
```

All public commands are first-class subcommands in one validated command
schema. A bare `tj` or `tj --help` prints application help; `tj COMMAND
--help` prints help for that command. Help is written to standard output and
returns status 0.

Command options accept `--option value` and `--option=value` when the option
requires a value. A required-value option without one is invalid; there is no
implicit value for options such as `grep --color`. `--` ends TJ option parsing
where a command accepts dash-prefixed operands. For `new` and `continue`, it
also explicitly begins the child argv, though it may be omitted before an
ordinary executable name. For `noout`, the separator is mandatory. TJ never
parses options in a child argv after that boundary.

Every command enforces the arity in its published usage. Unknown commands,
unknown options, missing option values, and missing or extra operands are
command-line usage errors: they print the relevant generated help to standard
error and return status 2. Operational and storage failures retain status 1,
as do commands with a documented negative result such as a grep with no
matches.

The writer exports `TJ_JOURNAL`, `TJ_NEXT`, `TJ_HOME`, and `TJ`. The zsh
integration derives `TJ_JOURNAL_SHORT` and `TJ_REF`. These variables describe
the selected durable journal and its next unused entry; they are not a
snapshot of prior process state.

Within the current journal, `@42` refers to entry 42. To refer to
an entry in another journal (for example, another terminal pane,
or a journal that has already ended), the reference is qualified with
the journal ULID or any suffix of it:

``` text
@42/out                                  entry 42, current journal
@build-failure/out                       named entry, current journal
@01knxf1n5ffvk9jsm8wve1pgsd.42/out       entry 42, full journal id
@wve1pgsd.42/out                         same, using a suffix
@pgsd.42/out                             same, using a shorter suffix
@pgsd.build-failure/out                  named entry in that journal
@-/out                                   previous entry, current journal
```

Suffixes rather than prefixes, because the timestamp prefix is shared
by every journal started in the same moment while the random tail is
what distinguishes them. A suffix may be of any length. If more than
one journal matches, the most recent one wins. This trades certainty
for convenience: short suffixes are for interactive use, and anything
that needs a stable reference (a note, a script, an agent transcript)
should use the full ULID.

That newest-match rule applies to read references and replay. `tj continue`
requires a unique match because it mutates the selected journal.

Because the ULID is time-ordered, journals sort chronologically in
`~/.tj/` with no extra metadata.

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
├── out
├── prompt
└── rc
```

### Journal namespace

TJ references are shell-neutral identifiers accepted by TJ commands:

``` text
@10
@build-failure
@pgsd.10
@pgsd.build-failure
@-
```

The canonical zsh filesystem namespace uses dynamic named directories. The
name inside the brackets identifies an entry directory; resource paths
are ordinary filesystem suffixes:

``` text
~[@10]/out
~[@build-failure]/out
~[@10]/files/data.csv
~[@pgsd.10]/out
~[@pgsd.build-failure]/out
~[@-]/out
```

Ordinary programs do not need to understand either form. zsh expands the
canonical dynamic named directory during normal command parsing and passes an
ordinary filesystem path to the program.

Conceptually:

``` text
~[@10]/out                 → ~/.tj/<journal>/10/out
~[@10]/files/data.csv      → ~/.tj/<journal>/10/files/data.csv
~[@pgsd.10]/out            → ~/.tj/<ulid ending in pgsd>/10/out
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
@pgsd.10/out  → ~[@pgsd.10]/out
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
cmd  files/  out  prompt  rc
```

and:

``` sh
cat ~[@10]/files/<TAB>
```

can offer resources published by the program.

The global shorthand completer remains available for `@10/<TAB>`. Normal zsh
completion runs before that fallback so dynamic named-directory and ordinary
filesystem completion retain their native behavior.

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
tj tag --remove @42 parser
tj tag @42
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

History renders each entry as:

```text
[pin] [number] command @name [tags] [rc=N]
```

The pin and right-aligned number form the left prefix. Name and tags are
optional suffix metadata, with tags space-separated inside brackets. A nonzero
exit status follows as `[rc=N]`; status zero and a missing status are omitted.
On a capable terminal, names and tags are dimmed and a nonzero status is red;
`NO_COLOR`, `TERM=dumb`, and non-terminal output disable styling.

For terminal output, TJ obtains the width with `TIOCGWINSZ`, reserves the left
prefix, and word-wraps the command and suffix in the remaining columns.
Oversized words are hard-wrapped. Continuation lines align with the command.
Non-terminal output remains one physical line per entry with no ANSI sequences.

When stdout is a terminal and a current journal exists, history lazily encloses
the listing in one OSC 5107 noout region. No markers are emitted when filters
select no entries. Redirected or piped history is plain marker-free output.

A pin is an idempotent boolean annotation. It appears as `*` beside the
entry number in history. Pins protect entries and their output
from entry-level removal unless `--force` is present. They have no
retention semantics. Whole-journal removal is refused while pins remain unless
`--force` is present.

`@N..@M` selects the inclusive numeric interval in the current journal for
`tag` and `pin`. Endpoints are unqualified numeric references with `N <= M`;
names, `@-`, resources, and qualified journals are invalid. Missing numbers
inside the interval are skipped. Tagging, untagging, pinning, and unpinning
load and save the annotation manifest once, so the selected existing
entries change atomically. `tj tag @N..@M` queries tagged entries in
numeric order.

Targeted name and tag queries may read qualified references. Every annotation
write is restricted to the journal whose full id is in `TJ_JOURNAL`.
Syntactically qualified references and canonical paths belonging to another
journal are rejected before mutation. To annotate another journal, a user
continues it and runs the annotation command there.

Annotations are held in the journal root:

```json
{
  "v": 1,
  "interactions": {
    "42": {
      "name": "build-failure",
      "tags": ["bug", "parser"],
      "pinned": true
    }
  }
}
```

The on-disk key remains `"interactions"` for compatibility with existing
journals; its members are entries in the current terminology.

Absent fields are omitted and an entry with no annotations has no map
entry. The manifest is bounded to 4 MiB, validated strictly, serialized in
numeric/tag order, and replaced by same-directory sync-and-rename. A malformed
or unsupported manifest fails closed and is never overwritten.

The lifetime writer lock does not serialize child commands. Therefore one
blocking advisory lock at `.locks/<journal-ulid>.mutation` covers every
annotation read-modify-write and entry/output removal. The manifest is
reloaded after acquiring it. No per-entry or high-water lock exists.

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
tj rm --force @42
tj journal rm <id-or-suffix> [--force]
```

Entry and output removal require a current journal and may target only
that journal. The target number must be lower than the highest numeric
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
the ULID directory to root-private trash before recursive deletion. `--force`
skips confirmation and overrides pin protection only; it never bypasses
selection, locking, or other validation.

## Native journal search

The portable search command is:

``` text
tj grep [--all] [--cmd] [--out] [-i|--ignore-case]
        [--color WHEN] [--] PATTERN
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

Color behavior uses GNU grep's three modes. With no color option, highlighting
is disabled. `--color` and `--colour` require `WHEN`, supplied as the next
argument or with `=`; bare `--color` is invalid. `WHEN` is `never`, `auto`, or
`always`. Auto mode enables color only when stdout is a terminal and non-empty
`TERM` is not `dumb`. Always mode emits SGR sequences even to redirected or
piped stdout, and never mode emits none. Selected non-empty, non-overlapping
matches default to bold red (`01;31`). When `GREP_COLORS` is set, valid
decimal/semicolon `mt` and `ms` capabilities are applied in order, with the
later selected-match value winning; an empty selected-match value disables
match styling. TJ does not style its reference prefix.

Iteration uses the storage model rather than recursive filesystem traversal:
journals are newest first, entries are numeric ascending, resources are
`cmd` then `out`, and matching lines retain source order. Matching does not
cross a newline. Each matching source line is emitted once even if it contains
the literal more than once. Matching operates on original stored bytes. For
presentation, a terminal line-ending carriage return and leading or trailing
horizontal whitespace are omitted, while internal spaces and tabs collapse to
one space. Other source bytes are preserved. Results use history's row grammar:

``` text
*   42  [out] matching source line @name [tag] [rc=1]
  @8wpc.42  [out] matching source line under --all
```

The leading pin, optional name and tags, and nonzero status come from the same
journal-local annotations and entry metadata as history. Current-journal
results use a plain right-aligned number. Every `--all` result qualifies the
number with the last four bytes of its journal ULID, including results from the
writer's current journal. A final unterminated source line is still searchable.

On a terminal, TJ obtains the width with `TIOCGWINSZ` and hard-wraps rows under
the content column without buffering the source line. The resource, name, and
tags are dimmed and a nonzero status is red when terminal styling is supported.
Piped and redirected results use the same fields without wrapping or
presentation styling. Explicit `--color=always` still styles selected matches
when redirected, as described above.

When `TJ_JOURNAL` is set and decimal `TJ_NEXT` is greater than one, entry
`TJ_NEXT - 1` in that exact journal is treated as the command currently
executing and excluded. A missing or malformed counter does not cause another
entry to be guessed or excluded.

Search streams each resource in fixed-size chunks with matcher state carried
across reads and reset at line boundaries. Matching-line spans are copied by
positional reads, so memory use is proportional to the pattern and fixed
buffers rather than to the resource, line, or match count.

When stdout is a terminal and a current journal exists, search lazily encloses
all result lines in one OSC 5107 noout region. No markers are emitted for help,
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
**OSC 5107** (`5107` reads as `SLOT` in leetspeak). The resource
contents remain ordinary program output; TJ interprets the control
sequences as annotations over that output.

The protocol is:

``` text
OSC 5107 ; tj ; begin ; <path> ; <mime> ST
<ordinary output bytes>
OSC 5107 ; tj ; end ST
```

The same non-nesting protocol has a noout region:

``` text
OSC 5107 ; tj ; noout ST
<ordinary output bytes>
OSC 5107 ; tj ; end ST
```

TJ removes both markers before forwarding output. On `noout`, it writes the
fixed text `<tj:noout>` once to the entry's `out`, without displaying
that text. Bytes inside the region are forwarded to the terminal but are not
written to `out` or to a published resource. Normal recording resumes after
the generic `end` marker.

For example, an agent might produce a reply containing a CSV data set
and a shell script:

``` text
OSC 5107 ; tj ; begin ; files/data.csv ; text/csv ST
date,amount
2026-08-01,12.50
2026-08-02,19.20
OSC 5107 ; tj ; end ST

OSC 5107 ; tj ; begin ; files/script.sh ; text/x-shellscript ST
#!/bin/sh
awk -F, '{ sum += $2 } END { print sum }'
OSC 5107 ; tj ; end ST
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
OSC 5107 ; tj ; begin ; err ; text/plain ST
parse error at line 12
OSC 5107 ; tj ; end ST
```

exposing `@42/err`. Whether such a resource exists is up to the program.

The v1 protocol has deliberately simple rules:

-   no nesting
-   one open region at a time, either a resource or noout
-   the first open region wins when another begin marker is received
-   `end` closes whichever region is open
-   resource names are relative paths
-   absolute paths and `..` are rejected
-   `cmd`, `out`, `prompt`, `rc`, `meta.json`, and private removal bookkeeping names are
    reserved and rejected as resource names
-   the bytes between `begin` and `end` are exactly the resource
    contents
-   OSC markers are control metadata and are not part of `@N/out`
-   `ST` (`ESC \`) terminates the OSC sequence
-   an unfinished resource is closed and marked truncated at the entry
    boundary; an unfinished noout region is cleared without metadata so it
    cannot affect the next entry
-   noout payload sizes or flags are not stored in `meta.json`

By default, TJ strips OSC 5107 sequences from the stream before
forwarding it to the terminal emulator. An option keeps them in the
forwarded stream, for debugging or for emulators and multiplexers that
want to interpret them.

Programs that do not emit OSC 5107 still work normally and expose the core
resources produced by their shell integration.

`tj noout -- command args...` is the user-facing wrapper for a whole command.
It requires an active journal and a controlling terminal, writes the region
markers to that terminal, executes the supplied argv directly without a shell,
and otherwise inherits the caller's cwd, environment, standard streams,
terminal, and process group. Its result is the child's exit status, or
`128 + signal` when the child dies from a signal. The wrapper makes a best
effort to emit `end` after it has emitted `noout`; entry-boundary reset
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

A proof of concept does not require a database.

``` text
~/.tj/
├── .locks/
│   ├── <journal>
│   └── <journal>.mutation
└── <journal>/
    ├── annotations.json
    └── 42/
        ├── cmd
        ├── out
        ├── rc
        └── files/
```

Existing ULID directories require no migration. A newly created journal that
records no entry or log may be removed as noise. A continued journal is
never deleted by an empty writer run.

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
