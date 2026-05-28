# Semantic Conflicts

A semantic conflict occurs when the textual merge is clean but the combined
program is wrong.

High-suspicion changes:

- function signature changes
- type/schema changes
- dependency additions/removals
- constants/env var changes
- public API changes
- one side refactors while the other adds callers

## Rover-inspired symbol classes

| Node | Represents |
|---|---|
| TypeDef | classes, structs, aliases, interfaces |
| MethodDef | functions, methods, macros |
| GlobalVarDef | module-level constants, globals, macros |
| ImportDef | imports, requires, includes |
| MemberDef | fields and properties |
| MethodStmt | statements inside method bodies |
| MethodVarDef | parameters and local variables |

## Manual recipe

```bash
base="$(git merge-base HEAD MERGE_HEAD)"
git diff "$base"...HEAD -- '*.py' '*.ts' '*.go' '*.rs'
git diff "$base"...MERGE_HEAD -- '*.py' '*.ts' '*.go' '*.rs'
git grep -n "\b<symbol>\b" -- ':!*.md' ':!*.txt'
```

The script `${CLAUDE_SKILL_DIR}/scripts/semantic-audit.sh` operationalizes a
conservative version of this recipe.

