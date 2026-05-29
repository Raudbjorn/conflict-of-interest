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

Run all tests from the repository root:

```bash
make test
```

`historical-resolution-search.sh` returns `0` when matches are found, `2` when
history has no usable signal, `10` for bad arguments, `11` outside a git
repository, and `12` when required commands or Git features are unavailable.
