# Journals

A journal is the persistent object in TJ. Opening one starts a writer process
that records commands from its child shell or command. Leaving that process
does not delete the journal.

## Create a journal

```sh
tjctl new project-work
```

Names may contain lowercase ASCII letters, digits, and internal `-` characters.
They must start and end with a letter or digit and may be at most 63 characters
long. If the name is omitted, TJ creates one.

## Temporary journals

`tjctl new --temp [NAME]` creates a journal intended for short-lived work. TJ
removes it when its writer exits, even if it has entries, pins, names, or tags.
Save it while the shell is active to keep it:

```sh
tjctl save
```

Saving keeps the current name and prints it when the writer later finishes.
Use `tjctl mv` after exit to rename it. `tj-new --temp` works during a shell
handoff too. If a temporary writer is killed, a later `tjctl` lifecycle command
removes the inactive leftover; active journals are never reclaimed.

Temporary writers export `TJ_TEMPORARY=1`. It describes how that writer began,
so it remains set after `save`; the journal marker, not this environment
variable, is the authoritative saved state.

## Open an existing journal

```sh
tjctl use project-work
tjctl use work                 # an unambiguous suffix also works
```

`use` starts a fresh child process. It does not restore paths, environment
variables, shell state, or old processes. New entry numbers continue after the
highest number already present. Existing unfinished entries are preserved.

Only one TJ process may write to a journal at a time.

Use `tj-new` or `tj-use` from an interactive zsh or Fish shell. Outside a journal they
delegate to `tjctl new/use`. Inside one, they keep the current shell while the
proxy moves recording to the selected journal. The shell's cwd, environment,
jobs, functions, and editor state remain intact. `tjctl new/use` intentionally
refuse an in-journal invocation and tell the user to use the shell helpers.
Handoff is unavailable from tmux and GNU Screen in this version.

## Choose a child shell

Normally, `new` and `use` start `$SHELL` with no arguments. To select a
different interactive shell invocation, put it after `--`:

```sh
tjctl new project-work -- zsh -l
```

The command after `--` must launch interactive zsh or Fish that loads its TJ
plugin for recording to work. Direct commands and noninteractive shells do not
produce shell command boundaries and therefore do not create entries.

## Splash and terminal title

New and continued journals show a short recording splash. Disable it with:

```sh
tjctl use project-work --no-splash
```

`TJ_NO_SPLASH=1` sets the default. Explicit command-line options take
precedence over environment values.

The zsh plugin evaluates a terminal-title format at each prompt. The default is
`TJ | %3~`. Override it with either form:

```sh
tjctl use project-work --title 'recording | $TJ_REF | ${PWD:t}'
TJ_TITLE='recording | %3~' tjctl use project-work
```

Use `--title none` to leave titles to other shell configuration.

While recording, TJ alternates a filled and empty circle in terminal titles.
The default interval is 1500 milliseconds:

```sh
tjctl use project-work --title-blink 3000
tjctl use project-work --title-blink 0     # disable blinking
```

`TJ_TITLE_BLINK` sets the default interval.

## Replay

`tjctl use` replays the journal without recorded delays before starting the new
child. Use `--no-replay` to skip this.

For controlled playback:

```sh
tjctl replay project-work
tjctl replay project-work --speed 4 --max-pause 500
tjctl replay project-work --from 20 --to 30
tjctl replay project-work --duration
```

Replay suppresses terminal bells. `tj-tape` converts replay output for tools
that consume terminal recordings.

## List and identify journals

```sh
tjctl ls -l
tjctl ls                       # names only
tjctl ls -l -n 10
tjctl current
```

`ls` prints one journal name per line. `ls -l` also shows the active marker,
entry count, and the UTC dates of the earliest and latest remaining completed
entries. A dash indicates that no completed entry has valid timing metadata.
Journals are ordered by latest entry, newest first; journals without timing
metadata come last. In the long form, the current journal is marked with `*`.

Use `-n NUMBER` or `--number NUMBER` to show at most that many journals after
sorting. Zero produces no output.

`current` requires `TJ_JOURNAL`, which is set inside a journal.

## Rename a journal

```sh
tjctl mv project-work client-work
```

The journal must not be active. Renaming changes qualified references that
contain the old journal name.

## Measure journal storage

```sh
tjctl du project-work
tjctl du project-work --bytes
tjctl du project-work --chart
tjctl du project-work --chart --bytes
```

Without a journal argument, `du` uses the current journal. The total is logical
file size, not allocated disk blocks. Chart mode shows the size of each entry.

## Delete a journal

```sh
tjctl rm project-work
tjctl rm project-work --force
```

The journal must not be active. TJ asks for confirmation when appropriate and
refuses to delete pinned entries unless `--force` is present.

Deletion removes the journal directory and all entries and annotations stored
inside it.
