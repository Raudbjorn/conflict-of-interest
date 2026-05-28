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

1. **Refactor isolation first, when clean** — pure renames/moves/reformatting go
   into a dedicated *preliminary* PR (high-similarity renames, `R90`+). This
   removes the `structural` conflict class and gives behavior PRs a clean
   baseline. If the same files also carry behavior changes, downgrade confidence:
   rebasing the behavior PR onto the refactor can reintroduce conflicts.
2. **Dependency topology** — land lower layers first so each PR compiles:
   contracts/schema/migration → shared infrastructure → implementation →
   consumers/UI → cleanup. Keep generated output with its source spec and tests
   with the implementation they validate.
3. **Functional vertical slices** — when a feature has independent subfeatures,
   split by user-visible capability rather than by arbitrary directory count.
4. **Ownership and co-change** — package/module ownership, CODEOWNERS, and
   historical co-change are supporting signals; they do not override dependency
   direction.
5. **Iterative compiling milestones** — every split must leave the tree
   buildable/typecheckable on its own. A split that breaks a milestone is worse
   than one large PR.

## What `suggest-pr-split.sh` decides vs. defers

`${CLAUDE_SKILL_DIR}/scripts/suggest-pr-split.sh` proposes groups deterministically
from pure git/bash signals. It does **not** build an import graph, so its
boundaries are structural, not semantic.

| Signal | Deterministic | Defers to human |
|---|---|---|
| top-level module cluster | grouping key | true cross-module coupling |
| layer classification (migration/lockfile/generated/test/ui/config/docs/source) | path globs | mixed-layer single module |
| rename isolation (`R`-score) | `R>=threshold` → confident move | `R<threshold` → move + edit |
| active conflict scopes | `--scope unmerged`, `incoming-range`, or `both` | whether the full source branch is semantically splittable |

Confidence: `high` (single layer in a module), `medium` (two layers), `low`
(three+ layers in one module, or a sub-threshold rename). **Low-confidence /
cross-cutting groups are starting points, not guarantees** — verify dependencies
before splitting them, or keep the change whole. Abstaining beats a wrong split.

```bash
# analyze a PR/branch before any local conflict
${CLAUDE_SKILL_DIR}/scripts/suggest-pr-split.sh --base origin/main --head HEAD --json
# analyze the current oversized conflict
${CLAUDE_SKILL_DIR}/scripts/suggest-pr-split.sh --conflicts --scope both
```

## Git surgery recipes

```bash
# inspect a candidate group
git diff --stat <base>...<head> -- <paths>

# carve a path subset onto a fresh branch
git switch -c <branch> <base>
git restore --source=<head> --staged --worktree -- <paths>
git commit -m "<split title>"

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

Execution requires an explicit remote:

```bash
${CLAUDE_SKILL_DIR}/scripts/open-stacked-prs.sh --base main --head HEAD \
  --remote origin --execute --group "split/schema:db/migrate/001.sql"
```

The script synthesizes commits from path groups. It does not preserve the
original commit topology unless the user already supplied commit-aligned groups.
It refuses dirty trees, protected/default starting branches, missing `gh` auth,
and pre-existing local/remote branch names.

Retarget as parents merge: `gh pr edit <n> --base main`. Graphite and git-town
automate this retargeting if you prefer an external tool.

## Host notes

| Host | Notes |
|---|---|
| GitHub | No native dependency enforcement; base-branch changes can make review comments outdated. Use a draft tracking PR or PR description checklist for stack state. |
| GitLab | Premium/Ultimate support merge-request dependencies; `glab` can cover the CLI workflow. |
| Bitbucket | Treat as mostly manual stack management; document parent/child order explicitly. |

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

## Anti-patterns

- Formatting/refactors mixed with behavior changes.
- Hand-resolved lockfiles; regenerate from manifests instead.
- Generated output split away from the schema/spec that produces it.
- Tests split away from the implementation they validate.
- Dropping old APIs or columns before all consumers are migrated.
- Squash-merging a parent stack PR without rebasing/retargeting children.
- Splitting so small that no reviewer can understand the behavior in isolation.
