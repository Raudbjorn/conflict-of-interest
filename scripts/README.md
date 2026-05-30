# Scripts

Runtime helpers for the `git-conflict-resolver` skill.

| Script | Purpose |
|---|---|
| `conflict-status.sh` | Detect active git conflict operation and unmerged count |
| `categorize-conflicts.sh` | Classify unmerged paths by deterministic handling category |
| `validate-resolution.sh` | Check for conflict markers, whitespace issues, and optional project checks |
| `detect-stacked-pr.sh` | Detect empty-base/high-similarity stacked-PR duplicate conflicts |
| `historical-resolution-search.sh` | Retrieve similar real historical conflict resolutions from local merge history |
| `semantic-audit.sh` | Heuristically flag post-resolution semantic-conflict suspects |
| `suggest-pr-split.sh` | Propose functional/structural split groups for a large range or conflict (`--scope unmerged\|incoming-range\|both`) |
| `open-stacked-prs.sh` | Materialize a split plan as stacked GitHub PRs (dry-run by default; `--execute --remote <name>` requires `gh`) |
| `meta-route.sh` | Per-file deterministic router over category, balance, stacked-PR, and (optional) history signals; emits JSON/TSV audit trail for `SKILL.md` Step 3i |
| `sbse-recombine.sh` | Bounded line-combination candidate generator for balanced `other` conflicts (7 deterministic strategies, ranked by Jaccard to both parents) |
| `prompt-context.sh` | Hard-capped Rover-style cross-file context bundle (BFS over `git grep -w` from extracted symbols, k=4 / 48-hit / 12 KB budget) |
| `validate-and-reprompt.sh` | Bounded debug-prompt loop wrapper around `validate-resolution.sh`; emits `reprompt.md` artifact on failure, never calls an LLM |
| `lib/jaccard.sh` | Shared whitespace-normalised line-set Jaccard similarity helper (sourced by `detect-stacked-pr.sh` and `sbse-recombine.sh`) |

Run all tests from the repository root:

```bash
make test
```

`historical-resolution-search.sh` returns `0` when matches are found, `2` when
history has no usable signal, `10` for bad arguments, `11` outside a git
repository, and `12` when required commands or Git features are unavailable.
