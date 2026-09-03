# Search and output

## Search journals

`tj grep` searches command and output resources for a literal byte string:

```sh
tj grep panic
tj grep --cmd docker
tj grep --out 'connection refused'
tj grep --all example.com
tj grep --ignore-case warning
tj grep --tui warning
tj grep -- --pattern-starting-with-a-dash
```

Options that select `--cmd` or `--out` may be combined. Without either option,
both are searched. `--all` searches every journal.

`--tui` opens the entry browser containing each matching entry once, even when
several lines or both resources match. It searches the current journal and may
be combined with `--cmd`, `--out`, and `--ignore-case`. It cannot be combined
with `--all` or `--color`.

Exit status is `0` when a match is found, `1` when no match is found, and
greater than `1` for an error.

Search output resembles history. `>` marks command matches and `<` marks output
matches. Each result is trimmed around the match to fit the terminal width.
Whitespace is collapsed for display, so recorded tables, progress output, and
indentation do not create empty-looking rows. Control sequences are removed
before results are written to the terminal.

Highlighting follows common grep behavior:

```sh
tj grep --color=auto error
tj grep --color=always error
tj grep --color=never error
```

`auto` uses color only on a terminal, `always` emits color for pipes too, and
`never` disables it. The default is `never`. The optional
`contrib/tj-grep` script adds ripgrep regular expressions, context, line
numbers, and arbitrary `rg` options; new scripts should use `tj grep`.

When shown directly in a journal terminal, grep and history enclose their own
display in a noout region so search results do not become input to the next
search. Piped output contains no protocol markers.

## Render recorded output

`tj cat` renders output according to its destination:

- A terminal receives the recorded terminal bytes.
- A pipe or file receives plain rendered text.
- `--plain` emits text without terminal formatting.
- `--raw` emits the exact stored bytes.

Plain rendering deliberately operates one line at a time. A single
unterminated line may therefore require memory proportional to its length.

## Fullscreen output

TJ recognizes alternate-screen terminal output. Fullscreen content remains
visible while the program runs but is omitted from the normal `out` resource.
This prevents editor and TUI drawing traffic from dominating recorded output.

Use `--keep-osc` on `tjctl new` or `tjctl use` when debugging TJ protocol
messages and terminal control sequences.

## Omit command output explicitly

```sh
tj noout -- command args...
```

The command's output remains visible in the terminal. Its `out` resource
contains one fixed placeholder:

```text
<tj:noout>
```

The wrapper preserves the child exit status and signal behavior. If it is
interrupted before emitting the closing marker, omission continues until the
current entry boundary. TJ resets the open region at that boundary, so
later entries record normally.

Resource and noout regions do not nest. Invalid nesting is logged and ignored.
No noout byte counts or flags are added to `meta.json`.

See the [OSC ELLO protocol](osc-3110.md) for framing and direct emission.
