#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/historical-resolution-search.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_exit() {
    local expected="$1"
    shift
    set +e
    "$@" >/tmp/historical-resolution-test.out 2>/tmp/historical-resolution-test.err
    local actual=$?
    set -e
    [ "$actual" -eq "$expected" ] || {
        echo "stdout:" >&2
        cat /tmp/historical-resolution-test.out >&2
        echo "stderr:" >&2
        cat /tmp/historical-resolution-test.err >&2
        fail "expected exit $expected, got $actual: $*"
    }
}

assert_contains() {
    local needle="$1" file="$2"
    grep -Fq -- "$needle" "$file" || {
        echo "content:" >&2
        cat "$file" >&2
        fail "expected '$needle' in $file"
    }
}

init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    (
        cd "$repo"
        git init -q
        git config user.name "Conflict Test"
        git config user.email "conflict-test@example.com"
        git config commit.gpgsign false
    )
}

commit_all() {
    local message="$1" date="$2"
    git add -A
    GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" git commit -q -m "$message"
}

write_current_conflict() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
function total(value) {
<<<<<<< ours
  const normalized = normalize(value);
  return normalized + 1;
=======
  return value + bonus;
>>>>>>> theirs
}
EOF
}

create_conflict_history_repo() {
    local repo="$1"
    init_repo "$repo"
    (
        cd "$repo"
        mkdir -p src
        cat > src/calc.js <<'EOF'
function total(value) {
  return value;
}
EOF
        commit_all "base" "2024-01-01T00:00:00Z"

        git switch -q -c left
        cat > src/calc.js <<'EOF'
function total(value) {
  const normalized = normalize(value);
  return normalized + 1;
}
EOF
        commit_all "left total change" "2024-01-02T00:00:00Z"

        git switch -q -c right main
        cat > src/calc.js <<'EOF'
function total(value) {
  return value + bonus;
}
EOF
        commit_all "right total change" "2024-01-03T00:00:00Z"

        git switch -q left
        set +e
        git merge --no-ff right >/dev/null 2>&1
        local merge_status=$?
        set -e
        [ "$merge_status" -ne 0 ] || fail "expected historical conflict"
        cat > src/calc.js <<'EOF'
function total(value) {
  const normalized = normalize(value);
  return normalized + 1;
  return value + bonus;
}
EOF
        commit_all "Resolve historical total conflict" "2024-01-04T00:00:00Z"
        git rev-parse HEAD > "$repo/historical-merge.sha"
        write_current_conflict src/calc.js
    )
}

test_bad_args() {
    assert_exit 10 "$SCRIPT" --top nope
}

test_non_repo() {
    local dir="$TMP_ROOT/non-repo"
    mkdir -p "$dir"
    (
        cd "$dir"
        assert_exit 11 "$SCRIPT" --file src/calc.js
    )
}

test_help() {
    assert_exit 0 "$SCRIPT" --help
    assert_contains "historical-resolution-search.sh" /tmp/historical-resolution-test.out
}

test_no_merge_history() {
    local repo="$TMP_ROOT/no-merges"
    init_repo "$repo"
    (
        cd "$repo"
        write_current_conflict src/calc.js
        git add src/calc.js
        commit_all "base conflict fixture" "2024-01-01T00:00:00Z"
        write_current_conflict src/calc.js
        assert_exit 2 "$SCRIPT" --file src/calc.js --json
        assert_contains '"reason":"no_merge_commits"' /tmp/historical-resolution-test.out
    )
}

test_partial_clone_guard() {
    local repo="$TMP_ROOT/partial"
    init_repo "$repo"
    (
        cd "$repo"
        git config remote.origin.promisor true
        assert_exit 2 "$SCRIPT" --json
        assert_contains '"reason":"partial_clone_promisor"' /tmp/historical-resolution-test.out
    )
}

test_real_conflict_json() {
    local repo="$TMP_ROOT/real-conflict"
    create_conflict_history_repo "$repo"
    (
        cd "$repo"
        local merge_sha
        merge_sha="$(cat historical-merge.sha)"
        assert_exit 0 "$SCRIPT" --file src/calc.js --symbol total --json
        assert_contains '"version":1' /tmp/historical-resolution-test.out
        assert_contains '"status":"matches"' /tmp/historical-resolution-test.out
        assert_contains "\"commit\":\"$merge_sha\"" /tmp/historical-resolution-test.out
        assert_contains '"path":"src/calc.js"' /tmp/historical-resolution-test.out
        assert_contains '"line_jaccard":' /tmp/historical-resolution-test.out
        assert_contains '"recombination_ratio":' /tmp/historical-resolution-test.out
        assert_contains '"matched_symbols":["total"]' /tmp/historical-resolution-test.out
        assert_contains '"snippets":null' /tmp/historical-resolution-test.out
    )
}

test_snippets_json() {
    local repo="$TMP_ROOT/snippets"
    create_conflict_history_repo "$repo"
    (
        cd "$repo"
        assert_exit 0 "$SCRIPT" --file src/calc.js --json --include-snippets
        assert_contains '"snippets":{"parents":' /tmp/historical-resolution-test.out
        assert_contains '"result":' /tmp/historical-resolution-test.out
    )
}

test_clean_merge_ignored() {
    local repo="$TMP_ROOT/clean-merge"
    init_repo "$repo"
    (
        cd "$repo"
        mkdir -p src
        echo "left" > src/left.js
        commit_all "base" "2024-01-01T00:00:00Z"
        git switch -q -c feature
        echo "feature" > src/feature.js
        commit_all "feature" "2024-01-02T00:00:00Z"
        git switch -q main
        echo "main" > src/main.js
        commit_all "main" "2024-01-03T00:00:00Z"
        git merge --no-ff -q feature -m "Clean merge"
        write_current_conflict src/calc.js
        assert_exit 2 "$SCRIPT" --file src/calc.js --json
        assert_contains '"reason":"no_conflicted_candidate_paths"' /tmp/historical-resolution-test.out
    )
}

test_parent_identical_resolution_ignored() {
    local repo="$TMP_ROOT/parent-identical"
    init_repo "$repo"
    (
        cd "$repo"
        mkdir -p src
        cat > src/calc.js <<'EOF'
function total(value) {
  return value;
}
EOF
        commit_all "base" "2024-01-01T00:00:00Z"
        git switch -q -c left
        cat > src/calc.js <<'EOF'
function total(value) {
  return value + 1;
}
EOF
        commit_all "left" "2024-01-02T00:00:00Z"
        git switch -q -c right main
        cat > src/calc.js <<'EOF'
function total(value) {
  return value + 2;
}
EOF
        commit_all "right" "2024-01-03T00:00:00Z"
        git switch -q left
        set +e
        git merge --no-ff right >/dev/null 2>&1
        set -e
        git checkout --ours src/calc.js >/dev/null 2>&1
        git add src/calc.js
        GIT_AUTHOR_DATE="2024-01-04T00:00:00Z" GIT_COMMITTER_DATE="2024-01-04T00:00:00Z" git commit -q -m "Choose left"
        write_current_conflict src/calc.js
        assert_exit 2 "$SCRIPT" --file src/calc.js --json
        assert_contains '"reason":"no_conflicted_candidate_paths"' /tmp/historical-resolution-test.out
    )
}

test_since_filters_candidates() {
    local repo="$TMP_ROOT/since"
    create_conflict_history_repo "$repo"
    (
        cd "$repo"
        assert_exit 2 "$SCRIPT" --file src/calc.js --json --since "2030-01-01"
        assert_contains '"status":"no_signal"' /tmp/historical-resolution-test.out
    )
}

test_top_truncates() {
    local repo="$TMP_ROOT/top"
    create_conflict_history_repo "$repo"
    (
        cd "$repo"
        assert_exit 0 "$SCRIPT" --file src/calc.js --json --top 1
        local count
        count="$(grep -o '"commit":' /tmp/historical-resolution-test.out | wc -l | tr -d ' ')"
        [ "$count" = "1" ] || fail "expected one JSON match, got $count"
    )
}

test_bad_args
test_non_repo
test_help
test_no_merge_history
test_partial_clone_guard
test_real_conflict_json
test_snippets_json
test_clean_merge_ignored
test_parent_identical_resolution_ignored
test_since_filters_candidates
test_top_truncates

echo "historical-resolution-search tests passed"

