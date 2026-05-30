# git-conflict-resolver

Claude skill for resolving Git conflicts with a layered workflow:

1. Structural merge support through `mergiraf`.
2. Deterministic file categorization for mechanical cases.
3. Explicit intent inference, historical-resolution evidence, validation, and
   semantic-conflict audit for the hard cases.

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
| Runtime helpers | `scripts/conflict-status.sh`, `scripts/categorize-conflicts.sh`, `scripts/validate-resolution.sh`, `scripts/detect-stacked-pr.sh`, `scripts/historical-resolution-search.sh`, `scripts/semantic-audit.sh`, `scripts/suggest-pr-split.sh`, `scripts/open-stacked-prs.sh`, `scripts/meta-route.sh`, `scripts/sbse-recombine.sh`, `scripts/prompt-context.sh`, `scripts/validate-and-reprompt.sh` |
| Research handoff | `docs/research-synthesis.md`, `docs/SOURCES.md`, `docs/implementation-notes.md` |

The helpers classify lockfiles, migrations, submodules, binary files,
generated files, snapshots, notebooks, mergiraf-supported files, and remaining
`other` files. High-risk categories route to explicit HALT paths.

For ambiguous human-authored source/config conflicts, the skill can mine local
merge history for similar real conflict resolutions. These examples are advisory
evidence only; they are never auto-applied.

For an oversized PR or conflict, the skill also proposes a decomposition into
smaller PRs along functional/structural boundaries (`suggest-pr-split.sh`) and can
open the resulting stacked PRs on GitHub (`open-stacked-prs.sh`, dry-run by
default, requires explicit `--execute --remote <name>` and `gh`). See
`references/pr-decomposition.md`.

Inside Step 3i the skill's prose routing is also recorded as a deterministic
audit trail by `meta-route.sh`, with three companion helpers for the cases the
prose names: `sbse-recombine.sh` (the 87% line-combination heuristic),
`prompt-context.sh` (Rover-style cross-file context, capped at `k=4`), and
`validate-and-reprompt.sh` (LLMinus-style debug-prompt artifact loop around
`validate-resolution.sh`). See `references/meta-resolver.md`.

## Packaging

```bash
make package
```

This creates `git-conflict-resolver.tar.gz` with the skill files, references,
docs, scripts, tests, license, and notice.
