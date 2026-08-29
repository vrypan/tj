# Embedded SQLite

TJ vendors the official SQLite 3.53.4 amalgamation and compiles it directly
into the `tj` executable. It does not use a system SQLite library or the
`sqlite3` command-line program.

- Upstream: <https://sqlite.org/download.html>
- Artifact: `sqlite-amalgamation-3530400.zip`
- Published SHA3-256:
  `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`
- Vendored files: unmodified `sqlite3.c` and `sqlite3.h`

The build enables SQLite's normal thread-safe mode and disables loadable
extensions and double-quoted string literals. When updating SQLite, replace
both generated files together, update the artifact and checksum above, update
the version assertion in `src/sqlite.zig`, and run the native and six-target
release gates.
