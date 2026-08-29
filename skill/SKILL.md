---
name: tj
description: Read the terminal journal to find out what actually happened in this terminal - what was run, what it printed, what failed. Use whenever the user refers to something on their screen without saying what ("this", "that error", "why did it fail", "the last command"), asks about a command they ran, or gives a @N reference. Also use before asking the user to paste output or re-run something: it may already be recorded.
---

# Terminal Journal

The user's terminal is recording. Every command is an **entry** with a
number, and you can read what it ran, what it printed, and how it ended -
without asking them to paste anything and without running it again.

## Is there a journal?

`$TJ_JOURNAL` is set while the current shell is writing a journal. If it is
empty, there is no current journal context: answer from what you were told.
Persisted journals may still exist and are listed by `tj journal list`.

Run **`tj`** by its plain name, one command per call, with no pipe and no
`;`. Not `"$TJ"`, not `tj ... | tail`. A wrapper may grant permission to run
`tj` and nothing else, and a rule like `Bash(tj *)` matches only the literal
name in a simple command — a pipeline or an expanded variable does not match
it, and the journal silently stays unreadable. Every window you might want a
pipe for, `tj` already has as a flag.

If `tj` is genuinely not on `$PATH`, `$TJ` holds its full path, but prefer
the plain name.

## Start with the index, not the output

```sh
tj hist
```

```
     1  git status
*    2  go test ./... @build-failure [bug parser] [rc=1]
     3  vi parser.go
```

Columns: pin, number, and the command followed by optional name, tags, and a
nonzero exit status. Long commands wrap under the command column on a terminal.
Names and tags are dimmed and failures are red when color is enabled.
The whole index is a few hundred tokens even for a long journal. The output
of a single entry can be 50K. **Read the index first and fetch
deliberately.**

When the user gives a distinctive literal rather than an entry number,
search narrowly instead of opening many outputs:

```sh
tj grep --out 'connection refused'
tj grep --cmd 'docker compose'
```

Results use history-like rows: pin, entry reference, `[cmd]` or `[out]`, the
matching line, optional name and tags, and `[rc=N]` for failures. Redirected
results keep the same fields without terminal wrapping or presentation color.
Displayed matching lines collapse horizontal whitespace; use `tj cat` for the
original indentation or layout.

Native grep is fixed-string search; it does not interpret regular expressions.
Use `tj hist` to browse, and use `tj grep --all LITERAL` only when evidence from
other journals is relevant. Search results are deliberately omitted from the
current entry when displayed in its terminal, so they do not become the
next search's output matches.

Then take only what you need:

```sh
tj cat @2              # what entry 2 printed
tj cat @2..@5          # existing outputs 2 through 5, in numeric order
tj cat --tail 20 @2    # just the end, where errors are
tj cat --head 5 @2     # just the beginning
tj cat @2/cmd          # the command line as it was typed
```

Use `--tail` and `--head` rather than piping to `tail` or `head`: a pipeline
is a compound command, and a narrow permission rule will refuse it.

Ranges are inclusive, current-journal numeric references and skip missing
numbers. Use one only when several complete outputs are deliberately needed;
it is refused if it includes the entry currently running `tj cat`.

When a window hides something, `tj` says so on stderr: `showing 20 of 431
lines`. If you see that, you are looking at a fragment - fetch more before
concluding anything about what is not shown.

## Resolving "this" and "that"

`@-` is the last **completed** entry. Your own invocation is still
running, so `@-` is reliably the command the user just ran, which is almost
always what "this" means.

```sh
tj cat @-/cmd          # what they just ran
tj cat @-              # what it printed
```

When you infer a referent, **say which one in a single line** before
answering:

> Assuming you mean the `go test ./...` you just ran:

The user corrects a wrong guess in one word. A confident answer about the
wrong command wastes a whole exchange.

Do not do this blindly. If the question stands on its own, answer it. Fetch
`@-` when the prompt points at something it does not name.

## Reading exit status correctly

- `tj hist` shows only nonzero statuses, as `[rc=N]`. No status means either
  success or an unfinished entry; inspect the entry's `rc` resource when that
  distinction matters.
- `rc` is the shell's status for the **whole line**. On a pipeline that is
  the last element, so `curl … | head` reports `0` when `curl` failed. Empty
  output with status `0` on a pipeline is a strong hint that something
  upstream failed quietly.

## What the output actually contains

`out` is what the terminal saw, escape sequences and all. `tj cat` renders it
as readable text when writing to a pipe, which is what you will get. Add
`--raw` only if you specifically need the bytes, including colour codes.

With the zsh integration, `prompt` contains the exact rendered prompt that
preceded the entry, including dynamic prompt-engine output. Use
`tj cat '@42/prompt'` only when the prompt itself is relevant; it is absent in
older journals and is not part of `out`.

Two things will look wrong and are not:

- **Full-screen programs record almost nothing.** Editors, pagers and
  anything that takes over the screen paint on the alternate screen, which is
  not part of scrollback, so it is not recorded either. `vi notes.txt` leaves
  a command, a status, and a near-empty output. `meta.json` says
  `"fullscreen"` when this happened. This is by design; do not report it as
  missing data.
- **Prompt redraw** appears at the end of an entry's output. It belongs
  to the shell, not the command.
- **`<tj:noout>` means visible output was deliberately omitted.** `tj noout`
  and cooperating programs can show bytes in the terminal without retaining
  them in `out`. The placeholder carries no byte count or hidden payload, and
  `meta.json` intentionally adds no noout fields. Do not treat it as a failed
  capture or try to reconstruct what was omitted.

## Referring across journals

`@42` means this journal. Another journal is named by a suffix of its id:
`@pgsd.42/out`. `$TJ_JOURNAL_SHORT` holds the current one's suffix. `tj
journal list` lists them, newest first.

An entry may also have a journal-local name, such as
`@build-failure/out`; `@pgsd.build-failure/out` reads the same name from
another journal. Names and numbers resolve through `tj cat` in the same way.
An unresolved `@name` remains literal in an interactive command so it can
still be an ordinary `@handle`.

Names, tags, and pins are user annotations. Tags can be used to narrow the
index with repeatable AND filters such as `tj hist --tag bug --tag parser`.
Use `tj hist --pinned` (or `--pin`) to show only pinned entries; pin and tag
filters combine with AND semantics.
Direct terminal history is deliberately omitted from the entry recording with
`<tj:noout>` so browsing the index does not duplicate it into the journal.
Piped or redirected history remains ordinary output.
Pins imply no retention policy, but protect an entry and its output from
`tj rm`. Removal ranges skip pinned entries; use `tj rm --force REF` only
when overriding that protection is deliberate. Whole-journal removal likewise
requires `--force` while any pins remain.

Do not add, remove, or change annotations unless the user asks. Annotation
writes and entry/output deletion are current-journal-only; qualified
references are read-only.

## Published resources

A program can mark part of its output as a named file, which then appears
under the entry:

```sh
tj cat @42/files/data.csv
```

`tj hist` does not list these. Check `@42/meta.json` for a `resources` map,
or run `tj complete '@42/'` to see what an entry holds.

## Output the user may want to reuse

When part of an answer is meant to be **used** rather than read - a table of
data, a script, a config block - put it in a fenced block with a language
tag, and keep prose out of the fence:

    ```csv
    date,amount
    2026-08-01,12.50
    ```

A wrapper may turn fenced blocks into files of this entry, taking the
mime type from that tag, which is why the tag is worth getting right. Whether
such a wrapper is in the pipeline is not something you can see from here.

So: **do not claim a file was written, and do not invent a name or a number
for it.** You do not choose either. Write the block, say what it is, and stop
there.

## Rules

- **Use `tj cat`, never `cat @N/out`.** The second replays the whole
  recording to the terminal, which is slow, makes a mess of the screen, and
  gets recorded again as a new entry - a 50K one. This is the single
  most expensive mistake available here.
- **Do not fetch everything.** Fetching every entry's output costs
  hundreds of times what the index costs and is almost never worth it.
- **Quote references** when passing them to `tj` from inside a journal writer:
  `tj cat '@1'`. The shell integration canonicalizes unquoted shorthand as
  `~[@1]`, then zsh expands that dynamic named directory before `tj` runs.
- The journal records **what happened, not what the user was trying to do**.
  It has no intent, no reasoning, and no record of what was already ruled
  out. If the goal matters and the prompt does not say it, ask.
- The journal contains whatever appeared on the terminal, **including
  secrets**. Do not quote credentials back, and do not send journal contents
  anywhere the user did not ask you to.
