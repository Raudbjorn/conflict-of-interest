---
name: git-conflict-resolver
description: >
  Resolve git conflicts (rebase, merge, cherry-pick, revert) using mergiraf,
  deterministic category handling, explicit intent inference, validation, and
  semantic-conflict auditing. Use when git status shows unmerged paths or an
  operation is paused with conflicts. Also decomposes an oversized PR or branch
  into smaller stacked PRs along functional/structural boundaries.
when_to_use: >
  Trigger phrases: "unmerged paths", "rebase paused", "merge conflict",
  "resolve conflicts", "cherry-pick conflict", "revert conflict". Split mode (for
  oversized changes only): "split this PR", "PR too big to review", "decompose
  PR", "break up this branch".
  Do not use for abstract git education, blanket --ours/--theirs sweeps,
  force-push recovery, or general PR review.
argument-hint: "[--abort|--continue|--split]"
allowed-tools: Bash(git *), Bash(gh auth status), Bash(gh pr *), Bash(mergiraf *), Bash(timeout *), Bash(npm *), Bash(pnpm *), Bash(yarn *), Bash(bun *), Bash(uv *), Bash(pdm *), Bash(cargo *), Bash(poetry *), Bash(bundle *), Bash(composer *), Bash(mix *), Bash(swift *), Bash(dart *), Bash(dotnet *), Bash(nix *), Bash(python *)
effort: high
---

# git-conflict-resolver

Mechanical conflict resolution is automated. Judgment is explicit. If intent
cannot be inferred, halt and ask.

For rationale and empirical grounding, read
`${CLAUDE_SKILL_DIR}/references/design-rationale.md` only when needed.

## Constitutional Rules

Read `${CLAUDE_SKILL_DIR}/constitution.md`. These rules override this procedure:

1. No conflict markers in tracked source files.
2. No blanket resolution across human-authored files.
3. Halt when intent cannot be inferred for `other` files.

## Modes

Two entry points:

- **Resolve** (default): an operation is paused with conflicts. Follow the
  Procedure below.
- **Split** (`--split`, or a request to decompose an oversized PR/branch with no
  active conflict): propose smaller PRs along functional/structural boundaries.
  See "PR Decomposition" below. The Procedure's large-conflict gates also route
  here when a conflict is too large to resolve in place.

## Procedure

### Step 1 — Detect context

```bash
${CLAUDE_SKILL_DIR}/scripts/conflict-status.sh
```

Output: `context<TAB>progress<TAB>branch<TAB>unmerged_count`.

| Context | Unmerged | Argument | Action |
|---|---:|---|---|
| `none` | n/a | `--abort` | Report "no operation in progress" |
| `none` | n/a | none / `--continue` | Report "no conflicts" |
| active | n/a | `--abort` | `git <ctx> --abort` |
| active | 0 | any | `git <ctx> --continue` (merge: `git commit --no-edit`) |
| active | >0 | `--continue` | Continue without resolving |
| active | >0 | none | Proceed to Step 2 |

Abort recommendation criteria:

- rebase step has 20 or more conflicted files
- five or more consecutive rebase steps have conflicts
- same conflict reappears three or more times with rerere enabled

These are configurable heuristics, not empirical laws. See
`${CLAUDE_SKILL_DIR}/references/recurring-conflicts.md`. When the unmerged count
is 20 or more, run
`${CLAUDE_SKILL_DIR}/scripts/suggest-pr-split.sh --conflicts --scope both --json` before
categorizing. If high-confidence groups exist, recommend aborting and re-landing
as smaller PRs (refactor-baseline first); see
`${CLAUDE_SKILL_DIR}/references/pr-decomposition.md`. This is advisory —
low-confidence (cross-cutting) groups are structural-only boundaries, not safe
splits.

### Step 2 — Categorize

```bash
${CLAUDE_SKILL_DIR}/scripts/categorize-conflicts.sh
```

Categories: `lockfile`, `migration`, `submodule`, `binary`, `generated`,
`snapshot`, `notebook`, `mergiraf`, `other`.

Report categorization before editing.

### Step 3 — Resolve by category

#### 3a. Lockfiles

Accept theirs to clear markers; regenerate in Step 5.

```bash
git checkout --theirs <file> && git add <file>
```

#### 3b. Migrations

Do not auto-resolve. Show both sides and ask. State operation-specific
ours/theirs semantics, especially during rebase.

#### 3c. Submodules

Halt. Show both pinned SHAs and ask which commit the submodule should point to.

#### 3d. Binary files

Halt. Show file type/size and ask whether to keep ours or theirs.

#### 3e. Generated files

Resolve the source spec first, then regenerate. If the source spec cannot be
identified or both specs changed incompatibly, halt.

#### 3f. Snapshots

Use the side that matches the intended code state, then regenerate snapshots.
During rebase, explicitly state that "ours" is upstream and "theirs" is the
replayed commit before choosing.

#### 3g. Notebooks

If conflict is output-only (`outputs` or `execution_count`), strip outputs.
If source cells conflict, treat as `other` and run intent inference.

#### 3h. mergiraf files

```bash
timeout 30 mergiraf solve -- <file> --compact --keep-backup=false
```

Exit code 124 means timeout; fall through to `other`. If markers remain after
mergiraf, fall through to `other`. Otherwise stage the file.

#### 3i. Other files

For each file:

1. Measure balance. If one side is more than 3x longer, LLM analysis is more
   appropriate. If balanced, prefer line-combination reasoning and lower
   confidence. If total conflict content is over 300 lines, halt and recommend
   decomposition: run `${CLAUDE_SKILL_DIR}/scripts/suggest-pr-split.sh --conflicts --scope both`
   to propose split groups, and fall back to `git-imerge` (see
   `${CLAUDE_SKILL_DIR}/references/recurring-conflicts.md`) when the change cannot
   be split (all groups low-confidence/cross-cutting).
2. If one side is empty, classify as `modify-delete` and inspect commit order
   with `git log --oneline --left-right --merge -- <file>`.
3. Run stacked-PR detection:

   ```bash
   ${CLAUDE_SKILL_DIR}/scripts/detect-stacked-pr.sh --file <file> --json
   ```

4. Collect evidence before inferring intent:

   ```bash
   git log --oneline --left-right --merge -- <file>
   git show <sha> -- <file>
   git diff "$(git merge-base HEAD MERGE_HEAD)" HEAD -- <file>
   git diff "$(git merge-base HEAD MERGE_HEAD)" MERGE_HEAD -- <file>
   ```

5. Name the structural root cause.
6. Infer ours/theirs intent in one sentence each.
7. If either intent is unknown, HALT using the schema below.
8. Classify: trivial, additive, competing, structural, modify-delete, semantic.
9. Resolve, remove markers, stage, and produce a decision record.

### Step 4 — Validate

```bash
${CLAUDE_SKILL_DIR}/scripts/validate-resolution.sh \
  --typecheck '<project-typecheck-cmd>' \
  --test '<focused-test-cmd>'
```

Then run:

```bash
${CLAUDE_SKILL_DIR}/scripts/semantic-audit.sh
```

Any `SUSPECT` output requires review before continuing.

### Step 5 — Regenerate and continue

Regenerate lockfiles from manifests:

| Lockfile | Command |
|---|---|
| `package-lock.json` | `npm install` |
| `pnpm-lock.yaml` | `pnpm install` |
| `yarn.lock` | `yarn install` |
| `bun.lockb` / `bun.lock` | `bun install` |
| `npm-shrinkwrap.json` | `npm shrinkwrap` |
| `Cargo.lock` | `cargo generate-lockfile` |
| `poetry.lock` | `poetry lock --no-update` |
| `uv.lock` | `uv lock` |
| `pdm.lock` | `pdm lock` |
| `Gemfile.lock` | `bundle install` |
| `composer.lock` | `composer install` |
| `mix.lock` | `mix deps.get` |
| `Package.resolved` | `swift package resolve` |
| `pubspec.lock` | `dart pub get` / `flutter pub get` |
| `packages.lock.json` | `dotnet restore` |
| `flake.lock` | `nix flake lock` |

Continue:

| Context | Command |
|---|---|
| rebase | `git rebase --continue` |
| merge | `git commit --no-edit` |
| cherry-pick | `git cherry-pick --continue` |
| revert | `git revert --continue` |

Loop to Step 1 if more conflicts appear.

### Step 6 — Summarize

Produce Markdown plus fenced JSON:

```markdown
## Resolution Complete — <operation> on `<branch>`

| Category | Auto | User | Halted |
|---|---:|---:|---:|
| lockfile | N | 0 | 0 |
| other | N | N | N |

**Lockfiles regenerated**: ...
**Semantic audit**: ...
**Constitutional overrides**: ...
**Decomposition recommended**: <none, or which groups were proposed>
```

```json
{
  "operation": "rebase",
  "branch": "feature",
  "categories": {},
  "semantic_audit": {"suspects": 0},
  "overrides": []
}
```

## Per-file Decision Record

```markdown
### Resolution: `<file-path>`

| Field | Value |
|---|---|
| Category | lockfile / migration / submodule / binary / generated / snapshot / notebook / mergiraf / other |
| Evidence sources checked | commit-msg / ancestor-diff / related-files / PR-refs |
| Intent (ours) | <sentence or UNKNOWN> |
| Intent (theirs) | <sentence or UNKNOWN> |
| Root cause | <structural cause> |
| Confidence | high / medium / low / none -> HALT |
| Conflict type | trivial / additive / competing / structural / modify-delete / semantic |
| Action | auto-resolved / user-directed / HALT / decompose-recommended |
| Behaviour after resolution | <sentence asserting post-merge behavior> |
```

```json
{
  "file": "<file-path>",
  "category": "other",
  "confidence": "high",
  "action": "auto-resolved",
  "conflict_type": "additive"
}
```

## HALT Schema

```markdown
## HALT — intent not inferable: `<file-path>`

**Context**: <operation> step <N/M> on `<branch>`

**Evidence checked**:
- Commit msg (ours): `<hash>` "<message>"
- Commit msg (theirs): `<hash>` "<message>"
- Ancestor diff (ours): <summary>
- Ancestor diff (theirs): <summary>

**Best read**:
- Ours appears to: <sentence>
- Theirs appears to: <sentence>

**Options**:
1. Take ours -> <outcome>
2. Take theirs -> <outcome>
3. Synthesize -> <proposal>
```

Abstention is better than a wrong merge.

## PR Decomposition (split mode)

Use when asked to decompose an oversized PR/branch, or when a large-conflict gate
routes here. Full guidance: `${CLAUDE_SKILL_DIR}/references/pr-decomposition.md`.

### Step S1 — Propose boundaries

```bash
# pre-conflict: analyze a PR/branch range
${CLAUDE_SKILL_DIR}/scripts/suggest-pr-split.sh --base <base-ref> --head <head-ref> --json
# in an oversized conflict
${CLAUDE_SKILL_DIR}/scripts/suggest-pr-split.sh --conflicts --scope both --json
```

Present the proposed groups in merge order (refactor-baseline first, then
schema/migration, then source, then ui/test). State each group's confidence.
Low-confidence (cross-cutting) groups are structural-only boundaries: flag them,
do not present them as safe. If every group is low-confidence, recommend keeping
the change whole or using `git-imerge` instead.

### Step S2 — Dry-run the stack

```bash
${CLAUDE_SKILL_DIR}/scripts/open-stacked-prs.sh --base <trunk-branch> --head <head-ref> \
  --group "<branch>:<path,path>" --group "<branch>:<path,path>"
```

`open-stacked-prs.sh` is dry-run by default and prints the `git`/`gh` plan. It
synthesizes new commits from path groups; it does not preserve original commit
topology unless the user explicitly supplied commit-aligned groups.

### Step S3 — Confirm, then execute

Creating branches and PRs is outward-facing. Show the dry-run plan and obtain
**explicit user confirmation** before re-running with `--execute --remote <name>`.
The script refuses dirty trees, protected/default branches, missing `gh` auth, and
pre-existing local/remote branch names unless the user explicitly changes the
plan. Each split must compile/typecheck on its own; verify before opening the next
PR. Retarget children to the trunk as parents merge (`gh pr edit <n> --base
<trunk>`).
