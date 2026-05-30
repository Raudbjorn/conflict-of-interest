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
    git -C "$repo" init -q -b main
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config rerere.enabled false
    mkdir -p "$repo/src/auth" "$repo/db"
    printf 'x\n' > "$repo/src/auth/a.ts"
    printf 'y\n' > "$repo/db/m.sql"
    git -C "$repo" add -A
    git -C "$repo" commit -qm base
    git -C "$repo" remote add origin "$repo"
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
    assert_contains "first branch off base" "git switch -c split/db main" "$out"
    assert_contains "first PR targets base" "gh pr create --base main --head split/db" "$out"
    assert_contains "second branch off first" "git switch -c split/auth split/db" "$out"
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
    (cd "$repo" && bash "$SCRIPT" --base main --remote origin --group "split/db:db/m.sql" --execute) >/dev/null 2>&1 || rc=$?
    assert_exit "dirty tree refused with exit 13" 13 "$rc"
    rm -rf "$repo"
}

# --- missing gh (execute, clean tree) --------------------------------------
test_missing_gh() {
    local repo rc
    repo="$(new_repo)"
    rc=0
    git -C "$repo" switch -c work -q
    (cd "$repo" && GH_BIN="gh-not-a-real-binary-xyz" bash "$SCRIPT" \
        --base main --remote origin --group "split/db:db/m.sql" --execute) >/dev/null 2>&1 || rc=$?
    assert_exit "missing gh exits 14 before any branch op" 14 "$rc"
    rm -rf "$repo"
}

# --- execute requires explicit remote --------------------------------------
test_execute_requires_remote() {
    local repo rc
    repo="$(new_repo)"
    rc=0
    (cd "$repo" && bash "$SCRIPT" --base main --group "split/db:db/m.sql" --execute) >/dev/null 2>&1 || rc=$?
    assert_exit "execute without explicit remote exits 10" 10 "$rc"
    rm -rf "$repo"
}

# --- protected branch guard -------------------------------------------------
test_protected_branch_refusal() {
    local repo rc
    repo="$(new_repo)"
    rc=0
    (cd "$repo" && GH_BIN="gh-not-a-real-binary-xyz" bash "$SCRIPT" \
        --base main --remote origin --group "split/db:db/m.sql" --execute) >/dev/null 2>&1 || rc=$?
    assert_exit "protected branch refused before gh" 16 "$rc"
    rm -rf "$repo"
}

# --- duplicate target branch names ------------------------------------------
test_duplicate_branch_refusal() {
    local repo rc err
    repo="$(new_repo)"
    rc=0
    err="$(cd "$repo" && bash "$SCRIPT" --base main \
        --group "split/db:db/m.sql" --group "split/db:src/auth/a.ts" 2>&1)" || rc=$?
    assert_exit "duplicate branch exits 17" 17 "$rc"
    assert_contains "duplicate branch message" "duplicate target branch name: split/db" "$err"
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

# --- --group-path repeatable, no comma split -------------------------------
test_group_path_accumulates() {
    local repo rc out
    repo="$(new_repo)"
    rc=0
    out="$(cd "$repo" && bash "$SCRIPT" --base main --head HEAD \
        --group-path split/x db/m.sql \
        --group-path split/x src/auth/a.ts)" || rc=$?
    assert_exit "group-path dry-run exits 0" 0 "$rc"
    assert_contains "first path present" "db/m.sql" "$out"
    assert_contains "second path present" "src/auth/a.ts" "$out"
    assert_contains "single restore line per group" "git restore --source=HEAD --staged --worktree -- db/m.sql src/auth/a.ts" "$out"
    rm -rf "$repo"
}

test_group_path_tolerates_commas_in_paths() {
    local repo rc out
    repo="$(new_repo)"
    mkdir -p "$repo/weird"
    printf 'x\n' > "$repo/weird/a,b.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -qm "comma"
    rc=0
    out="$(cd "$repo" && bash "$SCRIPT" --base main --head HEAD \
        --group-path split/c "weird/a,b.txt")" || rc=$?
    assert_exit "comma-in-path dry-run exits 0" 0 "$rc"
    # printf %q escapes the literal comma as `\,`; assert the path appears as a
    # single argument rather than being split into two.
    assert_contains "comma path passed as one arg" 'weird/a\,b.txt' "$out"
    rm -rf "$repo"
}

test_group_path_needs_name_and_path() {
    local repo rc
    repo="$(new_repo)"
    rc=0
    (cd "$repo" && bash "$SCRIPT" --base main --group-path only-name) >/dev/null 2>&1 || rc=$?
    assert_exit "missing PATH arg exits 10" 10 "$rc"
    rm -rf "$repo"
}

# --- --from-json fail-fast on invalid JSON ---------------------------------
test_from_json_bad_input_exit_19() {
    local repo rc err
    repo="$(new_repo)"
    rc=0
    err="$(cd "$repo" && echo 'NOT JSON' | bash "$SCRIPT" --base main --from-json 2>&1 1>/dev/null)" || rc=$?
    assert_exit "invalid --from-json JSON exits 19" 19 "$rc"
    assert_contains "explicit parse-failure message" "failed to parse stdin as JSON" "$err"
}

# --- --from-json valid-but-empty -> existing exit 15 -----------------------
test_from_json_empty_groups_exit_15() {
    local repo rc
    repo="$(new_repo)"
    rc=0
    (cd "$repo" && echo '{"groups":[]}' | bash "$SCRIPT" --base main --from-json) >/dev/null 2>&1 || rc=$?
    assert_exit "valid-but-empty JSON exits 15 (no groups)" 15 "$rc"
    rm -rf "$repo"
}

test_dry_run_plan
test_no_groups
test_bad_group_spec
test_dirty_tree_refusal
test_missing_gh
test_execute_requires_remote
test_protected_branch_refusal
test_duplicate_branch_refusal
test_non_repo_guard
test_arg_error
test_group_path_accumulates
test_group_path_tolerates_commas_in_paths
test_group_path_needs_name_and_path
test_from_json_bad_input_exit_19
test_from_json_empty_groups_exit_15

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]
