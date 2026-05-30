# Meta-Resolver

Why the skill has a deterministic routing layer over the prose Step 3i, what
goes into it, and what stays out.

## Why a router, not a rewrite

`SKILL.md` Step 3i has long encoded the routing decision in prose: "if one side
is more than 3x longer, LLM; if balanced, line-combination reasoning; if too
large, decompose; …". That works, but it is untestable: there is no artefact a
reviewer can audit, no fixture set, and no way to detect regressions in the
heuristic. `scripts/meta-route.sh` consumes the same signals the prose already
uses (`categorize-conflicts.sh`, balance metrics, `detect-stacked-pr.sh`,
optionally `historical-resolution-search.sh`) and emits one structured record
per file. The prose steps 1–9 are unchanged; the router augments and audits
them, it does not displace judgment.

The record names the strategy explicitly so the agent's downstream actions can
be reviewed by a human or by `make test` golden corpora.

## Inputs

Four signal sources, in order of cost:

| Signal | Source | Cost |
|---|---|---|
| Category | `scripts/categorize-conflicts.sh` (path globs + git index probes) | one call per repo |
| Balance / `has_base` / `empty_side` | inline parse of the worktree file's conflict markers | linear in file size |
| Stacked-PR aggregate (`AUTO_HEAD` / `ASK` / `MIXED`) | `scripts/detect-stacked-pr.sh --file <p> --json` | one call per file |
| Historical top score (optional) | `scripts/historical-resolution-search.sh --file <p> --top 3 --json` (only with `--history-search`) | bounded by `--max-merges` (default 200) |

Mechanical-category files (lockfile, migration, submodule, binary, generated,
snapshot, notebook, mergiraf) short-circuit at the first signal — no further
calls happen, ever.

## Routes

| # | Precondition | Route | Citation |
|---|---|---|---|
| 1 | category ∈ mechanical-set | `mechanical` | category invariants |
| 2 | category = other ∧ stacked aggregate = `AUTO_HEAD` | `stacked-auto` | H-06 |
| 3 | category = other ∧ stacked aggregate has `ASK` | `llm-imbalanced` (with stacked context) | H-06 |
| 4 | category = other ∧ `total_lines > large-threshold` | `halt-decomposition` | H-11 |
| 5 | category = other ∧ one side empty | `llm-imbalanced` (`modify-delete`) | Step 3i.2 |
| 6 | category = other ∧ `max/min ≥ imbalance-threshold` | `llm-imbalanced` (`ratio=…`) | H-02 |
| 7 | category = other ∧ history top score ≥ history-threshold | `llm-with-history` | H-05 |
| 8 | category = other ∧ `has_base` (balanced with diff3 base) | `sbse-recombine` | H-02 |
| 9 | category = other ∧ no diff3 base | `llm-imbalanced` (`no_diff3=true`, low confidence) | H-06 |
| 10 | catch-all (sub-call errors, unreadable worktree, etc.) | `halt-other` | fail-safe invariant |

First match wins; the router never silently downgrades. The catch-all is a
deliberate fail-stop — if any sub-signal script errors, the file routes to
`halt-other` with `reason=subcall_failed=…`.

## Routing-table invariants

Every row above cites either an `H-NN` heuristic in
`docs/research-synthesis.md` or a deliberate Step 3i sub-step. Adding a new row
requires the same: cite an `H-NN` entry and an `I-NN` risk-register entry.
This forces evidence before mechanism and keeps the table from accreting
folk-routes.

The router itself is one file with one table; if a route needs more nuance,
that nuance belongs in the downstream script (`sbse-recombine.sh`,
`prompt-context.sh`, `validate-and-reprompt.sh`), not in the router.

## Honest trade-off

Formalising routing in code makes it testable but moves judgment further from
the reading order of `SKILL.md`. The mitigation is structural: the prose Step
3i.1–9 stays, and the router is invoked at a new Step 3i.0 that records its
verdict into the per-file Decision Record. A reviewer can compare the prose
intent against the router verdict and call out drift. If the two disagree
often, that is a signal that the heuristic itself needs updating — not that
either side should "win" by default.

## Non-goals

- No machine learning, no LLM calls, no network, no embeddings.
- No auto-application of any route. Every "auto" route in the table is advisory.
  `stacked-auto` for example is permission to *consider* taking the left side;
  the agent's Step 3i.9 still names the action.
- No cross-file routing. The router decides one file at a time. Cross-file
  coupling is a future concern, deferred to a Python v2.
- No retry / queue / state between invocations. The router is a pure function
  of the current worktree.

## Failure modes

| Failure | Behaviour |
|---|---|
| `categorize-conflicts.sh` errors | exit 12 (`categorize-conflicts.sh failed`); routing halted |
| `detect-stacked-pr.sh` errors on a file | stacked signal treated as absent; routing continues |
| `historical-resolution-search.sh` errors with `--history-search` | history score treated as `null`; route falls through |
| worktree file unreadable | route = `halt-other`, reason = `subcall_failed=worktree_unreadable` |
| no unmerged files / no `--file` | exit 2 with `[]`/empty TSV |

The invariant is fail-conservative: when a sub-signal cannot be trusted, route
to a HALT lane rather than silently downgrading confidence.

## References

- `H-02` — 87% of real resolutions are line combinations
- `H-03` — Rover MtCPG at `k=4` is optimal; deeper context degrades
- `H-05` — LLMinus historical-resolution RAG
- `H-06` — diff3 base as a stacked-PR signal
- `H-11` — PR decomposition before conflict resolution
- `I-26` — Step 3i prose routing is untestable (router mitigation)
- `I-27` — Balanced `other` misses the 87% line-combination heuristic
  (`sbse-recombine.sh` mitigation)
- `I-28` — Freeform cross-file exploration exceeds the Rover `k=4` budget
  (`prompt-context.sh` mitigation)
- `I-29` — `validate-resolution.sh` exit 3/4 lacks structured reprompt context
  (`validate-and-reprompt.sh` mitigation)
