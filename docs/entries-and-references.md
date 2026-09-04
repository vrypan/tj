# Entries and references

Each recorded command has a monotonically increasing entry number. Removing an
entry leaves a hole. Numbers are never reused. An unfinished entry has no `rc`
resource and remains in the journal.

## List entries

```sh
tj hist
tj hist @42 @50..@60
tj hist @release-build.
tj hist --pinned
```

A trailing dot selects a journal.

History shows two flag positions: `*` for pinned and `!` for a nonzero exit
status. It also shows the entry reference, output size, start date, command,
and nonzero status. Long commands wrap to the terminal width. Redirected
output uses the same fields without color or wrapping.

`tj last` prints the reference of the last entry that completed.

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

When output goes to a terminal, `cat` renders terminal control sequences. When
it is redirected or piped, raw bytes are the default. `--plain` removes terminal
formatting; `--raw` always preserves recorded bytes.

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
tj pin @40..@45
tj pin --remove @42
tj pin
```

Pinning and unpinning are idempotent. A pin protects an entry from ordinary
removal. It does not currently define a retention policy.

Ranges are inclusive, apply only to the current journal, and skip numbering
holes.

## Remove data

```sh
tj rm @42
tj rm @42/out
tj rm @2..@10
tj rm @12 @15/out @20..@25
tj rm --force @42
```

Removal only changes the current journal. Targets are processed from left to
right. Pinned entries are skipped unless `--force` is present. The currently
running entry cannot be removed.

Removing an entry also removes its pin, output, resources, and metadata.
Removing only `out` preserves the entry, command, exit status, and pin, but
also removes resources published from spans of that output.
Individual published resources cannot be removed separately.

## Interactive browser

`tj tui` opens a full-screen browser for the current journal.

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
`cwd`, `cmd`, and every output line. Long lines are clipped on screen rather
than wrapped; selecting one still prints its complete value. `Up`, `Down`,
`j`, and `k` move the cursor; Space toggles a line and Shift+Up/Down selects an
inclusive range. Enter restores the terminal, prints the selected lines (or
the focused line when nothing is selected), and exits. Escape clears a
selection before returning to the list; `q` returns directly.

Unpinned entries are deleted without a prompt. If the targets include pinned
entries, one prompt offers to include them. The browser restores the terminal
screen and mode when it exits.
