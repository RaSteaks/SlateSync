# IP-00 Worktree Protection Record

CLASSIFICATION: **FROZEN HISTORICAL BASELINE EVIDENCE — NOT AN EXECUTION
INSTRUCTION**. Current phase/package authority is indexed by
`.codex/refactor/README.md` and `CURRENT_STATE.json`.

Captured before IP-00 implementation on baseline commit `c7dafa4d972e5eb7be61f00e2b546d6826e70c87`.

## Git state

```text
# branch.oid c7dafa4d972e5eb7be61f00e2b546d6826e70c87
# branch.head codex/react-architecture-refactor
# branch.upstream origin/codex/react-architecture-refactor
# branch.ab +0 -0
? .codex/refactor/packages/
```

The package was originally inspected on `codex/electron-only`; an external checkout moved the worktree to `codex/react-architecture-refactor`. Both refs point to the same commit, and no source content changed. The Implementer must remain on `codex/react-architecture-refactor` and must not switch branches.

## Change classification

- Pre-existing tracked changes: none.
- Pre-existing staged changes: none.
- Pre-existing user untracked changes: none observed.
- Known architect artifact: `.codex/refactor/packages/IP-00.md`.
- Tracked build inputs include `build/**` (including the repository's tracked `build/.DS_Store` files), `build/slatesync.icon/**`, and `build/entitlements.mac.plist`.
- Ignored/generated inputs observed: `node_modules/`, `dist/`, `bin/`, and `public/vendor/`.
- No file was reset, checked out, cleaned, overwritten, staged, committed, or stashed while preparing this record.

## Implementer protocol

1. Capture `git status --porcelain=v2 --branch` before the first edit.
2. Treat every path not listed in IP-00 Allowed Scope as protected, including changes that appear after a concurrent checkout or external process.
3. Never use `git reset`, `git checkout`, `git clean`, blanket formatters, or dependency installation/update to make the worktree appear clean.
4. If an unexpected change overlaps a protected file, stop and append a Decision Queue entry. Preserve the path exactly; do not copy it into a fixture.
5. At completion, compare tracked protected files and the complete status against the preflight capture. Only IP-00 Allowed Scope paths may differ.
