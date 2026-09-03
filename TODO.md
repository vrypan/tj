# TODO

Things deliberately left undone, with enough context to pick up cold.

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

- Arbitrary-command shorthand completion does not offer journal selectors:
  `@rel<TAB>` produces nothing. Static `tjctl` journal operands complete
  canonical names, and qualified references resolve exact names or
  unique suffixes, but global cross-journal shorthand remains a possible
  future enhancement.
