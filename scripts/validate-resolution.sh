#!/usr/bin/env bash
set -euo pipefail

command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

typecheck_cmd=""
test_cmd=""
pathspecs=(':!*.md' ':!*.txt' ':!*.rst' ':!docs/**' ':!references/**')

remove_default_exclude() {
    local include="$1" next=()
    local spec
    for spec in "${pathspecs[@]}"; do
        case "$spec" in
            ":!$include"|":!$include/**") continue ;;
        esac
        next+=("$spec")
    done
    pathspecs=("${next[@]}")
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --typecheck) [ "$#" -ge 2 ] || { echo "ERROR: --typecheck needs a command" >&2; exit 10; }; typecheck_cmd="$2"; shift 2 ;;
        --test) [ "$#" -ge 2 ] || { echo "ERROR: --test needs a command" >&2; exit 10; }; test_cmd="$2"; shift 2 ;;
        --include-path) [ "$#" -ge 2 ] || { echo "ERROR: --include-path needs a pattern" >&2; exit 10; }; remove_default_exclude "$2"; shift 2 ;;
        --) shift; break ;;
        -*) echo "ERROR: unknown flag: $1" >&2; exit 10 ;;
        *) echo "ERROR: unexpected arg: $1" >&2; exit 10 ;;
    esac
done

echo "=== validate-resolution ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ==="

echo -n "Conflict markers: "
if marker_hits="$(git grep -nE '^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\||=======)( |$)' -- "${pathspecs[@]}" 2>/dev/null)"; then
    echo "FAIL"
    echo "$marker_hits" >&2
    exit 1
fi
echo "OK"

echo -n "Whitespace check (--cached): "
if ! git diff --check --cached >/dev/null 2>&1; then
    echo "FAIL"
    git diff --check --cached >&2 || true
    exit 2
fi
echo "OK"

if [ -n "$typecheck_cmd" ]; then
    echo "Type-check: running '$typecheck_cmd'"
    if ! bash -lc "$typecheck_cmd"; then
        echo "ERROR: type-check failed (cmd: $typecheck_cmd)" >&2
        exit 3
    fi
    echo "Type-check: OK"
fi

if [ -n "$test_cmd" ]; then
    echo "Tests: running '$test_cmd'"
    if ! bash -lc "$test_cmd"; then
        echo "ERROR: tests failed (cmd: $test_cmd)" >&2
        exit 4
    fi
    echo "Tests: OK"
fi

echo "=== all checks passed ==="

