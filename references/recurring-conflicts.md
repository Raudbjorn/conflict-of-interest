# Recurring Conflicts

## rerere

`git rerere` records and replays prior conflict resolutions. It is useful for
long rebases, but every replay must be reviewed.

Useful commands:

```bash
git config rerere.enabled true
git rerere status
git rerere diff
```

If the same conflict reappears three or more times, the resolution probably
depends on commit context. Abort and use a safer strategy.

## git-imerge

`git-imerge` breaks large merges/rebases into smaller pairwise conflicts. It
explicitly disables rerere while it runs because rerere replays can corrupt the
pairwise merge state. Do not combine rerere.autoupdate assumptions with
git-imerge workflows.

Escalate to git-imerge when:

- many consecutive rebase steps conflict
- the same conflict repeats with different correct answers
- a large branch mixes refactors and behavior changes

