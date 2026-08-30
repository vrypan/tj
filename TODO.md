# TODO

Things deliberately left undone, with enough context to pick up cold.

---

## Log a warning when a boundary arrives without a command line

A `133;C` with no preceding `cmd` sequence still opens an entry with an empty
`cmd`, but nothing is logged.

Verified: a zsh emitting only OSC 133 - somebody else's shell integration,
with no tj plugin - records entries with `cmd` empty and no `log` file
written at all.

That is precisely the case where the log is the only signal that tj is
running under an integration it does not own, so it is worth having.

- Where: `proxy.zig`, `Recorder.event`, the `.command_run` branch. When
  `command_len == 0`, call `store.warn`.
- Watch out for: the warning must not fire once per command in a shell that
  legitimately has no tj plugin, or the log becomes the largest file in the
  journal. Once per journal is enough.

---

## Larger, and deliberately deferred

### Retention

Journals persist indefinitely. `TJ-spec.md` lists retention as an open question
and it still is. The journal holds whatever appeared on the terminal, including
secrets, and grows without bound.

Decided so far: exit is **not** the retention boundary. Deleting a journal
when its terminal closes would break `@SUFFIX.N`, which is defined to resolve
after a writer has ended, and would throw away exactly the recordings worth
keeping. Only journals newly created by an empty `tjctl new` may be removed at
writer exit; `tjctl use` never deletes its existing journal.

Explicit `tj rm`, entry names, tags, and pins do not settle retention. Pins
protect entries and journals from ordinary explicit removal unless `--force`
is used, but promise nothing about a future automatic policy. Generated
`YYMMDD-RANDOM` names are mutable identities rather than timestamps: retention
must use authoritative metadata and must not parse age from a journal name.
Any retention design must decide its relationship to pins separately.

What is wanted instead is deliberate: something like `tjctl prune --older-than
30d`, or a size cap, or both.

---

## Smaller notes

- `tj.plugin.zsh` can fork `base64` three times per command in `preexec`, for
  `cmd`, `cwd`, and `expanded`. Encoding is needed so semicolons and newlines
  cannot break the sequence framing. Find a way to preserve that framing
  without several subprocesses on every interactive command.
- Arbitrary-command shorthand completion does not offer journal selectors:
  `@rel<TAB>` produces nothing. Static `tjctl` journal operands complete
  canonical names, and qualified references resolve exact names or
  unique suffixes, but global cross-journal shorthand remains a possible
  future enhancement.
- `tj resolve @1` inside a journal writer needs quoting (`tj resolve '@1'`).
  The accept-line widget canonicalizes the shorthand as `~[@1]`, then zsh's
  dynamic named-directory expansion supplies a path before tj sees it.
  `tj cat` sidesteps this by accepting either references or paths.
