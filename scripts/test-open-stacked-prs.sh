#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/open-stacked-prs.sh"

passes=0
failures=0

pass() { passes=$((passes + 1)); }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

assert_exit() {
    local description="$1" expected="$2" actual="$3"
    [ "$expected" -eq "$actual" ] && pass || fail "$description (expected exit $expected, got $actual)"
}

assert_contains() {
    local description="$1" needle="$2" hay="$3"
    [[ "$hay" == *"$needle"* ]] && pass || fail "$description (missing '$needle')"
}

new_repo() {
    local repo
    repo="$(mktemp -d "${TMPDIR:-/tmp}/open-stacked-prs.XXXXXX")"
    git -C "$repo" init -q
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config rerere.enabled false
    mkdir -p "$repo/src/auth" "$repo/db"
    printf 'x\n' > "$repo/src/auth/a.ts"
    printf 'y\n' > "$repo/db/m.sql"
    git -C "$repo" add -A
    git -C "$repo" commit -qm base
    echo "$repo"
}

# --- dry-run produces a correctly wired stacked plan -----------------------
test_dry_run_plan() {
    local repo rc out
    repo="$(new_repo)"
    rc=0
    out="$(cd "$repo" && bash "$SCRIPT" --base main --head HEAD \
        --group "split/db:db/m.sql" --group "split/auth:src/auth/a.ts")" || rc=$?
    assert_exit "dry-run exits 0" 0 "$rc"
    assert_contains "first branch off base" "git checkout -b split/db main" "$out"
    assert_contains "first PR targets base" "gh pr create --base main --head split/db" "$out"
    assert_contains "second branch off first" "git checkout -b split/auth split/db" "$out"
    assert_contains "second PR targets first branch" "gh pr create --base split/db --head split/auth" "$out"
    assert_contains "dry-run executes nothing" "Nothing executed." "$out"
    rm -rf "$repo"
}

# --- no groups -------------------------------------------------------------
test_no_groups() {
    local repo rc
    repo="$(new_repo)"
    rc=0
    (cd "$repo" && bash "$SCRIPT" --base main) >/dev/null 2>&1 || rc=$?
    assert_exit "no groups exits 15" 15 "$rc"
    rm -rf "$repo"
}

# --- malformed group spec --------------------------------------------------
test_bad_group_spec() {
    local repo rc
    repo="$(new_repo)"
    rc=0
    (cd "$repo" && bash "$SCRIPT" --base main --group "nocolon") >/dev/null 2>&1 || rc=$?
    assert_exit "bad group spec exits 10" 10 "$rc"
    rm -rf "$repo"
}

# --- dirty tree refusal (execute) ------------------------------------------
test_dirty_tree_refusal() {
    local repo rc
    repo="$(new_repo)"
    printf 'dirty\n' >> "$repo/db/m.sql"
    rc=0
    (cd "$repo" && bash "$SCRIPT" --base main --group "split/db:db/m.sql" --execute) >/dev/null 2>&1 || rc=$?
    assert_exit "dirty tree refused with exit 13" 13 "$rc"
    rm -rf "$repo"
}

# --- missing gh (execute, clean tree) --------------------------------------
test_missing_gh() {
    local repo rc
    repo="$(new_repo)"
    rc=0
    (cd "$repo" && GH_BIN="gh-not-a-real-binary-xyz" bash "$SCRIPT" \
        --base main --group "split/db:db/m.sql" --execute) >/dev/null 2>&1 || rc=$?
    assert_exit "missing gh exits 14 before any branch op" 14 "$rc"
    rm -rf "$repo"
}

# --- non-repo guard --------------------------------------------------------
test_non_repo_guard() {
    local dir rc
    dir="$(mktemp -d "${TMPDIR:-/tmp}/open-stacked-prs-norepo.XXXXXX")"
    rc=0
    (cd "$dir" && bash "$SCRIPT" --base main --group "x:y") >/dev/null 2>&1 || rc=$?
    assert_exit "non-repo exits 11" 11 "$rc"
    rm -rf "$dir"
}

# --- unknown flag ----------------------------------------------------------
test_arg_error() {
    local repo rc
    repo="$(new_repo)"
    rc=0
    (cd "$repo" && bash "$SCRIPT" --bogus) >/dev/null 2>&1 || rc=$?
    assert_exit "unknown flag exits 10" 10 "$rc"
    rm -rf "$repo"
}

test_dry_run_plan
test_no_groups
test_bad_group_spec
test_dirty_tree_refusal
test_missing_gh
test_non_repo_guard
test_arg_error

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]
