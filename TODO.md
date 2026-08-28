# TODO

Things deliberately left undone, with enough context to pick up cold.

---

## Tell the user when a journal recorded nothing

`tj new` without `tj.plugin.zsh` sourced runs fine and records nothing, and
nothing says so. `tj hist` prints zero bytes and exits 0, which is
indistinguishable from a broken journal, a wrong `$TJ_HOME`, or the feature
not working at all. This has already cost one debugging journal.

Zero interactions is a reliable signal: with the plugin loaded, even typing
`exit` produces one. So the proxy knows for certain at exit, and `tj hist`
knows whenever it is asked.

- Where: `proxy.run`, which already has the store at close time and may remove
  a newly created journal when it is empty (`Store.close`); continued journals
  are always preserved. Also update `commands.listInteractions`.
- Suggested wording: `tj: nothing was recorded - is tj.plugin.zsh sourced in
  your ~/.zshrc?`
- Send it to stderr so `tj hist` stays clean in a pipe.
- Once per journal at most. This must not become something that prints on
  every prompt.

## Log a warning when a boundary arrives without a command line

`SPEC.md` §6 says a `133;C` with no preceding `cmd` sequence "still opens an
interaction (empty `cmd`, warning logged)". The interaction opens, but
nothing is logged.

Verified: a zsh emitting only OSC 133 - somebody else's shell integration,
with no tj plugin - records interactions with `cmd` empty and no `log` file
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

Journals persist indefinitely. `TJ-spec.md` lists retention and redaction as
an open question and it still is. The journal holds whatever appeared on the
terminal, including secrets, and grows without bound.

Decided so far: exit is **not** the retention boundary. Deleting a journal
when its terminal closes would break `@SUFFIX.N`, which is defined to resolve
after a writer has ended, and would throw away exactly the recordings worth
keeping. Only journals newly created by an empty `tj new` may be removed at
writer exit; `tj continue` never deletes its existing journal.

Explicit `tj rm`, interaction names, tags, and pins do not settle retention.
In particular, a pin is currently only a user annotation: it neither protects
an interaction from explicit deletion nor promises that a future policy will
keep it. Any retention design must make that relationship as a separate
product decision.

What is wanted instead is deliberate: something like `tj prune --older-than
30d`, or a size cap, or both.

### A reserved gutter for the reference number

Considered and not done. The idea was to reserve the first four columns of
the terminal and print `@42` beside each command.

It is possible: Ghostty implements DECSLRM behind mode 69, so the left margin
could be set once and the label written at each command boundary, and the
alternate-screen filter already knows when to get out of the way for a
full-screen program.

The cost is that tj stops being transparent. Programs would get four fewer
columns and their absolute cursor addressing would land elsewhere, tj would
have to watch the outgoing stream for the sequences that reset margins - on
the hot path, where the byte-loss and typeahead bugs came from - and it only
works on terminals that support DECSLRM, which `xterm-ghostty`'s terminfo
does not advertise.

`$TJ_REF` in the prompt gets most of the value for none of that, and is what
is implemented. Revisit only if it turns out not to be enough.

---

## Smaller notes


- `test "signals sent to tj are forwarded to the shell"` is timing
  dependent and fails occasionally under load: it waits for the shell to
  print `READY` before sending the signal, and can time out before that
  arrives. Passed 3/3 on a re-run. Worth making it wait properly rather
  than on a deadline.

- `tj.plugin.zsh` forks `base64` once per command, in `preexec`. A few
  milliseconds on every interactive command. Encoding is needed so that
  semicolons and newlines in a command line cannot break the sequence
  framing, and zsh has no builtin for it, but it could be done with
  parameter expansion instead.
- `tj hist` has no machine-readable form. Not needed while an agent reads it
  through the skill - a model parses the table fine, and JSON measured 2.1x
  the size. It would matter if a wrapper script ever builds prompts.
- Completion does not offer journal suffixes: `@pg<TAB>` produces nothing.
  `SPEC.md` §8.3 does not ask for it, and full ULIDs make poor candidates,
  but it is a gap when working across journals.
- `tj resolve @1` inside a journal writer needs quoting (`tj resolve '@1'`).
  The accept-line widget canonicalizes the shorthand as `~[@1]`, then zsh's
  dynamic named-directory expansion supplies a path before tj sees it.
  `tj cat` sidesteps this by accepting either references or paths.
- Programs that repaint without the alternate screen - a progress meter,
  `top --no-altscreen` - are recorded in full. Only real terminal emulation
  could reduce those to a final state. `tj cat` resolves the common
  carriage-return case at read time instead.
