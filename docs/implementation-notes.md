# Implementation Notes

## Layout

The repository root is the Claude skill root. `scripts/` contains the runtime
artifacts the skill calls; there is no `src/` directory until a real build step
exists.

## Licensing

Two behaviorally useful scripts in the older implementation were derived from
an apparently unlicensed dotfiles repository. This repository uses independent
implementations based on observable behavior and tests, with prior-art
attribution in NOTICE.

## Test isolation

Tests create temporary git repositories and configure identity locally. Tests
should not rely on the user's global git configuration.

