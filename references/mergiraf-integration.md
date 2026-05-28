# mergiraf Integration

`mergiraf` is the preferred structural merge driver for supported languages.

Recommended git config:

```bash
git config --global merge.conflictStyle zdiff3
mergiraf languages
```

Second pass used by the skill:

```bash
timeout 30 mergiraf solve -- <file> --compact --keep-backup=false
```

If mergiraf times out or leaves markers, fall through to intent inference.
Large files over roughly 10,000 lines are the main timeout risk.

