#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/validate-resolution.sh"

passes=0
failures=0

setup_repo() {
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/validate-resolution.XXXXXX")"
    git -C "$tmp" init -q
    git -C "$tmp" config user.name "Test User"
    git -C "$tmp" config user.email "test@example.com"
    git -C "$tmp" config commit.gpgsign false
    git -C "$tmp" commit --allow-empty -m init -q
    echo "$tmp"
}

assert_exit() {
    local description="$1" expected="$2" actual="$3"
    if [ "$expected" -eq "$actual" ]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description (expected $expected, got $actual)"
        failures=$((failures + 1))
    fi
}

run_script() {
    local repo="$1"; shift
    local rc=0
    (cd "$repo" && bash "$SCRIPT" "$@") >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

test_clean_repo() {
    local repo rc
    repo="$(setup_repo)"
    echo "const x = 1;" > "$repo/a.ts"
    git -C "$repo" add a.ts
    git -C "$repo" commit -m add -q
    rc="$(run_script "$repo")"
    assert_exit "clean repo passes" 0 "$rc"
    rm -rf "$repo"
}

test_markers() {
    local repo rc
    repo="$(setup_repo)"
    cat > "$repo/a.ts" <<'EOF'
<<<<<<< HEAD
const x = 1;
||||||| base
const x = 0;
=======
const x = 2;
>>>>>>> theirs
EOF
    git -C "$repo" add a.ts
    git -C "$repo" commit -m broken -q
    rc="$(run_script "$repo")"
    assert_exit "diff3 markers fail in source" 1 "$rc"
    rm -rf "$repo"
}

test_docs_default_and_include() {
    local repo rc
    repo="$(setup_repo)"
    cat > "$repo/README.md" <<'EOF'
<<<<<<< HEAD
doc example
=======
doc example
>>>>>>> theirs
EOF
    git -C "$repo" add README.md
    git -C "$repo" commit -m docs -q
    rc="$(run_script "$repo")"
    assert_exit "markers in markdown allowed by default" 0 "$rc"
    rc="$(run_script "$repo" --include-path '*.md')"
    assert_exit "include path scans markdown" 1 "$rc"
    rm -rf "$repo"
}

test_optional_commands() {
    local repo rc
    repo="$(setup_repo)"
    echo x > "$repo/a.txt"
    git -C "$repo" add a.txt
    git -C "$repo" commit -m add -q
    rc="$(run_script "$repo" --typecheck true)"
    assert_exit "successful typecheck passes" 0 "$rc"
    rc="$(run_script "$repo" --typecheck false)"
    assert_exit "failed typecheck exits 3" 3 "$rc"
    rc="$(run_script "$repo" --test false)"
    assert_exit "failed tests exits 4" 4 "$rc"
    rm -rf "$repo"
}

test_bad_context() {
    local tmp rc repo
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/not-git.XXXXXX")"
    rc="$(run_script "$tmp")"
    assert_exit "not a repo exits 11" 11 "$rc"
    rm -rf "$tmp"

    repo="$(setup_repo)"
    rc="$(run_script "$repo" --not-real)"
    assert_exit "bad flag exits 10" 10 "$rc"
    rm -rf "$repo"
}

test_clean_repo
test_markers
test_docs_default_and_include
test_optional_commands
test_bad_context

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]

