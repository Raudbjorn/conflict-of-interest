# PR Decomposition

How to split a very large change or conflict (thousands of lines, hundreds of
files) into smaller PRs along functional and structural boundaries.

## The heuristic is sound

Splitting "along boundaries of similar functionality and related code" is the
validated approach to dismantling the "Everything PR" antipattern. Functional
boundaries are feature/module seams; structural boundaries are layers (schema,
logic, UI) and pure refactors. This is preventative, not a merge mechanic: it
reduces the conflict surface rather than resolving an existing wall of markers.

## When to decompose

| Situation | Action |
|---|---|
| Conflict fits the Step 3 flow (under the ~300-line / 20-file gates) | Resolve in place |
| The change itself is too large to review, or a conflict is large because two big features overlap | Decompose into smaller PRs |
| A single large branch must land as-is and the blocker is pairwise sequencing | `git-imerge` (see `${CLAUDE_SKILL_DIR}/references/recurring-conflicts.md`) |

Decomposition and `git-imerge` are not substitutes: one restructures the change,
the other incrementally merges an unsplittable one.

## Boundary heuristics

1. **Horizontal layer separation** — land lower layers first so each PR compiles:
   schema/migration → business logic → UI/assets. (This mirrors the skill's
   instinct to resolve a source spec before its generated output.)
2. **Refactor isolation** — pure renames/moves/reformatting go into a dedicated
   *preliminary* PR (high-similarity renames, `R90`+). This removes the
   `structural` conflict class and gives the behavior PRs a clean baseline. It is
   the highest-leverage split.
3. **Iterative compiling milestones** — every split must leave the tree
   buildable/typecheckable on its own. A split that breaks a milestone is worse
   than one large PR.

## What `suggest-pr-split.sh` decides vs. defers

`${CLAUDE_SKILL_DIR}/scripts/suggest-pr-split.sh` proposes groups deterministically
from pure git/bash signals. It does **not** build an import graph, so its
boundaries are structural, not semantic.

| Signal | Deterministic | Defers to human |
|---|---|---|
| top-level module cluster | grouping key | true cross-module coupling |
| layer classification (migration/lockfile/generated/test/ui/config/source) | path globs | mixed-layer single module |
| rename isolation (`R`-score) | `R>=threshold` → confident move | `R<threshold` → move + edit |

Confidence: `high` (single layer in a module), `medium` (two layers), `low`
(three+ layers in one module, or a sub-threshold rename). **Low-confidence /
cross-cutting groups are starting points, not guarantees** — verify dependencies
before splitting them, or keep the change whole. Abstaining beats a wrong split.

```bash
# analyze a PR/branch before any local conflict
${CLAUDE_SKILL_DIR}/scripts/suggest-pr-split.sh --base origin/main --head HEAD --json
# analyze the current oversized conflict
${CLAUDE_SKILL_DIR}/scripts/suggest-pr-split.sh --conflicts
```

## Git surgery recipes

```bash
# inspect a candidate group
git diff --stat <base>...<head> -- <paths>

# carve a path subset onto a fresh branch (parallel, independent PRs)
git checkout -b <branch> <base>
git checkout <head> -- <paths>

# lift specific commits instead of paths
git cherry-pick <sha>...

# retarget a dependent branch after its parent merges
git rebase --onto <new-base> <old-base> <branch>
```

## Stacked-PR topology (dependent splits)

When splits depend on each other, stack them: branch 1 off the trunk base, branch
2 off branch 1, and so on. Each PR targets its parent branch, not the trunk. As a
parent merges, retarget the child to the trunk.

`${CLAUDE_SKILL_DIR}/scripts/open-stacked-prs.sh` materializes a plan. It is
**outward-facing and dry-run by default** — it prints the `git`/`gh` command plan
and applies nothing until `--execute`. Obtain explicit user confirmation and show
the dry-run plan first.

```bash
# dry-run a stack (prints the plan only)
${CLAUDE_SKILL_DIR}/scripts/open-stacked-prs.sh --base main --head HEAD \
  --group "split/schema:db/migrate/001.sql" \
  --group "split/logic:src/billing/charge.ts"

# or feed suggest-pr-split.sh output directly
${CLAUDE_SKILL_DIR}/scripts/suggest-pr-split.sh --base main --head HEAD --json \
  | ${CLAUDE_SKILL_DIR}/scripts/open-stacked-prs.sh --base main --from-json
```

Retarget as parents merge: `gh pr edit <n> --base main`. Graphite and git-town
automate this retargeting if you prefer an external tool.

## Governance thresholds (tunable heuristics, not laws)

- PRs over ~400 LOC sharply raise overlap/conflict risk.
- Conflict probability roughly triples past ~25 lines of churn (AgenticFlict).

These are configurable (`--large-loc`), not empirical constants. Treat them as
prompts to consider splitting, not hard cutoffs.

## Structural, not concatenative

About 87% of correct merge resolutions are pure combinations of existing lines —
but only when they preserve partial order (AST set-union, as `mergiraf` does), not
blind text concatenation. This *validates the skill's mergiraf-first stance*
(Step 3h, `${CLAUDE_SKILL_DIR}/references/design-rationale.md`): when a decomposed
PR is later re-merged, prefer structural merge over hand-concatenation.

## Dependency analysis tools

For entangled changes where clean seams are unclear, `git-deps` (commit-level
dependency graph) and Viezly (visual PR decomposition) help locate independent
clusters. They are external and optional; `suggest-pr-split.sh` covers the
high-confidence structural cases without them.
