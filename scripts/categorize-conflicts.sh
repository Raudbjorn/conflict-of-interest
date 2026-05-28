#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/path-classifiers.sh
source "$SCRIPT_DIR/lib/path-classifiers.sh"

is_submodule() {
    local path="$1"
    git ls-files -u -- "$path" 2>/dev/null | awk '$1 == "160000" {found=1} END {exit found ? 0 : 1}'
}

is_binary() {
    local path="$1" numstat
    numstat="$(git diff --numstat -- "$path" 2>/dev/null || true)"
    printf '%s\n' "$numstat" | awk '$1 == "-" && $2 == "-" {found=1} END {exit found ? 0 : 1}'
}

categorize_path() {
    local path="$1"
    if is_submodule "$path"; then
        echo "submodule"
    elif is_binary "$path"; then
        echo "binary"
    elif is_lockfile "$path"; then
        echo "lockfile"
    elif is_migration "$path"; then
        echo "migration"
    elif is_snapshot "$path"; then
        echo "snapshot"
    elif is_notebook "$path"; then
        echo "notebook"
    elif is_generated "$path"; then
        echo "generated"
    elif is_mergiraf_supported "$path"; then
        echo "mergiraf"
    else
        echo "other"
    fi
}

main() {
    command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

    local path
    git diff --name-only --diff-filter=U | while IFS= read -r path; do
        [ -n "$path" ] || continue
        printf '%s\t%s\n' "$(categorize_path "$path")" "$path"
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
