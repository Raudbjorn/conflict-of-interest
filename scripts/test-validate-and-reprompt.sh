#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/validate-and-reprompt.sh"

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
assert_not_contains() {
    local description="$1" needle="$2" hay="$3"
    [[ "$hay" != *"$needle"* ]] && pass || fail "$description (unexpected '$needle')"
}
assert_file_exists() {
    local description="$1" path="$2"
    [ -f "$path" ] && pass || fail "$description (file missing: $path)"
}
assert_file_absent() {
    local description="$1" path="$2"
    [ ! -e "$path" ] && pass || fail "$description (file should not exist: $path)"
}

new_repo() {
    local repo
    repo="$(mktemp -d "${TMPDIR:-/tmp}/validate-reprompt.XXXXXX")"
    git -C "$repo" init -q
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config rerere.enabled false
    echo seed > "$repo/seed.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -qm base
    echo "$repo"
}

# 1: pass case - exit 0, no artifact/state files left
test_pass_case() {
    local repo rc
    repo="$(new_repo)"
    rc=0
    (cd "$repo" && bash "$SCRIPT") >/dev/null 2>&1 || rc=$?
    assert_exit "pass exits 0" 0 "$rc"
    assert_file_absent "no reprompt.md on pass" "$repo/.git/conflict-resolver/reprompt.md"
    assert_file_absent "no state file on pass" "$repo/.git/conflict-resolver/reprompt-state.json"
    rm -rf "$repo"
}

# 2: typecheck fail (iteration 1) - exit 5, artifact written, state shows iter 1
test_typecheck_fail_first_iter() {
    local repo rc out
    repo="$(new_repo)"
    rc=0
    out="$(cd "$repo" && bash "$SCRIPT" --typecheck 'echo "src/a.ts:42:10: error" >&2; false' 2>&1)" || rc=$?
    assert_exit "first failure exits 5" 5 "$rc"
    assert_file_exists "reprompt.md created" "$repo/.git/conflict-resolver/reprompt.md"
    local art state
    art="$(cat "$repo/.git/conflict-resolver/reprompt.md")"
    assert_contains "artifact mentions iteration 1/1" "iteration 1/1" "$art"
    assert_contains "artifact names typecheck failure" "typecheck failed" "$art"
    state="$(cat "$repo/.git/conflict-resolver/reprompt-state.json")"
    assert_contains "state iteration=1" '"iteration":1' "$state"
    assert_contains "state last_exit_code=3" '"last_exit_code":3' "$state"
    rm -rf "$repo"
}

# 3: budget exhausted (second call with max=1) - exits with underlying code
test_budget_exhausted() {
    local repo rc1 rc2
    repo="$(new_repo)"
    rc1=0
    (cd "$repo" && bash "$SCRIPT" --typecheck 'false') >/dev/null 2>&1 || rc1=$?
    assert_exit "first call exits 5" 5 "$rc1"
    rc2=0
    (cd "$repo" && bash "$SCRIPT" --typecheck 'false' 2>&1) >/dev/null 2>&1 || rc2=$?
    assert_exit "budget exhausted -> exit 3" 3 "$rc2"
    rm -rf "$repo"
}

# 4: successful retry clears state and artifact
test_retry_then_pass() {
    local repo rc1 rc2
    repo="$(new_repo)"
    rc1=0
    (cd "$repo" && bash "$SCRIPT" --typecheck 'false') >/dev/null 2>&1 || rc1=$?
    assert_exit "first call exits 5" 5 "$rc1"
    assert_file_exists "state present after fail" "$repo/.git/conflict-resolver/reprompt-state.json"
    rc2=0
    # second call with passing typecheck
    (cd "$repo" && bash "$SCRIPT" --typecheck 'true') >/dev/null 2>&1 || rc2=$?
    assert_exit "successful retry exits 0" 0 "$rc2"
    assert_file_absent "state cleared after success" "$repo/.git/conflict-resolver/reprompt-state.json"
    assert_file_absent "artifact cleared after success" "$repo/.git/conflict-resolver/reprompt.md"
    rm -rf "$repo"
}

# 5: artifact shape - regex-check required sections
test_artifact_shape() {
    local repo art
    repo="$(new_repo)"
    (cd "$repo" && bash "$SCRIPT" --typecheck 'echo "src/x.ts:1:1: error" >&2; false') >/dev/null 2>&1 || true
    art="$(cat "$repo/.git/conflict-resolver/reprompt.md")"
    assert_contains "section: Failure" "## Failure" "$art"
    assert_contains "section: Files involved" "## Files involved" "$art"
    assert_contains "section: Instruction" "## Instruction" "$art"
    assert_contains "shows last lines block" '```' "$art"
    rm -rf "$repo"
}

# 6: PURE-DATA invariant - artifact contains no LLM/network endpoint strings
test_pure_data_invariant() {
    local repo art
    repo="$(new_repo)"
    (cd "$repo" && bash "$SCRIPT" --typecheck 'echo "boom" >&2; false') >/dev/null 2>&1 || true
    art="$(cat "$repo/.git/conflict-resolver/reprompt.md")"
    assert_not_contains "no http:// in artifact" "http://" "$art"
    assert_not_contains "no https:// in artifact" "https://" "$art"
    assert_not_contains "no anthropic endpoint" "api.anthropic.com" "$art"
    assert_not_contains "no openai endpoint" "api.openai.com" "$art"
    assert_not_contains "no api key string" "API_KEY" "$art"
    rm -rf "$repo"
}

# 7: max-iterations=2 allows two retries
test_max_iter_2() {
    local repo rc
    repo="$(new_repo)"
    rc=0; (cd "$repo" && bash "$SCRIPT" --typecheck 'false' --max-iterations 2) >/dev/null 2>&1 || rc=$?
    assert_exit "first iter exits 5" 5 "$rc"
    rc=0; (cd "$repo" && bash "$SCRIPT" --typecheck 'false' --max-iterations 2) >/dev/null 2>&1 || rc=$?
    assert_exit "second iter exits 5" 5 "$rc"
    rc=0; (cd "$repo" && bash "$SCRIPT" --typecheck 'false' --max-iterations 2) >/dev/null 2>&1 || rc=$?
    assert_exit "third iter budget exhausted -> underlying 3" 3 "$rc"
    rm -rf "$repo"
}

# 8: max-iterations=0 disables loop (failure -> underlying code immediately)
test_max_iter_0() {
    local repo rc
    repo="$(new_repo)"
    rc=0; (cd "$repo" && bash "$SCRIPT" --typecheck 'false' --max-iterations 0) >/dev/null 2>&1 || rc=$?
    assert_exit "max=0 short-circuits to underlying 3" 3 "$rc"
    assert_file_absent "no artifact when loop disabled" "$repo/.git/conflict-resolver/reprompt.md"
    rm -rf "$repo"
}

# 9: arg errors
test_arg_errors() {
    local repo rc
    repo="$(new_repo)"
    rc=0; (cd "$repo" && bash "$SCRIPT" --bogus) >/dev/null 2>&1 || rc=$?
    assert_exit "unknown flag exits 10" 10 "$rc"
    rc=0; (cd "$repo" && bash "$SCRIPT" --max-iterations abc) >/dev/null 2>&1 || rc=$?
    assert_exit "non-integer max-iterations exits 10" 10 "$rc"
    rm -rf "$repo"
}

# 10: non-repo guard
test_non_repo_guard() {
    local dir rc
    dir="$(mktemp -d "${TMPDIR:-/tmp}/vr-norepo.XXXXXX")"
    rc=0; (cd "$dir" && bash "$SCRIPT") >/dev/null 2>&1 || rc=$?
    assert_exit "non-repo exits 11" 11 "$rc"
    rm -rf "$dir"
}

# --- regression: --state-file outside .git/conflict-resolver/ is rejected ---
test_state_file_out_of_tree_rejected() {
    local repo rc err out_path
    repo="$(new_repo)"
    out_path="$(mktemp -u "${TMPDIR:-/tmp}/vr-out-of-tree.XXXXXX.json")"
    rc=0
    err="$(cd "$repo" && bash "$SCRIPT" --state-file "$out_path" 2>&1)" || rc=$?
    assert_exit "out-of-tree --state-file rejected with exit 10" 10 "$rc"
    assert_contains "rejection mentions artifact-root prefix" "must live under" "$err"
    # And: no artifact was written to the rogue location.
    assert_file_absent "no rogue state-file created" "$out_path"
    rm -rf "$repo"
}

# --- regression: --reprompt-out outside .git/conflict-resolver/ is rejected ---
test_reprompt_out_of_tree_rejected() {
    local repo rc err out_path
    repo="$(new_repo)"
    out_path="$(mktemp -u "${TMPDIR:-/tmp}/vr-out-of-tree.XXXXXX.md")"
    rc=0
    err="$(cd "$repo" && bash "$SCRIPT" --reprompt-out "$out_path" 2>&1)" || rc=$?
    assert_exit "out-of-tree --reprompt-out rejected with exit 10" 10 "$rc"
    assert_contains "rejection mentions artifact-root prefix" "must live under" "$err"
    assert_file_absent "no rogue reprompt artifact created" "$out_path"
    rm -rf "$repo"
}

# --- regression: artifact preserves forwarded flags in printed commands ------
test_artifact_preserves_forwarded_flags() {
    local repo rc artifact state_file reprompt_out content
    repo="$(new_repo)"
    state_file="$repo/.git/conflict-resolver/custom-state.json"
    reprompt_out="$repo/.git/conflict-resolver/custom/reprompt.md"
    rc=0
    (cd "$repo" && bash "$SCRIPT" \
        --typecheck 'false' \
        --include-path 'src/billing/**' \
        --state-file "$state_file" \
        --reprompt-out "$reprompt_out") >/dev/null 2>&1 || rc=$?
    assert_exit "typecheck failure exits 5 (retry requested)" 5 "$rc"
    artifact="$reprompt_out"
    assert_file_exists "artifact written" "$artifact"
    assert_file_exists "custom state file written" "$state_file"
    content="$(cat "$artifact")"
    assert_contains "validate command preserves --include-path" "--include-path src/billing" "$content"
    assert_contains "rerun command preserves --include-path" "--include-path src/billing" "$content"
    assert_contains "rerun command preserves --state-file" "--state-file $state_file" "$content"
    assert_contains "rerun command preserves --reprompt-out" "--reprompt-out $reprompt_out" "$content"
    rm -rf "$repo"
}

test_pass_case
test_typecheck_fail_first_iter
test_budget_exhausted
test_retry_then_pass
test_artifact_shape
test_pure_data_invariant
test_max_iter_2
test_max_iter_0
test_arg_errors
test_non_repo_guard
test_state_file_out_of_tree_rejected
test_reprompt_out_of_tree_rejected
test_artifact_preserves_forwarded_flags

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]
