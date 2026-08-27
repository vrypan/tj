---
name: tj
description: Read the terminal journal to find out what actually happened in this terminal - what was run, what it printed, what failed. Use whenever the user refers to something on their screen without saying what ("this", "that error", "why did it fail", "the last command"), asks about a command they ran, or gives a @N reference. Also use before asking the user to paste output or re-run something: it may already be recorded.
---

# Terminal Journal

The user's terminal is recording. Every command is an **interaction** with a
number, and you can read what it ran, what it printed, and how it ended -
without asking them to paste anything and without running it again.

## Is there a journal?

`$TJ_SESSION` is set inside a recorded session. If it is empty, there is no
journal: answer from what you were told.

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
    1  0      185  git status
    2  1      12K  go test ./...
    3  -      53K  vi parser.go
```

Columns: number, exit status, size of the output, first line of the command.
The whole index is a few hundred tokens even for a long session. The output
of a single interaction can be 50K. **Read the index first and fetch
deliberately.**

Then take only what you need:

```sh
tj cat @2              # what interaction 2 printed
tj cat --tail 20 @2    # just the end, where errors are
tj cat --head 5 @2     # just the beginning
tj cat @2/cmd          # the command line as it was typed
```

Use `--tail` and `--head` rather than piping to `tail` or `head`: a pipeline
is a compound command, and a narrow permission rule will refuse it.

When a window hides something, `tj` says so on stderr: `showing 20 of 431
lines`. If you see that, you are looking at a fragment - fetch more before
concluding anything about what is not shown.

## Resolving "this" and "that"

`@-` is the last **completed** interaction. Your own invocation is still
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

- **A `-` in the status column means the interaction never finished.** It is
  in progress or was killed. Never read it as success.
- `rc` is the shell's status for the **whole line**. On a pipeline that is
  the last element, so `curl … | head` reports `0` when `curl` failed. Empty
  output with status `0` on a pipeline is a strong hint that something
  upstream failed quietly.

## What the output actually contains

`out` is what the terminal saw, escape sequences and all. `tj cat` renders it
as readable text when writing to a pipe, which is what you will get. Add
`--raw` only if you specifically need the bytes, including colour codes.

Two things will look wrong and are not:

- **Full-screen programs record almost nothing.** Editors, pagers and
  anything that takes over the screen paint on the alternate screen, which is
  not part of scrollback, so it is not recorded either. `vi notes.txt` leaves
  a command, a status, and a near-empty output. `meta.json` says
  `"fullscreen"` when this happened. This is by design; do not report it as
  missing data.
- **Prompt redraw** appears at the end of an interaction's output. It belongs
  to the shell, not the command.

## Referring across sessions

`@42` means this session. Another session is named by a suffix of its id:
`@pgsd.42/out`. `$TJ_SESSION_SHORT` holds the current one's suffix. `tj
sessions` lists them, newest first.

## Published resources

A program can mark part of its output as a named file, which then appears
under the interaction:

```sh
tj cat @42/files/data.csv
```

`tj hist` does not list these. Check `@42/meta.json` for a `resources` map,
or run `tj complete '@42/'` to see what an interaction holds.

## Output the user may want to reuse

When part of an answer is meant to be **used** rather than read - a table of
data, a script, a config block - put it in a fenced block with a language
tag, and keep prose out of the fence:

    ```csv
    date,amount
    2026-08-01,12.50
    ```

A wrapper may turn fenced blocks into files of this interaction, taking the
mime type from that tag, which is why the tag is worth getting right. Whether
such a wrapper is in the pipeline is not something you can see from here.

So: **do not claim a file was written, and do not invent a name or a number
for it.** You do not choose either. Write the block, say what it is, and stop
there.

## Rules

- **Use `tj cat`, never `cat @N/out`.** The second replays the whole
  recording to the terminal, which is slow, makes a mess of the screen, and
  gets recorded again as a new interaction - a 50K one. This is the single
  most expensive mistake available here.
- **Do not fetch everything.** Fetching every interaction's output costs
  hundreds of times what the index costs and is almost never worth it.
- **Quote references** when passing them to `tj` from inside a session:
  `tj cat '@1'`. The shell integration rewrites unquoted `@` words into paths
  before `tj` runs.
- The journal records **what happened, not what the user was trying to do**.
  It has no intent, no reasoning, and no record of what was already ruled
  out. If the goal matters and the prompt does not say it, ask.
- The journal contains whatever appeared on the terminal, **including
  secrets**. Do not quote credentials back, and do not send journal contents
  anywhere the user did not ask you to.
