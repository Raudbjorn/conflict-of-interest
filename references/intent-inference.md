# Intent Inference

Before resolving `other` files, answer:

1. What did ours intend?
2. What did theirs intend?

If either answer is unknown, halt.

## Evidence sources

Use these before reading only the conflict hunk:

```bash
git log --oneline --left-right --merge -- <file>
git show <sha> -- <file>
git diff "$(git merge-base HEAD MERGE_HEAD)" HEAD -- <file>
git diff "$(git merge-base HEAD MERGE_HEAD)" MERGE_HEAD -- <file>
```

Commit messages are strongest when descriptive. Generic messages like `fix`,
`wip`, or `update` are red flags.

## Taxonomy

| Type | Signature | Strategy |
|---|---|---|
| trivial | adjacent edits split artificially | combine both |
| additive | both sides add distinct items | keep both with deliberate order |
| competing | same logic changed differently | pick or synthesize by intent |
| structural | move/rename versus edit | apply edit to moved/renamed location |
| delete-vs-edit | one side deletes, other modifies | determine superseding intent |
| semantic | no marker, behavior conflict | run semantic audit |

## Behavior sentence

Before staging an `other` resolution, write one sentence describing behavior
after the merge. If you cannot, you do not yet understand the resolution.

