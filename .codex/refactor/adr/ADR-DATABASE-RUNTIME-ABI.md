# ADR: Database driver and Node/Electron native ABI lifecycle

Status: accepted for IP-03-08 continuous implementation  
Date: 2026-08-21

Authority context: current supporting decision for
`IP-03-08-CONTINUOUS` version `2026-08-21.2`; see `../README.md` and
`../CURRENT_STATE.json`.

## Context

SlateSync is an Electron-only desktop application. SQLite, Project Library,
task, diagnostic, and scenario persistence are owned by Main and currently use
`better-sqlite3`. The system Node process runs repository tests while Electron
loads the packaged application. Native addon ABI numbers identify those
runtimes; they do not imply that a Node Web server still exists.

On the current development machine the observed Node and Electron ABIs are 137
and 148. A native `.node` binary built for one cannot be loaded by the other.
The numbers are runtime/version facts, not stable application constants, so
scripts and tests must read the active runtime rather than hard-code them.

The persistence contract is already broad and safety-sensitive: existing
`library.sqlite`, `project.sqlite`, and legacy `slatesync.sqlite` files; WAL,
foreign keys, busy timeout, transactions, backup/import/export, copied
version-1 migration, private file modes, JSON compatibility snapshots, and
unchanged user-data paths must all remain valid.

## Decision

Keep `better-sqlite3` for the IP-03-08 refactor. Do not mix a database-driver
migration into the Renderer/ownership/UI migration.

Use explicit, automated runtime preparation:

- `rebuild:native:node` prepares the system Node test runner.
- `rebuild:native:electron` prepares Electron development and packaging.
- `test:native:abi` rebuilds and probes Electron without a GUI, restores the
  Node binding in `finally`, and probes Node afterward.
- Node tests, Electron development/smoke, package builds, CI, and release
  validation call the appropriate named lifecycle; developers do not manually
  copy native binaries or infer ABI compatibility from a successful install.
- Electron/package controllers that temporarily switch the shared
  `node_modules` binding continue to restore Node in an outer `finally`.

The continuous package may exercise and strengthen this lifecycle but may not
replace the driver, introduce a database abstraction, or change schema/data
semantics. A driver change requires a separate post-refactor package and ADR.

## Alternatives considered

### `sqlite3`, Knex, or another wrapper

Rejected. `sqlite3` is also a native addon and therefore does not remove the
runtime rebuild problem. Knex is a query builder rather than a SQLite runtime;
placing it over a native driver adds an abstraction without eliminating ABI
ownership and would require rewriting synchronous transaction-heavy code.

### SQLite WASM / OPFS

Rejected for this desktop Main-owned database. OPFS is browser/Worker storage,
has different file visibility and locking behavior, and WAL requires special
exclusive-lock handling without its usual concurrency benefit. Moving the
authoritative Project Library there would change ownership, paths, backup,
import/export, recovery, concurrency, and package behavior.

### `node:sqlite`

Promising future candidate, but deferred. It removes the third-party native
addon because SQLite ships with each Node runtime and offers a synchronous API.
However, it entered Node in 22.5.0 and remains release-candidate stability in
current upstream documentation. SlateSync supports Node 22 in CI while
Electron embeds a separately versioned Node/SQLite build, and the current
storage modules depend on `better-sqlite3` statement, transaction, pragma, and
backup behavior. An immediate substitution would require a complete API,
SQLite-version, transaction, error, backup, migration, performance, and
cross-runtime compatibility study.

## Post-refactor evaluation gate

A future `node:sqlite` spike may proceed only in an isolated package with no
production cutover until all of the following pass against copied data:

1. supported system Node and Electron versions both expose the required API;
2. every current SQL statement and transaction has differential parity;
3. WAL/foreign-key/busy-timeout and error/locking behavior match;
4. Library export/import and SQLite backup remain atomic and compatible;
5. version-1 and legacy migrations leave their source unchanged;
6. full persistence, concurrency, crash-recovery, package, and performance
   suites meet or improve the frozen baseline;
7. the migration removes `better-sqlite3` and native rebuild scripts without
   adding a temporary dual-driver abstraction.

## Consequences

- ABI switching remains an implementation detail of development and CI, but
  is deterministic, self-restoring, and independently testable.
- Existing databases and Main ownership remain untouched during IP-03-08.
- The project avoids exchanging a small build-time cost for a high-risk data
  migration during the largest application refactor.
- `node:sqlite` remains a documented optimization candidate rather than
  untracked technical debt.

## References

- Electron, “Native Node Modules”:
  <https://www.electronjs.org/docs/latest/tutorial/using-native-node-modules>
- better-sqlite3 troubleshooting:
  <https://github.com/WiseLibs/better-sqlite3/blob/master/docs/troubleshooting.md>
- Node.js `node:sqlite` API:
  <https://nodejs.org/api/sqlite.html>
- SQLite WASM persistent storage:
  <https://sqlite.org/wasm/doc/tip/persistence.md>
