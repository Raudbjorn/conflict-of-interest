# Historical Resolution Mining

Use repository history as evidence when resolving semantic, structural, or
competing source/config conflicts. The goal is not to replay old patches; it is to
surface how this repository's humans resolved similar conflicts before.

## What the helper does

`scripts/historical-resolution-search.sh` searches local merge commits for real
two-parent textual conflicts, replays the parents with `git merge-tree
--write-tree`, and compares the historical parent lines plus committed result to
the current conflict. It returns the top advisory examples, normally three, with
the commit, path, score, matched symbols, and an inspection command.

The script is read-only and local-only:

```bash
${CLAUDE_SKILL_DIR}/scripts/historical-resolution-search.sh \
  --file <file> --symbol <name> --top 3 --json
```

It exits `0` when matches are found, `2` when history has no usable signal, `10`
for bad arguments, `11` outside a git repository, and `12` when required Git
features are unavailable.

## Research alignment

- **LLMinus-style retrieval:** LLMinus retrieves similar historical resolutions
  from the same project and feeds them to an LLM as context. This skill adopts the
  local retrieval idea without adding embeddings, a vector database, or training.
- **Merge-Bench-Builder-style replay:** Good examples come from replaying real
  merge parents, not from ordinary clean merge commits. The helper filters for
  paths that actually conflict under `git merge-tree`.
- **Plastic-surgery heuristic:** Historical studies found that most real
  resolutions are line combinations from the two parents. The helper reports a
  recombination ratio:

  ```text
  historical result lines that appear in either parent / all historical result lines
  ```

  A high ratio supports line-combination reasoning; it does not prove the current
  conflict is safe to auto-resolve.
- **Almost Rerere future work:** Project-specific rules learned from past
  resolutions are promising, but V1 deliberately keeps examples advisory. Learned
  auto-resolution rules need stronger validation before they belong in this skill.
- **Language-specific models:** MergeGen, LLMergeJ, and Merge-Bench language
  results show that language matters. Treat language as a risk modifier: C/C++
  conflicts deserve extra caution, while easier languages still require explicit
  intent evidence.

## Limitations

- Squash-only and rebase-only repositories may have no merge commits to mine.
- Shallow or promisor/partial clones may not have enough local objects; the helper
  returns no-signal rather than fetching data.
- Octopus merges are skipped.
- Parent-identical resolutions, including many `ours`/`theirs` strategies, are
  filtered out because they rarely teach synthesis.
- Rename-heavy conflicts are best-effort; inspect the returned command before
  trusting path similarity.

## Privacy

The helper itself makes no network calls and does not create a persistent corpus.
However, any snippets copied into model context may be transmitted by the model
runtime. Snippets are disabled by default; use `--include-snippets` only when the
repository's confidentiality rules allow it.

Future dataset export tooling should require an explicit output path, size/path
filters, and prominent warnings because historical conflict corpora can contain
proprietary code or old secrets.

