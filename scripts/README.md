# Scripts

Runtime helpers for the `git-conflict-resolver` skill.

| Script | Purpose |
|---|---|
| `conflict-status.sh` | Detect active git conflict operation and unmerged count |
| `categorize-conflicts.sh` | Classify unmerged paths by deterministic handling category |
| `validate-resolution.sh` | Check for conflict markers, whitespace issues, and optional project checks |
| `detect-stacked-pr.sh` | Detect empty-base/high-similarity stacked-PR duplicate conflicts |
| `semantic-audit.sh` | Heuristically flag post-resolution semantic-conflict suspects |
| `suggest-pr-split.sh` | Propose functional/structural split groups for a large range or conflict (`--scope unmerged\|incoming-range\|both`) |
| `open-stacked-prs.sh` | Materialize a split plan as stacked GitHub PRs (dry-run by default; `--execute --remote <name>` requires `gh`) |

Run all tests from the repository root:

```bash
make test
```
