# Terminal Journal (TJ)

*A proposal for making terminal interactions persistent, addressable,
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

A **Terminal Journal** treats every command interaction as a first-class
object.

Rather than viewing the terminal as a stream of characters, TJ models it
as an append-only journal of computational interactions.

Each interaction receives an identifier. Journal references use `@N`;
`@-` refers to the immediately preceding interaction.

Every interaction exposes three core resources:

``` text
@42/
├── cmd
├── out
└── rc
```

`cmd` is the command line as entered. `out` is the terminal output as
rendered: the bytes the program wrote to the tty, including escape
sequences. `rc` is the exit status.

Programs may also mark semantic spans within their output as named
resources:

``` text
@42/
├── cmd
├── out
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

Interactions become stable references rather than anonymous text.

## Computational objects

Commands no longer produce only terminal output.

They produce reusable objects.

The three core resources are always available:

``` text
@103/cmd
@103/out
@103/rc
```

Programs can additionally expose meaningful parts of their output as
named resources:

``` text
@103/
├── cmd
├── out
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
3.  Records interactions.

A PTY carries a single byte stream: the program's stdout and stderr are
already merged by the time TJ sees them. TJ therefore does not attempt
to separate them. There is no `err` core resource; a program that wants
to expose its errors as a distinct resource can do so with OSC 5107
(see below).

## Sessions and numbering

Each `tj` process is a session. When a session starts, TJ generates a
ULID for it. ULIDs are 26-character Crockford base32 strings: a 48-bit
millisecond timestamp followed by 80 random bits. If the generated ULID
already exists in the store, TJ simply generates another one.

Interactions are numbered sequentially within a session, starting at 1.

Within the current session, `@42` refers to interaction 42. To refer to
an interaction in another session (for example, another terminal pane,
or a session that has already ended), the reference is qualified with
the session ULID or any suffix of it:

``` text
@42/out                                  interaction 42, current session
@01knxf1n5ffvk9jsm8wve1pgsd.42/out       interaction 42, full session id
@wve1pgsd.42/out                         same, using a suffix
@pgsd.42/out                             same, using a shorter suffix
@-/out                                   previous interaction, current session
```

Suffixes rather than prefixes, because the timestamp prefix is shared
by every session started in the same moment while the random tail is
what distinguishes them. A suffix may be of any length. If more than
one session matches, the most recent one wins. This trades certainty
for convenience: short suffixes are for interactive use, and anything
that needs a stable reference (a note, a script, an agent transcript)
should use the full ULID.

Because the ULID is time-ordered, sessions sort chronologically in
`~/.tj/` with no extra metadata.

An all-digit reference (`@42`) always means the current session and is
never interpreted as a suffix.

## Zsh integration

A small zsh plugin provides two functions:

1.  semantic command boundaries for the journal
2.  resolution and completion of the journal namespace

### Command boundaries

The plugin uses `preexec` and `precmd`, optionally augmented by OSC 133
shell integration, to tell TJ when an interaction starts and finishes.

Each completed interaction becomes a journal entry:

``` text
@42/
├── cmd
├── out
└── rc
```

### Journal namespace

TJ references are a shell-level namespace:

``` text
@10/out
@10/files/data.csv
@pgsd.10/out
@-/out
```

Ordinary programs do not need to understand this syntax. Before
executing a command, the zsh integration resolves journal references to
ordinary filesystem paths.

Conceptually:

``` text
@10/out                 → ~/.tj/<session>/10/out
@10/files/data.csv      → ~/.tj/<session>/10/files/data.csv
@pgsd.10/out            → ~/.tj/<ulid ending in pgsd>/10/out
@-/out                  → ~/.tj/<session>/<previous>/out
```

Thus:

``` sh
cat @10/out
```

is executed equivalently to:

``` sh
cat ~/.tj/<session>/10/out
```

and `cat` remains completely unaware of TJ.

The model deliberately resembles zsh named-directory expansion:

``` text
~name/path      named filesystem location
@N/path         named journal interaction
```

The `@` prefix identifies the journal namespace in the same way that `~`
introduces filesystem-oriented shorthand.

The zsh integration applies this expansion to unquoted command arguments
that begin with `@` followed by a journal reference (`-`, `N`, or
`SUFFIX.N`). Arguments such as `user@host` are unaffected. The semantic PTY
proxy does not rewrite command input.

### Completion

The same resolver provides native zsh completion.

For example:

``` sh
cat @10/<TAB>
```

can offer:

``` text
cmd  files/  out  rc
```

and:

``` sh
cat @10/files/<TAB>
```

can offer resources published by the program.

This makes the journal namespace behave like a filesystem from the
user's perspective while allowing TJ to change its underlying storage
implementation later.

## Semantic output resources

TJ can preserve structure that would otherwise be lost when a program
writes human-readable output.

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
-   one open resource at a time
-   resource names are relative paths
-   absolute paths and `..` are rejected
-   `cmd`, `out`, and `rc` are reserved and rejected as resource names
-   the bytes between `begin` and `end` are exactly the resource
    contents
-   OSC markers are control metadata and are not part of `@N/out`
-   `ST` (`ESC \`) terminates the OSC sequence

By default, TJ strips OSC 5107 sequences from the stream before
forwarding it to the terminal emulator. An option keeps them in the
forwarded stream, for debugging or for emulators and multiplexers that
want to interpret them.

Programs that do not emit OSC 5107 still work normally and simply expose
the three default resources.

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
└── <session>/
    └── 42/
        ├── cmd
        ├── out
        ├── rc
        └── files/
```

This immediately enables shell completion.

``` sh
python @42/<TAB>
```

Future implementations may replace this directory representation with a
virtual filesystem or an internal storage engine without changing the
user-facing interface.

## Open questions

-   Retention and redaction. `cmd` will capture secrets typed on the
    command line, and the journal is exactly what gets fed to agents.
    Deferred for now.
-   Interactive programs (editors, pagers, TUIs) produce large `out`
    entries consisting mostly of escape sequences. Whether the plugin
    should mark these as opaque is not yet decided.

------------------------------------------------------------------------

# Why this matters

The Terminal Journal is not simply a better shell history.

It introduces a persistent namespace for previous computations.

This unlocks:

-   post-hoc composition
-   addressable debugging sessions
-   reusable computational artifacts
-   agent-friendly context
-   model-independent workflows
-   reproducible investigations

Rather than becoming the environment in which work happens, AI
assistants become Unix-style tools that reason over a shared execution
journal.

The shell remains the operating environment.

The Terminal Journal becomes its memory.
