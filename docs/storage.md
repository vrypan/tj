# Journal storage

## Journal layout

TJ stores journals below `~/.tj`, or the directory selected by `TJ_HOME` or
`--home`:

```text
~/.tj/
├── .locks/
└── project-work/
    ├── .tj-temporary       # present only until `tjctl save`
    ├── log
    ├── 1/
    │   ├── cmd
    │   ├── cwd
    │   ├── out
    │   ├── prompt
    │   ├── rc
    │   ├── pin              # present only when pinned
    │   └── meta.json
    └── 2/
```

Recorded resources are ordinary files. Directories use mode `0700` and files
use mode `0600`. A journal can contain commands, output, paths, credentials
printed by programs, and other sensitive terminal data.

## Pins

An empty `pin` marker inside an entry directory means that entry is pinned.
The marker is private TJ bookkeeping and is not offered as an entry resource.
It moves or is deleted with the entry directory.

## Locks

`~/.tj/.locks/JOURNAL` contains the lifetime lock used to prevent concurrent
writers. Activity is determined by the held advisory lock, not by whether the
lock file exists. Lifetime lock files are stable and normally remain after a
journal is removed; their presence does not mean a writer is active.

Short mutation and namespace locks coordinate entry deletion, pin updates,
journal creation, rename, and removal. Read-only commands remain
available while a writer is active.

This coordination is intended for processes on one host, not for a shared
network filesystem.

## Numbering and lifetime

Journals outlive writer processes. A new writer starts at one greater than the
highest numeric entry directory. An unfinished entry has no `rc`, but still
uses its number. Deleted numbers are not reused.

A newly created journal may be removed automatically when it records nothing.
An existing journal opened with `tjctl use` is never removed because that run
was empty. A journal containing a diagnostic log is also preserved.

A journal created with `tjctl new --temp` has a private `.tj-temporary` marker.
The writer removes the whole journal on exit while that marker remains. `tjctl
save` removes the marker through the active proxy, making the journal
persistent even if it is empty. Later `tjctl` lifecycle commands reclaim an
inactive marker-bearing journal left by an unclean writer exit.

## Recording diagnostics

The journal warning log is bounded. Recording failures are logged when
possible while the PTY continues forwarding terminal traffic.
An entry's `rc` is the command's real exit status; its presence does not prove
that every buffered output byte reached storage. A failed final output flush
disables further recording for that writer and is logged when possible.

See the [OSC ELLO protocol](osc-3110.md) for TJ's in-band messages.
