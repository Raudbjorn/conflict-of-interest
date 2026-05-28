# Constitution: git-conflict-resolver

These rules override all other conflict-resolution guidance.

## Rule 1: No conflict markers in tracked source

Do not continue, commit, or stage a final resolution that leaves conflict
markers in tracked source files:

- `<<<<<<<`
- `|||||||`
- `=======`
- `>>>>>>>`

Documentation examples may contain markers, but source paths may not.

## Rule 2: No blanket resolution across human-authored files

Forbidden by default:

- `git checkout --ours .`
- `git checkout --theirs .`
- `git reset --hard` during an active conflict operation
- `git rebase --skip` without inspecting the skipped patch

Bulk operations are allowed only for known mechanical categories such as
lockfiles, generated output, and snapshots, and only by category.

## Rule 3: Halt on uninferred intent

For `other` files, if you cannot state what ours and theirs intended in one
sentence each, do not edit. Show evidence and ask the user.

## Override Protocol

If the user overrides a rule for a specific scope:

1. Record the override visibly.
2. Apply it only to that scope.
3. Do not generalize it to other files.
4. Refuse overrides that leave markers in source code.

