# Changelog

## Unreleased

- Initial fresh repository for the improved `git-conflict-resolver` Claude skill.
- Flat skill-root layout: `SKILL.md`, `constitution.md`, `references/`, `scripts/`.
- Independent script implementations with tests.
- Expanded categories: lockfiles, migrations, submodules, binary, generated,
  snapshots, notebooks, mergiraf-supported files, and other files.
- Added stacked-PR detection and semantic-audit helpers.
- Added saved research synthesis and source index for future maintainers.
- Added PR decomposition: `references/pr-decomposition.md` plus
  `scripts/suggest-pr-split.sh` (deterministic functional/structural split-group
  proposals, with `--conflicts --scope ...` and `--base/--head` range modes) and
  `scripts/open-stacked-prs.sh` (stacked-PR creation via `gh`, dry-run by default
  with explicit `--execute --remote <name>` gates).
- Broadened the skill trigger to a split mode for oversized PRs/branches and
  allowed only `gh auth status` / `gh pr *` for the optional PR automation.
