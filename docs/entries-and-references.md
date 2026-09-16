# Entries and references

Each recorded command has a monotonically increasing entry number. Removing an
entry leaves a hole. Numbers are never reused. An unfinished entry has no `rc`
resource and remains in the journal.

## List entries

```sh
tj history
tj history @42 @50..@60
tj history @release-build.
tj history --pinned
tj history --ids @42 @50..@60
tj history --pinned --ids | tj tui
```

A trailing dot selects a journal.

History shows two flag positions: `*` for pinned and `!` for a nonzero exit
status. It also shows the entry reference, output size, start date, command,
and nonzero status. Long commands wrap to the terminal width. Redirected
output uses the same fields without wrapping.

Without explicit targets, a terminal standard input lists the current
journal, same as always. Redirected standard input is instead read as a
whitespace-separated list of current-journal entry numbers to show, so
`tj grep error --ids | tj history` narrows history to grep's matches. Explicit
target operands always take precedence over redirected input. Empty
redirected input selects nothing rather than everything.

`tj last` prints the positive decimal number of the last entry that completed.

`--ids` prints the unique selected entry numbers in ascending order as one
space-separated line. It is current-journal-only, including when a target is
explicitly qualified. An empty selection writes no bytes. Its output is
always plain, regardless of any `--color` setting.

`--color=auto|always|never` (or `--colour`) controls layout color; `auto` is
the default and colors a real terminal unless `NO_COLOR` is set or `TERM` is
unusable. `always` colors output even when piped; `never` disables it.
`TJ_COLOR` sets the default between the command line and history's own
default.

## Read entries

```sh
tj cat @42
tj cat @42/out
tj cat @42/cmd @42/rc
tj cat @40..@45
tj cat --plain @42/out
tj cat --raw @42/out
tj cat --head 20 @42/out
tj cat --tail 20 @42/out
```

When output goes to a terminal, `cat` passes recorded bytes to the terminal for
rendering. When redirected or piped, plain rendered text is the default.
`--plain` removes terminal formatting; `--raw` always preserves recorded bytes.

## Reference forms

| Reference | Meaning |
|---|---|
| `@42` | Entry 42 in the current journal |
| `@-` | The last completed entry |
| `@release-build.42` | Entry 42 in another journal |
| `@40..@45` | An inclusive numeric range in the current journal |
| `@release-build.` | The complete selected journal, where supported |

Journal selectors use an exact name first, then an unambiguous suffix. Printed
qualified references use the complete journal name.

Words such as `@username` are not entry references and remain literal.

## Shell references

References are arguments to TJ commands:

```sh
tj cat @42/out
tj cat @42/cmd @42/rc
```

`"$(tj @REF)"` is the canonical shell form for an entry filesystem path:

```zsh
jq .items "$(tj @42/out)"
diff "$(tj @42/out)" "$(tj @45/out)"
```

Use `tj @42/out` (short for `tj resolve @42/out`) when a program needs the
stored filesystem path. This is also the portable command-substitution form:

```fish
cat (tj @42/out)
```

```zsh
cat "$(tj @42/out)"
```

In interactive zsh, the plugin rewrites a valid bare reference when Enter
accepts the line, so `cat @42/out` is a convenience spelling for the canonical
form. Fish uses `(tj @42/out)`. Use the canonical form in scripts and in shells
without the zsh plugin.

## Entry resources

Core resources are stored directly under the entry:

- `cmd` — command text as typed
- `cwd` — absolute logical working directory
- `out` — terminal output
- `prompt` — rendered prompt
- `rc` — exit status
- `meta.json` — timing, recording, and optional `expanded_cmd` metadata
- `files/` — files published by the command

Programs may publish additional resources. See
[Agents and published resources](agents-and-resources.md).

The plugin provides `tjcd` to return to an entry's directory:

```sh
tjcd @42
tjcd @release-build.42
```

## Pins

```sh
tj pin @42
tj pin @40..@45 @50 @52
tj pin --remove @42 @50..@52
tj pin @42 --remove
tj pin
tj pin --ids
```

Pinning and unpinning are idempotent. Multiple references and ranges are
deduplicated and applied in ascending numeric order. TJ validates the complete
batch under one current-journal mutation guard before changing any markers. A
pin protects an entry from ordinary removal. It does not currently define a
retention policy.

`tj pin --ids` is a listing mode equivalent to `tj history --pinned --ids`.
It cannot be combined with targets or `--remove`.

Without explicit targets and without `--ids`, a terminal standard input pins
or unpins nothing and instead lists the current journal's pinned entries, same
as always. Redirected standard input is instead read as a whitespace-separated
list of current-journal entry numbers to pin (or unpin, with `--remove`), so
`tj grep error --ids | tj pin` pins grep's matches. Explicit target operands
always take precedence over redirected input. Empty redirected input changes
nothing.

Ranges are inclusive, apply only to the current journal, and skip numbering
holes.

## Remove data

```sh
tj rm @42
tj rm @42/out
tj rm @2..@10
tj rm @12 @15/out @20..@25
tj rm --include-pinned @42
tj rm --ignore-missing @2 @2
echo '2 4' | tj rm --stdin
```

Removal only changes the current journal. Targets are processed from left to
right. Pinned entries are skipped unless `--include-pinned` is present. The
currently running entry cannot be removed.

`--ignore-missing` makes a missing explicit entry or an entirely empty range
harmless instead of an error, including a duplicate or overlapping operand
that an earlier operand already removed. Other failures (permission,
corruption, an invalid reference, an unsupported resource, a foreign journal,
or the currently running entry) are still reported. `--include-pinned` is
orthogonal and may be combined with it.

`tj rm` requires either explicit target operands or `--stdin`, never both.
`--stdin` reads a whitespace-separated list of current-journal entry numbers
(capped at 4 MiB, sorted and deduplicated) and validates the whole batch
before removing anything; combine it with `--ignore-missing` to tolerate
stale ids in the batch. Unlike `history` and `pin`, `tj rm` never infers its
targets from an ambient redirected pipe — `--stdin` must be explicit, so a
stray pipe cannot make removal destructive by accident.

Removing an entry also removes its pin, output, resources, and metadata.
Removing only `out` preserves the entry, command, exit status, and pin, but
also removes resources published from spans of that output.
Individual published resources cannot be removed separately.

## Interactive browser

`tj tui [TARGET...]` opens a full-screen browser for the current journal.
Targets may be unqualified entry references or current-journal numeric ranges.
They are validated before the terminal switches to its alternate screen.

When standard input is redirected, it is read as a space-separated list of
entry numbers and the browser shows only those entries. Numbers are sorted and
duplicates are ignored:

```sh
echo 100 101 1002 | tj tui
tj history --ids @100..@200 | tj tui
tj pin --ids | tj tui
```

Explicit target operands take precedence over redirected standard input. An
empty explicit selection is an error rather than an unfiltered browser.

| Key | Action |
|---|---|
| `Up`, `Down`, `j`, `k` | Move |
| `Home`, `g` / `End`, `G` | First / last entry |
| `Page Up`, `Page Down` | Move one page |
| `Enter` | Show entry details |
| `Space` | Toggle selection |
| `Shift+Up`, `Shift+Down` | Extend or shrink a range |
| `Escape` | Clear the selection |
| `p` | Pin or unpin |
| `d` | Delete |
| `e` | Print selected entry IDs to standard output and quit |
| `r` | Refresh |
| `q` | Quit |

Pin and delete apply to every selected entry. With no selection, they apply to
the focused entry. Details use the focused entry.

`e` requires an explicit selection. It writes the selected entry IDs in
ascending order as one space-separated line, followed by a newline. This makes
it useful with another command:

```sh
tj tui | script
```

The optional `contrib/tj-md` companion turns a selection into a Markdown
terminal transcript. It reads the IDs from standard input; `--prompt` uses
the recorded prompt before each command.

```sh
tj tui | contrib/tj-md > transcript.md
tj tui | contrib/tj-md --prompt
```

The detail view is a list of selectable logical lines, including its metadata,
`cwd`, `cmd`, and every output line. Long lines wrap across visual rows but
remain one selectable item. `Up`, `Down`, `j`, and `k` move the cursor; Space
toggles a line and Shift+Up/Down selects an inclusive range. Enter restores
the terminal, prints the complete selected lines (or the focused line when
nothing is selected), and exits. Escape clears a selection before returning
to the list; `q` returns directly.

Unpinned entries are deleted without a prompt. If the targets include pinned
entries, one prompt offers to include them. The browser restores the terminal
screen and mode when it exits.
