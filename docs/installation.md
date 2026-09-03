# Installation

## Homebrew

```sh
brew install vrypan/tap/tj
```

The formula builds TJ from source and installs both binaries, the zsh and Fish plugins,
shell completions, and helper programs.

## Release archive

Download an archive for your platform from the
[release page](https://github.com/vrypan/tj/releases). Install its `bin` and
`share` trees under a prefix:

```sh
mkdir -p ~/.local
tar xzf tj-VERSION-x86_64-linux-musl.tar.gz \
  -C ~/.local --strip-components=1
```

Use the archive matching the operating system and CPU architecture.

## Build from source

TJ requires Zig 0.16.0.

```sh
git clone https://github.com/vrypan/tj.git
cd tj
make install
```

The default prefix is `~/.local`. Set `PREFIX` to change it:

```sh
sudo make install PREFIX=/usr/local
```

The install contains:

- `bin/tj`
- `bin/tjctl`
- `bin/tj-fence`
- `bin/tj-grep`
- `bin/tj-tape`
- `share/tj/tj.plugin.zsh`
- `share/tj/tj.plugin.fish`
- zsh, bash, and fish command completions

Remove files installed by `make install` with the same prefix:

```sh
make uninstall
```

This does not remove journals from `~/.tj`.

## Configure zsh

Load the plugin from `~/.zshrc`:

```zsh
source ~/.local/share/tj/tj.plugin.zsh
```

For Homebrew:

```zsh
source "$(brew --prefix)/share/tj/tj.plugin.zsh"
```

For a custom prefix, use its `share/tj/tj.plugin.zsh` path. Start a new shell
after changing the file. The plugin makes TJ's installed zsh command
completions available automatically.

## Configure Fish

Fish 4.0.0 or later is required for recording.

Load the plugin from `~/.config/fish/config.fish`:

```fish
source ~/.local/share/tj/tj.plugin.fish
```

For Homebrew:

```fish
source "(brew --prefix)/share/tj/tj.plugin.fish"
```

For a custom prefix, use its `share/tj/tj.plugin.fish` path. Start a new shell
after changing the file.

## Verify the installation

```sh
tj --version
tjctl --version
whence -v _tj_completer
```

In zsh, the last command should report a shell function from `tj.plugin.zsh`.
In Fish, use `functions -q _tj_preexec` instead.

## Ghostty and remote SSH hosts

Some remote systems do not include Ghostty's `xterm-ghostty` terminfo entry.
Install it on the remote host once:

```sh
infocmp -x xterm-ghostty | ssh host 'tic -x -'
ssh host 'infocmp -x xterm-ghostty >/dev/null && echo installed'
```

Without the entry, applications on the remote host may handle Backspace or
other keys incorrectly.
