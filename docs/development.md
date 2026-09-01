# Development

TJ requires Zig 0.16.0.

```sh
make              # native debug build
make check        # formatting and all tests
zig build test    # unit and PTY-driven integration tests
```

`make check` is the required local verification. PTY tests should run in a
normal terminal environment.

## Generated completion

The build runs a host-only `tj-completion` helper. It generates ready-to-install
zsh, bash, and fish completion files under `zig-out/share`. The helper binary is
not installed or included in release archives.

## Dependencies

Dependencies are pinned in `build.zig.zon`:

- Zecli 0.3.2 supplies command parsing, help, environment mapping, and command
  completion generation.
- Zooi 0.1.3 supplies terminal mechanics for `tj tui` and the startup splash.

Both are source dependencies and add no runtime package dependency. TJ embeds
SQLite through its C source.

## Build release packages

```sh
make list
make -j6 all
make package
```

Build trees and archives are written below `dist/`. Each archive contains one
`tj-VERSION-TARGET` root directory with `bin` and `share` beneath it.

Supported targets are `{aarch64,x86_64}` combined with `{macos, linux-musl,
linux-gnu}`. Musl builds are static. Release packages default to `ReleaseSafe`
and strip debug information.

## Publish a release

Update the version in `build.zig.zon`, commit it, and push `main`. Then run:

```sh
gh workflow run release.yml --ref main
gh run list --workflow release.yml --limit 1
gh run watch RUN_ID --exit-status
```

The workflow runs checks, creates all archives and `SHA256SUMS`, creates the
tag and GitHub release, and updates the source-building formula in
`vrypan/homebrew-tap`. It refuses to overwrite an existing tag.

Retry only the Homebrew formula update with:

```sh
gh workflow run update-homebrew-formula.yml -f tag=v0.5.0
```
