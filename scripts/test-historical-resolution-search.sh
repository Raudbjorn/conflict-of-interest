#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/historical-resolution-search.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ASSERT_STDOUT="$TMP_ROOT/assert.out"
ASSERT_STDERR="$TMP_ROOT/assert.err"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_exit() {
    local expected="$1"
    shift
    set +e
    "$@" >"$ASSERT_STDOUT" 2>"$ASSERT_STDERR"
    local actual=$?
    set -e
    [ "$actual" -eq "$expected" ] || {
        echo "stdout:" >&2
        cat "$ASSERT_STDOUT" >&2
        echo "stderr:" >&2
        cat "$ASSERT_STDERR" >&2
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
        git init -q -b main
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

add_second_conflict_merge() {
    local repo="$1"
    (
        cd "$repo"
        git reset --hard -q HEAD
        cat > src/calc.js <<'EOF'
function total(value) {
  return value;
}
EOF
        commit_all "reset total for second conflict" "2024-01-05T00:00:00Z"

        git switch -q -c second-left
        cat > src/calc.js <<'EOF'
function total(value) {
  const normalized = normalize(value);
  return normalized + 2;
}
EOF
        commit_all "second left total change" "2024-01-06T00:00:00Z"

        git switch -q -c second-right HEAD~1
        cat > src/calc.js <<'EOF'
function total(value) {
  return value + bonus + 2;
}
EOF
        commit_all "second right total change" "2024-01-07T00:00:00Z"

        git switch -q second-left
        set +e
        git merge --no-ff second-right >/dev/null 2>&1
        local merge_status=$?
        set -e
        [ "$merge_status" -ne 0 ] || fail "expected second historical conflict"
        cat > src/calc.js <<'EOF'
function total(value) {
  const normalized = normalize(value);
  return normalized + 2;
  return value + bonus + 2;
}
EOF
        commit_all "Resolve second total conflict" "2024-01-08T00:00:00Z"
        write_current_conflict src/calc.js
    )
}

test_bad_args() {
    assert_exit 10 "$SCRIPT" --top nope
}

test_bad_file_arg() {
    local repo="$TMP_ROOT/bad-file"
    init_repo "$repo"
    (
        cd "$repo"
        echo "base" > README.md
        commit_all "base" "2024-01-01T00:00:00Z"
        assert_exit 10 "$SCRIPT" --file missing.js
    )
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
    assert_contains "historical-resolution-search.sh" "$ASSERT_STDOUT"
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
        assert_contains '"reason":"no_merge_commits"' "$ASSERT_STDOUT"
    )
}

test_partial_clone_guard() {
    local repo="$TMP_ROOT/partial"
    init_repo "$repo"
    (
        cd "$repo"
        git config remote.origin.promisor true
        assert_exit 2 "$SCRIPT" --json
        assert_contains '"reason":"partial_clone_promisor"' "$ASSERT_STDOUT"
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
        assert_contains '"version":1' "$ASSERT_STDOUT"
        assert_contains '"status":"matches"' "$ASSERT_STDOUT"
        assert_contains "\"commit\":\"$merge_sha\"" "$ASSERT_STDOUT"
        assert_contains '"path":"src/calc.js"' "$ASSERT_STDOUT"
        assert_contains '"line_jaccard":' "$ASSERT_STDOUT"
        assert_contains '"recombination_ratio":' "$ASSERT_STDOUT"
        assert_contains '"matched_symbols":["total"]' "$ASSERT_STDOUT"
        assert_contains '"snippets":null' "$ASSERT_STDOUT"
    )
}

test_snippets_json() {
    local repo="$TMP_ROOT/snippets"
    create_conflict_history_repo "$repo"
    (
        cd "$repo"
        assert_exit 0 "$SCRIPT" --file src/calc.js --json --include-snippets
        assert_contains '"snippets":{"parents":' "$ASSERT_STDOUT"
        assert_contains '"result":' "$ASSERT_STDOUT"
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
        assert_contains '"reason":"no_conflicted_candidate_paths"' "$ASSERT_STDOUT"
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
        local merge_status=$?
        set -e
        [ "$merge_status" -ne 0 ] || fail "expected conflict in parent-identical fixture"
        git checkout --ours src/calc.js >/dev/null 2>&1
        git add src/calc.js
        GIT_AUTHOR_DATE="2024-01-04T00:00:00Z" GIT_COMMITTER_DATE="2024-01-04T00:00:00Z" git commit -q -m "Choose left"
        write_current_conflict src/calc.js
        assert_exit 2 "$SCRIPT" --file src/calc.js --json
        assert_contains '"reason":"no_conflicted_candidate_paths"' "$ASSERT_STDOUT"
    )
}

test_since_filters_candidates() {
    local repo="$TMP_ROOT/since"
    create_conflict_history_repo "$repo"
    (
        cd "$repo"
        assert_exit 2 "$SCRIPT" --file src/calc.js --json --since "2030-01-01"
        assert_contains '"status":"no_signal"' "$ASSERT_STDOUT"
    )
}

test_top_truncates() {
    local repo="$TMP_ROOT/top"
    create_conflict_history_repo "$repo"
    add_second_conflict_merge "$repo"
    (
        cd "$repo"
        assert_exit 0 "$SCRIPT" --file src/calc.js --json --top 3
        local total_count
        total_count="$(grep -o '"commit":' "$ASSERT_STDOUT" | wc -l | tr -d ' ')"
        [ "$total_count" -gt 1 ] || fail "expected multiple JSON matches before truncation, got $total_count"
        assert_exit 0 "$SCRIPT" --file src/calc.js --json --top 1
        local count
        count="$(grep -o '"commit":' "$ASSERT_STDOUT" | wc -l | tr -d ' ')"
        [ "$count" = "1" ] || fail "expected one JSON match, got $count"
    )
}

test_bad_args
test_bad_file_arg
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
