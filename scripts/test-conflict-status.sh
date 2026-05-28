#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/conflict-status.sh"

passes=0
failures=0

setup_repo() {
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/conflict-status.XXXXXX")"
    git -C "$tmp" init -q
    git -C "$tmp" config user.name "Test User"
    git -C "$tmp" config user.email "test@example.com"
    git -C "$tmp" config commit.gpgsign false
    git -C "$tmp" commit --allow-empty -m init -q
    echo "$tmp"
}

assert_output() {
    local description="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description"
        echo "  expected: $(printf '%s' "$expected" | cat -et)"
        echo "  actual:   $(printf '%s' "$actual" | cat -et)"
        failures=$((failures + 1))
    fi
}

test_none() {
    local repo branch output
    repo="$(setup_repo)"
    branch="$(git -C "$repo" branch --show-current)"
    output="$(cd "$repo" && bash "$SCRIPT")"
    assert_output "no operation reports none" "$(printf 'none\t\t%s\t0' "$branch")" "$output"
    rm -rf "$repo"
}

test_merge() {
    local repo branch output
    repo="$(setup_repo)"
    touch "$repo/.git/MERGE_HEAD"
    branch="$(git -C "$repo" branch --show-current)"
    output="$(cd "$repo" && bash "$SCRIPT")"
    assert_output "merge detected" "$(printf 'merge\t\t%s\t0' "$branch")" "$output"
    rm -rf "$repo"
}

test_cherry_pick_and_revert() {
    local repo branch output
    repo="$(setup_repo)"
    touch "$repo/.git/CHERRY_PICK_HEAD"
    branch="$(git -C "$repo" branch --show-current)"
    output="$(cd "$repo" && bash "$SCRIPT")"
    assert_output "cherry-pick detected" "$(printf 'cherry-pick\t\t%s\t0' "$branch")" "$output"
    rm -rf "$repo"

    repo="$(setup_repo)"
    touch "$repo/.git/REVERT_HEAD"
    branch="$(git -C "$repo" branch --show-current)"
    output="$(cd "$repo" && bash "$SCRIPT")"
    assert_output "revert detected" "$(printf 'revert\t\t%s\t0' "$branch")" "$output"
    rm -rf "$repo"
}

test_rebase_progress() {
    local repo output
    repo="$(setup_repo)"
    mkdir -p "$repo/.git/rebase-merge"
    echo 3 > "$repo/.git/rebase-merge/msgnum"
    echo 12 > "$repo/.git/rebase-merge/end"
    echo refs/heads/feature-branch > "$repo/.git/rebase-merge/head-name"
    output="$(cd "$repo" && bash "$SCRIPT")"
    assert_output "rebase progress and branch" "$(printf 'rebase\t3/12\tfeature-branch\t0')" "$output"
    rm -rf "$repo"
}

test_rebase_apply_and_priority() {
    local repo output
    repo="$(setup_repo)"
    mkdir -p "$repo/.git/rebase-apply"
    echo 5 > "$repo/.git/rebase-apply/next"
    echo 8 > "$repo/.git/rebase-apply/last"
    echo refs/heads/my-branch > "$repo/.git/rebase-apply/head-name"
    output="$(cd "$repo" && bash "$SCRIPT")"
    assert_output "rebase apply progress" "$(printf 'rebase\t5/8\tmy-branch\t0')" "$output"
    rm -rf "$repo"

    repo="$(setup_repo)"
    mkdir -p "$repo/.git/rebase-merge"
    echo 2 > "$repo/.git/rebase-merge/msgnum"
    echo 5 > "$repo/.git/rebase-merge/end"
    echo refs/heads/priority > "$repo/.git/rebase-merge/head-name"
    touch "$repo/.git/MERGE_HEAD"
    output="$(cd "$repo" && bash "$SCRIPT")"
    assert_output "rebase takes priority over merge" "$(printf 'rebase\t2/5\tpriority\t0')" "$output"
    rm -rf "$repo"
}

test_unmerged_count() {
    local repo output branch count
    repo="$(mktemp -d "${TMPDIR:-/tmp}/conflict-status-real.XXXXXX")"
    git -C "$repo" init -q
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config user.email "test@example.com"
    printf 'base\n' > "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -m base -q
    git -C "$repo" checkout -b left -q
    printf 'left\n' > "$repo/file.txt"
    git -C "$repo" commit -am left -q
    git -C "$repo" checkout -b right HEAD~1 -q
    printf 'right\n' > "$repo/file.txt"
    git -C "$repo" commit -am right -q
    git -C "$repo" merge left >/dev/null 2>&1 || true
    branch="$(git -C "$repo" branch --show-current)"
    output="$(cd "$repo" && bash "$SCRIPT")"
    count="$(printf '%s' "$output" | awk -F '\t' '{print $4}')"
    assert_output "unmerged count is one" "1" "$count"
    assert_output "merge status includes count" "$(printf 'merge\t\t%s\t1' "$branch")" "$output"
    rm -rf "$repo"
}

test_none
test_merge
test_cherry_pick_and_revert
test_rebase_progress
test_rebase_apply_and_priority
test_unmerged_count

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]

