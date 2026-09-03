# tj — Terminal Journal

TJ records terminal work in persistent journals. Each shell command becomes a
numbered entry containing the command, working directory, terminal output,
prompt, exit status, and timing metadata.

Recorded entries can be inspected, searched, named, tagged, pinned, removed,
or used as input to later commands. Reading an entry does not run its command
again.

```sh
curl -s https://example.com/data.json   # recorded as entry 1
jq .items "$(tj @1/out)"
tj hist
tj cat @1
tj grep error
tj tui
```

TJ provides two commands:

- `tjctl` creates, opens, replays, and manages journals.
- `tj` works with journal entries and their resources.

## Install

With Homebrew:

```sh
brew install vrypan/tap/tj
```

Or build from source with Zig 0.16.0:

```sh
git clone https://github.com/vrypan/tj.git
cd tj
make install
```

Release archives and custom install prefixes are described in
[Installation](docs/installation.md).

## Configure a shell

For zsh, add the plugin to `~/.zshrc`:

```zsh
source ~/.local/share/tj/tj.plugin.zsh
```

Homebrew installs the plugin under its own prefix:

```zsh
source "$(brew --prefix)/share/tj/tj.plugin.zsh"
```

For Fish, add this to `~/.config/fish/config.fish`:

```fish
source ~/.local/share/tj/tj.plugin.fish
```

With Homebrew:

```fish
source "(brew --prefix)/share/tj/tj.plugin.fish"
```

Start a new shell, then check the setup:

```sh
tj --version
tjctl --version
```

The shell plugin records command boundaries and enables journal-aware
completion. Zsh also expands bare references such as `@12/out` when you press
Enter. Inside a journal, Ctrl-X Ctrl-T opens the entry browser. TJ can start
without a plugin, but shell commands will not be recorded.

## Start a journal

Create a journal and open a shell inside it:

```sh
tjctl new project-work
```

Leave the journal with `exit`. Open it again later:

```sh
tjctl use project-work
```

For disposable work, use a temporary journal. It is removed on exit unless
you save it from the shell:

```sh
tjctl new --temp
tjctl save
```

By default, `use` quickly replays the recorded terminal output before opening
a new shell. Use `--no-replay` to skip it. Continuing a journal does not restore
old processes, environment variables, or shell state.

Use `tj-new` and `tj-use` from an interactive zsh or Fish shell. Outside TJ they behave like
`tjctl new/use`; inside TJ they keep the current shell and move recording to
the selected journal.

Useful journal commands:

```sh
tjctl ls -l
tjctl current
tjctl mv project-work new-name
tjctl rm new-name
```

See [Journals](docs/journals.md) for temporary journals, replay, disk usage,
titles, and deletion.

## Work with entries

Inside a journal:

```sh
tj hist                       # list entries
tj hist @12                   # show details for one entry
tj cat @12                    # show recorded output
tj cat @12/out                # show only recorded output
tj grep 'connection refused'  # search commands and output
tj name @12 build-failure
tj tag @12 @15..@18 bug
tj pin @12
tj rm @15..@18
```

Every entry has core resources:

- `cmd` — the command as typed
- `out` — recorded terminal output
- `cwd` — the working directory
- `prompt` — the rendered prompt
- `rc` — the exit status, when the command finished
- `meta.json` — timing, recording, and optional expanded-command metadata

`"$(tj @REF)"` is TJ's canonical POSIX-shell form for an entry filesystem path.
Fish uses its equivalent `(tj @REF)`. In interactive zsh, the plugin rewrites a
valid bare `@REF` on Enter as a convenience, so `cat @12/out` runs as
`cat "$(tj @12/out)"`.
Qualified references select another journal: `@work.12/out`. Commands that
change entries only operate on the current journal.

See [Entries and references](docs/entries-and-references.md) for ranges, names,
tags, pins, removal, completion, and the TUI.

## Contributing

TJ does not accept pull requests. To report a specific bug or request a
specific feature, open an issue and document it clearly. See
[Contributing](CONTRIBUTING.md).

## Documentation

- [Installation](docs/installation.md)
- [Journals](docs/journals.md)
- [Entries and references](docs/entries-and-references.md)
- [Shell integration](docs/shell-integration.md)
- [Search and output](docs/search-and-output.md)
- [Agents and published resources](docs/agents-and-resources.md)
- [Journal storage](docs/storage.md)
- [OSC ELLO protocol](docs/osc-3110.md)
- [Development](docs/development.md)
- [TJ specification](TJ-spec.md)
- [Open work](TODO.md)

## Current limits

- Shell recording currently supports zsh and Fish.
- Only one TJ process can write to a journal at a time.
- Automatic retention and pruning are not implemented.
- Journals may contain commands, output, paths, and other sensitive data. Their
  directories are created with permissions for the current user only.
