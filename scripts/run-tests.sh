#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

for script in scripts/*.sh; do
    bash -n "$script"
done

for test_script in scripts/test-*.sh; do
    echo "== $test_script"
    bash "$test_script"
done

