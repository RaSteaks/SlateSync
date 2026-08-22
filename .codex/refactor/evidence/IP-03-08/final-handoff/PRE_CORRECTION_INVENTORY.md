# C01 resumed-repair pre-correction inventory

Captured: 2026-08-21 (Asia/Shanghai), immediately before adding the root
instruction files, Completion Report, final authority state, and final-handoff
evidence for the resumed C01 repair.

## Repository identity

- HEAD: `c7dafa4d972e5eb7be61f00e2b546d6826e70c87`
- Branch: `codex/react-architecture-refactor`
- Active package: `IP-03-08-CONTINUOUS`, version `2026-08-21.2`
- Active package SHA-256: `67a4d98e90950a78a04e4ab2b5a6b6a164408567dee83f6d211b2b4e54a2c164`
- State before correction: `IP-03-08_READY_FOR_CONTINUOUS_IMPLEMENTATION`
- Gate: `GATE-01-02 APPROVED`
- Git mutation policy: no stage, commit, push, reset, clean, or branch switch.

## Exact worktree inventory commands

The following read-only commands were run at capture time. Their counts and
content hashes preserve the inherited dirty worktree without collapsing it
into a clean-tree claim:

```text
git diff --name-only                         14 paths
git ls-files --others --exclude-standard    516 files
git status --porcelain=v2                  53 records
deleted tracked paths                       0
git status --porcelain=v2 SHA-256           f21b1c06c43e880158badc604737c75c2c8fda16b99b8e5299ed1f7b25719f45
git ls-files --others --exclude-standard SHA-256
                                               388d69156f8e991a2cc264d8c8fe7c67a56f86d6784d57e287c556f4aacd888f
git diff --name-only SHA-256                0b70fc3c22e77269c0a944a21db090074934e6096feefce46df754673ed6fc88
git diff --check                            exit 0
```

The 14 already-modified tracked paths are:

```text
.codex/refactor/ARCHITECTURE_INVARIANTS.md
.codex/refactor/EXECUTION_GUIDE.md
.codex/refactor/MASTER_PLAN.md
.github/workflows/ci.yml
.github/workflows/release.yml
README.md
electron-builder.yml
electron/main.mjs
electron/preload.cjs
package-lock.json
package.json
public/csv-worker.js
public/electron-bridge.js
test/electron-bridge.test.mjs
```

The inherited untracked set contains the continuous refactor source, tests,
fixtures, authority/evidence records, generated Storybook/test outputs, and
the existing visual evidence. It was not cleaned, reset, or overwritten.

## Correction boundary

Before this inventory, the only C01 repair additions were the prior Stop
Condition record and its diagnostic evidence. This inventory is the baseline
for the resumed repair; the post-correction inventory must show only the
explicit C01 handoff files, authority documents, and generated outputs added
after this point.
