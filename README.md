# git-conflict-resolver

Claude skill for resolving Git conflicts with a layered workflow:

1. Structural merge support through `mergiraf`.
2. Deterministic file categorization for mechanical cases.
3. Explicit intent inference, validation, and semantic-conflict audit for the hard cases.

This repository root is the skill root. Install locally with:

```bash
make install
```

Run tests with:

```bash
make test
```

The implementation intentionally halts on ambiguous intent. Merge conflict
resolution is destructive; an unresolved conflict is cheaper than silent code
loss.

## What's included

| Area | Files |
|---|---|
| Skill procedure | `SKILL.md`, `constitution.md` |
| Strategy references | `references/*.md` |
| Runtime helpers | `scripts/conflict-status.sh`, `scripts/categorize-conflicts.sh`, `scripts/validate-resolution.sh`, `scripts/detect-stacked-pr.sh`, `scripts/semantic-audit.sh`, `scripts/suggest-pr-split.sh`, `scripts/open-stacked-prs.sh` |
| Research handoff | `docs/research-synthesis.md`, `docs/SOURCES.md`, `docs/implementation-notes.md` |

The helpers classify lockfiles, migrations, submodules, binary files,
generated files, snapshots, notebooks, mergiraf-supported files, and remaining
`other` files. High-risk categories route to explicit HALT paths.

For an oversized PR or conflict, the skill also proposes a decomposition into
smaller PRs along functional/structural boundaries (`suggest-pr-split.sh`) and can
open the resulting stacked PRs on GitHub (`open-stacked-prs.sh`, dry-run by
default, requires `gh`). See `references/pr-decomposition.md`.

## Packaging

```bash
make package
```

This creates `git-conflict-resolver.tar.gz` with the skill files, references,
docs, scripts, tests, license, and notice.
