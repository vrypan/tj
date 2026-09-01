# Installation

## Homebrew

```sh
brew install vrypan/tap/tj
```

The formula builds TJ from source and installs both binaries, the zsh plugin,
shell completions, and helper programs.

## Release archive

Download an archive for your platform from the
[release page](https://github.com/vrypan/tj/releases). Install its `bin` and
`share` trees under a prefix:

```sh
mkdir -p ~/.local
tar xzf tj-0.5.1-x86_64-linux-gnu.tar.gz \
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
after changing the file.

## Verify the installation

```sh
tj --version
tjctl --version
whence -v _tj_directory_name _tj_completer
```

The last command should report two shell functions from `tj.plugin.zsh`.

## Ghostty and remote SSH hosts

Some remote systems do not include Ghostty's `xterm-ghostty` terminfo entry.
Install it on the remote host once:

```sh
infocmp -x xterm-ghostty | ssh host 'tic -x -'
ssh host 'infocmp -x xterm-ghostty >/dev/null && echo installed'
```

Without the entry, applications on the remote host may handle Backspace or
other keys incorrectly.
