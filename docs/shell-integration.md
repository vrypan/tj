# Shell integration

`tjctl new/use` launches a PTY proxy. In an active direct TJ shell, use the
plugin's `tj-new/tj-use` helpers instead: they move the active proxy to another
journal without launching a nested proxy. The zsh plugin tells it when a command
starts and ends and provides the command and working directory. Fish 4 provides
those markers itself. Zsh additionally records the rendered prompt and expanded
command. Without a plugin, terminal bytes still pass through but shell entries
are not recorded.

## How recording works

```mermaid
flowchart TB
    subgraph Without["Without TJ"]
        direction LR
        PlainTerminal[Terminal emulator] <-->|terminal bytes| PlainShell[zsh]
        PlainShell <-->|run and wait| PlainCommand[Foreground command]
    end

    subgraph With["With TJ"]
        direction LR
        Terminal[Terminal emulator] <-->|terminal bytes| Proxy[TJ proxy]
        Proxy <-->|inner PTY| Shell[zsh]
        Shell <-->|run and wait| Command[Foreground command]
        Shell -.->|invokes hooks| Plugin[TJ zsh plugin]
        Plugin -.->|OSC metadata| Proxy
        Proxy -->|recorded data| Journal[(Journal)]
    end

    classDef tj fill:#dbeafe,stroke:#2563eb,color:#0f172a
    class Proxy,Plugin,Journal tj
```

TJ inserts the proxy into the existing terminal byte path. The plugin runs
inside the shell and adds metadata; the command still uses the terminal
normally.
Blue nodes are TJ components.

The command lifecycle shows when those extra messages appear:

```mermaid
sequenceDiagram
    actor User
    participant Terminal as Terminal emulator
    participant Proxy as TJ proxy
    participant Plugin as TJ zsh plugin
    participant Shell as zsh
    participant Command as Foreground command
    participant Journal

    Note over Plugin,Shell: The plugin runs inside zsh

    User->>Terminal: Type a command
    Terminal->>Proxy: Input bytes
    Proxy->>Shell: Input through the inner PTY

    Shell->>Plugin: Run preexec hook
    Plugin-->>Proxy: OSC ELLO#59;CONTEXT#59;… ST
    Note right of Proxy: Consume command, cwd, and expanded command
    Plugin-->>Proxy: OSC 133#59;C ST
    Proxy->>Journal: Start entry

    Shell->>Command: Execute
    Command->>Proxy: stdout and stderr through the inner PTY
    Proxy->>Terminal: Display ordinary output
    Proxy->>Journal: Append ordinary output to out

    opt Published resource
        Command-->>Proxy: OSC ELLO#59;RESOURCE#59;… ST
        Command->>Proxy: Resource bytes
        Proxy->>Terminal: Display resource bytes
        Proxy->>Journal: Append to out and named resource
        Command-->>Proxy: OSC ELLO#59;END ST
    end

    opt Output omitted from the journal
        Command-->>Proxy: OSC ELLO#59;NOOUT ST
        Command->>Proxy: Visible bytes
        Proxy->>Terminal: Display visible bytes
        Proxy->>Journal: Write the noout placeholder once
        Command-->>Proxy: OSC ELLO#59;END ST
    end

    Command->>Shell: Exit status
    Shell->>Plugin: Run precmd hook
    Plugin-->>Proxy: OSC 133#59;D#59;rc ST, then OSC 133#59;A ST
    Proxy->>Journal: Finish entry and start prompt capture
    Shell->>Proxy: Rendered prompt bytes
    Proxy->>Terminal: Display prompt
    Proxy->>Journal: Save prompt for the next entry
    Shell->>Plugin: Run zle-line-init hook
    Plugin-->>Proxy: OSC 133#59;B ST
```

The terminal sends input to TJ, and TJ forwards it unchanged to the inner PTY.
Output travels in the opposite direction, which lets the proxy inspect it
before forwarding it to the terminal.

Solid arrows in the lifecycle are ordinary input, output, execution, or
journal writes. Dashed arrows are OSC metadata added by the plugin or a
cooperating command.

OSC ELLO messages are private instructions for TJ. The proxy consumes them, so
they do not appear on screen or in `out`. OSC 133 command-boundary messages are
observed by TJ and also forwarded to the terminal. Ordinary output remains
ordinary terminal data. The proxy also observes OSC 0 and OSC 2 title changes
so it can preserve the application's title while adding the recording marker.

## Load the plugin

### zsh

Add one line to `~/.zshrc`:

```zsh
source /usr/local/share/tj/tj.plugin.zsh
```

For Homebrew:

```zsh
source "$(brew --prefix)/share/tj/tj.plugin.zsh"
```

The plugin preserves existing completion handlers.

### Fish

Fish **4.0.0 or later** is required. TJ uses Fish's native OSC 133 command
markers and OSC 7 working-directory reports. Earlier Fish versions do not
provide those markers; the plugin prints a warning and does not record entries.

Add one line to `~/.config/fish/config.fish`:

```fish
source ~/.local/share/tj/tj.plugin.fish
```

For Homebrew:

```fish
source "(brew --prefix)/share/tj/tj.plugin.fish"
```

Fish records the command, cwd, output, exit status, and prompt boundaries from
Fish's native terminal integration. It does not record zsh's expanded-command
metadata.

## TUI key binding

While a journal shell is at its prompt, Ctrl-X Ctrl-T opens `tj tui`. Closing
the TUI returns to the command line that was being edited. The two-key sequence
avoids the Ctrl-T binding commonly installed by fzf.

In an entry's detail view, Enter returns the focused line or selected lines.
When the browser was opened through the widget, that value is inserted at the
cursor in the current command line.

In zsh, set `TJ_TUI_KEY` before sourcing the plugin to choose another ZLE key sequence,
or set it to `none` to install the widget without binding a key:

```zsh
export TJ_TUI_KEY='^X^J'
source ~/.local/share/tj/tj.plugin.zsh
```

The zsh widget is named `_tj_tui_widget`, so it can also be bound explicitly
with `bindkey`. Fish binds the same Ctrl-X Ctrl-T sequence and uses Fish's
ordinary key-binding mechanism to customize it.

## Reference expansion

`"$(tj @REF)"` is the canonical POSIX-shell form for an entry filesystem path.
Fish uses its native equivalent, `(tj @REF)`. The zsh plugin provides a
convenience: it rewrites a valid unquoted reference
at the start of a shell word when you press Enter:

```text
cat @42/out  ->  cat "$(tj @42/out)"
```

Tab retains ordinary reference and resource completion, so `@42/<Tab>` offers
the entry's resources. Quoted words, unresolved names, and words such as
`user@host` remain unchanged.

Fish does not rewrite bare references. Use the explicit Fish form instead:

```fish
cat (tj @42/out)
```

## Completion

The installation provides command completion for forms such as:

```text
tj <Tab>
tj hist --<Tab>
tjctl use <Tab>
tjctl replay --<Tab>
```

The shell plugin separately completes references. In zsh:

```text
@42/<Tab>
```

Resource completion includes core entry files, `files/`, and published
resources. In Fish, completion also works inside the command substitution:

```text
tj cat @42/<Tab>
tj @42/<Tab>
```

## Prompt variables

The writer exports these variables to its child:

| Variable | Value |
|---|---|
| `TJ_REF` | Qualified reference for the command about to be typed |
| `TJ_NEXT` | Next entry number |
| `TJ_JOURNAL` | Complete journal name |
| `TJ_TITLE` | Shell-evaluated title format, or `none` |
| `TJ_TITLE_BLINK` | Title blink interval in milliseconds |
| `TJ` | Path to the entry command, when discoverable |
| `TJCTL` | Path to the journal command, when discoverable |
| `TJ_SESSION_ID` | Random token authenticating `tjctl` control requests to the writer |

They are unset outside a journal.

Plain zsh example:

```zsh
PROMPT='${TJ_NEXT:+[$TJ_NEXT] }%~ %# '
```

Starship example:

```toml
format = '$all${env_var.TJ_REF}$character'

[env_var.TJ_REF]
format = '[$env_value]($style) '
style = 'dimmed white'
```

## Terminal titles

At a zsh prompt, the plugin evaluates `TJ_TITLE` using zsh prompt expansion. This
allows forms such as `%3~` for the last three components of the working
directory and variables such as `$TJ_REF`.

```sh
tjctl use project-work --title 'TJ | $TJ_REF | %3~'
```

While another foreground program runs, the plugin allows that program to set
the title. The proxy remembers OSC 0 and OSC 2 title changes and adds only the
alternating recording marker. It restores the most recent underlying title on
each update.

Use `--title none` to disable TJ title handling, or `--title-blink 0` to keep
the title format without the alternating marker.
