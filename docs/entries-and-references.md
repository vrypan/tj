# Entries and references

Each recorded command has a monotonically increasing entry number. Removing an
entry leaves a hole. Numbers are never reused. An unfinished entry has no `rc`
resource and remains in the journal.

## List entries

```sh
tj hist
tj hist @42 @50..@60
tj hist @release-build.
tj hist --tag bug --tag parser
tj hist --pinned
```

A trailing dot selects a journal. Multiple tag filters use AND semantics.

History shows four flag positions: `*` for pinned, `@` for named, `#` for
tagged, and `!` for a nonzero exit status. It also shows the entry reference,
output size, start date, command, name, tags, and nonzero status. Long commands
wrap to the terminal width. Redirected output uses the same fields without
color or wrapping.

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
| `@build-failure` | A named entry in the current journal |
| `@-` | The last completed entry |
| `@release-build.42` | Entry 42 in another journal |
| `@release-build.build-failure` | A named entry in another journal |
| `@40..@45` | An inclusive numeric range in the current journal |
| `@release-build.` | The complete selected journal, where supported |

Journal selectors use an exact name first, then an unambiguous suffix. Printed
qualified references use the complete journal name.

Unresolved names remain literal. This avoids conflicts with programs that use
arguments such as `@username`.

## zsh references

The canonical zsh form is a dynamic named directory:

```sh
~[@42]/out
~[@build-failure]/out
~[@release-build.42]/out
```

At an interactive prompt, unquoted references at the start of shell words may
use the shorter form:

```sh
jq .items @42/out
diff @42/out @45/out
```

The plugin changes the shorthand to `~[@REF]` before zsh parses the command.
Quoted references and text such as `user@host` are not changed.

Use `tj resolve @42/out` when a program needs the stored filesystem path.

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

## Names

```sh
tj name @42 build-failure
tj name @42
tj name --remove build-failure
tj name
```

An entry has at most one name. Assigning another name renames it. Names are
unique within a journal and contain lowercase letters, digits, and internal
hyphens; they must start with a letter. Names extend the reference namespace,
for example `@build-failure/out`.

## Tags

Targets precede tags:

```sh
tj tag @42 bug parser
tj tag @42 @47 @50..@55 bug
tj tag --remove @42 @47 parser
tj tag @42 @47
tj tag
```

Tags are normalized to lowercase. They may contain letters, digits, `.`, `_`,
and `-`. Adding an existing tag and removing a missing tag are harmless.

Ranges are inclusive, apply only to the current journal, and skip numbering
holes.

## Pins

```sh
tj pin @42
tj pin @40..@45
tj pin --remove @42
tj pin
```

Pinning and unpinning are idempotent. A pin protects an entry from ordinary
removal. It does not currently define a retention policy.

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

Removing an entry also removes its name, tags, pin, output, resources, and
metadata. Removing only `out` preserves the entry, command, exit status, and
annotations, but also removes resources published from spans of that output.
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
| `t`, `T` | Add or remove a tag |
| `n` | Name or rename |
| `d` | Delete |
| `r` | Refresh |
| `q` | Quit |

Pin, tag, untag, and delete apply to every selected entry. With no selection,
they apply to the focused entry. Naming and details use the focused entry.

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
