# Journal storage

## Journal layout

TJ stores journals below `~/.tj`, or the directory selected by `TJ_HOME` or
`--home`:

```text
~/.tj/
├── .locks/
└── project-work/
    ├── journal.sqlite3
    ├── log
    ├── 1/
    │   ├── cmd
    │   ├── cwd
    │   ├── out
    │   ├── prompt
    │   ├── rc
    │   └── meta.json
    └── 2/
```

Recorded resources are ordinary files. Directories use mode `0700` and files
use mode `0600`. A journal can contain commands, output, paths, credentials
printed by programs, and other sensitive terminal data.

## Annotation database

`journal.sqlite3` stores sparse journal-local names, tags, and pins separately
from recording-time `meta.json`. TJ embeds SQLite; no system SQLite library or
command is required.

Updates use transactions and a bounded busy wait. The database uses persistent
WAL mode, so `journal.sqlite3-wal` and `journal.sqlite3-shm` may be present.
Copy an inactive journal directory as one unit. Copying only the main database
or copying while it is being changed is not a supported snapshot.

## Locks

`~/.tj/.locks/JOURNAL` contains the lifetime lock used to prevent concurrent
writers. Activity is determined by the held advisory lock, not by whether the
lock file exists.

Short mutation and namespace locks coordinate entry deletion, annotation
updates, journal creation, rename, and removal. Read-only commands remain
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

## Recording diagnostics

The journal warning log is bounded. Recording failures are logged when
possible while the PTY continues forwarding terminal traffic.

See the [OSC ELLO protocol](osc-3110.md) for TJ's in-band messages and
[TJ-spec.md](../TJ-spec.md) for the complete storage contract.
