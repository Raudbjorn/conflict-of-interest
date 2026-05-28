# Design Rationale

This reference explains why the skill is cautious and layered.

## Three-layer model

| Layer | Mechanism | Purpose |
|---|---|---|
| 1 | `mergiraf` merge driver | remove false textual conflicts with syntax-aware merge |
| 2 | file categorization | handle mechanical cases safely |
| 3 | intent inference and validation | resolve or halt on semantic ambiguity |

No single layer is enough. Structural merge does not understand lockfiles or
domain semantics. LLM analysis is not reliable enough to replace deterministic
classification.

## Empirical posture

Merge-Bench reports frontier-model code-normalized accuracy below 60% on real
merge conflicts. Abstaining with conflict markers is safer than producing a
wrong merge. AgenticFlict reports high conflict rates in AI-generated PRs, so
this workflow optimizes for repeated use rather than rare emergencies.

## Line-combination heuristic

Most correct resolutions are combinations of existing lines. For balanced
conflicts, prefer line-combination reasoning and lower confidence. For highly
imbalanced conflicts, LLM synthesis can be more useful.

## Stacked PRs

An empty diff3 base plus high similarity between sides often means duplicated
stacked-PR content. The 95%/70% thresholds are heuristics, not empirical laws,
and `detect-stacked-pr.sh` makes them testable and tunable.

