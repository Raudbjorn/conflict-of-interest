#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/meta-route.sh"

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

new_repo() {
    local repo
    repo="$(mktemp -d "${TMPDIR:-/tmp}/meta-route.XXXXXX")"
    git -C "$repo" init -q
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config rerere.enabled false
    echo seed > "$repo/seed.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -qm base
    echo "$repo"
}

stage_unmerged() {
    local repo="$1" path="$2"
    local b o t
    mkdir -p "$repo/$(dirname "$path")" 2>/dev/null || true
    b="$(printf 'base\n' | git -C "$repo" hash-object -w --stdin)"
    o="$(printf 'ours\n' | git -C "$repo" hash-object -w --stdin)"
    t="$(printf 'theirs\n' | git -C "$repo" hash-object -w --stdin)"
    printf '100644 %s 1\t%s\n100644 %s 2\t%s\n100644 %s 3\t%s\n' \
        "$b" "$path" "$o" "$path" "$t" "$path" \
        | git -C "$repo" update-index --index-info
}

stage_unmerged_submodule() {
    local repo="$1" path="$2"
    local sha=1111111111111111111111111111111111111111
    printf '160000 %s 1\t%s\n160000 %s 2\t%s\n160000 %s 3\t%s\n' \
        "$sha" "$path" "$sha" "$path" "$sha" "$path" \
        | git -C "$repo" update-index --index-info
}

# ---- 1: mechanical lockfile ----------------------------------------------
test_mechanical_lockfile() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged "$repo" Cargo.lock
    cat > "$repo/Cargo.lock" <<'EOF'
<<<<<<< HEAD
v1
=======
v2
>>>>>>> theirs
EOF
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "lockfile -> mechanical" '"route":"mechanical"' "$out"
    assert_contains "lockfile reason" '"reason":"category=lockfile"' "$out"
    rm -rf "$repo"
}

# ---- 2: mechanical migration ---------------------------------------------
test_mechanical_migration() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged "$repo" db/migrate/001_init.rb
    printf 'noop\n' > "$repo/db/migrate/001_init.rb"
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "migration -> mechanical" '"category":"migration"' "$out"
    assert_contains "migration reason" '"reason":"category=migration"' "$out"
    rm -rf "$repo"
}

# ---- 3: mechanical submodule (mode 160000) -------------------------------
test_mechanical_submodule() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged_submodule "$repo" deps/lib
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "submodule -> mechanical" '"category":"submodule"' "$out"
    rm -rf "$repo"
}

# ---- 4: stacked AUTO_HEAD ------------------------------------------------
test_stacked_auto_head() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged "$repo" auto.txt
    cat > "$repo/auto.txt" <<'EOF'
<<<<<<< HEAD
alpha
beta
gamma
||||||| base
=======
alpha
beta
gamma
>>>>>>> theirs
EOF
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "identical sides -> stacked-auto" '"route":"stacked-auto"' "$out"
    assert_contains "stacked pct present" '"stacked_pct":100' "$out"
    rm -rf "$repo"
}

# ---- 5: 5x imbalance -> llm-imbalanced ratio -----------------------------
test_imbalance_5x() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged "$repo" imb.txt
    {
        echo '<<<<<<< HEAD'
        for i in $(seq 1 50); do echo "ours_$i"; done
        echo '||||||| base'
        echo b1
        echo '======='
        for i in $(seq 1 10); do echo "th_$i"; done
        echo '>>>>>>> theirs'
    } > "$repo/imb.txt"
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "imbalance -> llm-imbalanced" '"route":"llm-imbalanced"' "$out"
    assert_contains "ratio reason" '"reason":"ratio=5.00"' "$out"
    rm -rf "$repo"
}

# ---- 6: balanced with base -> sbse-recombine -----------------------------
test_balanced_sbse() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged "$repo" bal.txt
    cat > "$repo/bal.txt" <<'EOF'
<<<<<<< HEAD
one
two
three
||||||| base
zero
=======
one
two
four
>>>>>>> theirs
EOF
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "balanced -> sbse-recombine" '"route":"sbse-recombine"' "$out"
    assert_contains "balanced reason" '"reason":"balanced_lines=3/3"' "$out"
    rm -rf "$repo"
}

# ---- 7: balanced large -> halt-decomposition (>300) ----------------------
test_balanced_large_halt() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged "$repo" big.txt
    {
        echo '<<<<<<< HEAD'
        for i in $(seq 1 200); do echo "o_$i"; done
        echo '||||||| base'
        echo b1
        echo '======='
        for i in $(seq 1 200); do echo "t_$i"; done
        echo '>>>>>>> theirs'
    } > "$repo/big.txt"
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "large -> halt-decomposition" '"route":"halt-decomposition"' "$out"
    assert_contains "total reason" '"reason":"total=400"' "$out"
    rm -rf "$repo"
}

# ---- 8: empty side (left empty) -> llm-imbalanced empty_side=L -----------
test_empty_side() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged "$repo" empty.txt
    cat > "$repo/empty.txt" <<'EOF'
<<<<<<< HEAD
||||||| base
removed line
=======
incoming a
incoming b
>>>>>>> theirs
EOF
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "empty side -> llm-imbalanced" '"route":"llm-imbalanced"' "$out"
    assert_contains "empty_side label is L (left empty)" '"empty_side":"L"' "$out"
    rm -rf "$repo"
}

# ---- 9: no diff3 base -> llm-imbalanced no_diff3 -------------------------
test_no_diff3() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged "$repo" nodiff3.txt
    cat > "$repo/nodiff3.txt" <<'EOF'
<<<<<<< HEAD
foo bar baz
=======
xyz qrs uvw
>>>>>>> theirs
EOF
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "no diff3 -> llm-imbalanced" '"route":"llm-imbalanced"' "$out"
    assert_contains "no_diff3 reason" '"reason":"no_diff3=true"' "$out"
    rm -rf "$repo"
}

# ---- 10: no unmerged paths -> exit 2, empty array ------------------------
test_no_unmerged() {
    local repo out rc
    repo="$(new_repo)"
    rc=0
    out="$(cd "$repo" && bash "$SCRIPT" --json)" || rc=$?
    assert_exit "no unmerged exits 2" 2 "$rc"
    assert_contains "empty array body" "[]" "$out"
    rm -rf "$repo"
}

# ---- 11: category wins over balance (Cargo.lock with markers) ------------
test_category_wins() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged "$repo" Cargo.lock
    cat > "$repo/Cargo.lock" <<'EOF'
<<<<<<< HEAD
v1
||||||| base
v0
=======
v2
>>>>>>> theirs
EOF
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "lockfile still mechanical (category wins)" '"route":"mechanical"' "$out"
    assert_not_contains "category wins skips balance signals" '"route":"sbse-recombine"' "$out"
    rm -rf "$repo"
}

# ---- 12: worktree unreadable (path staged but file missing) -> halt-other
test_worktree_missing() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged "$repo" ghost.txt
    # deliberately do NOT write ghost.txt to the worktree
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "missing worktree -> halt-other" '"route":"halt-other"' "$out"
    assert_contains "halt reason names the failure" "subcall_failed=worktree_unreadable" "$out"
    rm -rf "$repo"
}

# ---- 13: non-repo guard --------------------------------------------------
test_non_repo_guard() {
    local dir rc
    dir="$(mktemp -d "${TMPDIR:-/tmp}/meta-route-norepo.XXXXXX")"
    rc=0
    (cd "$dir" && bash "$SCRIPT" --json) >/dev/null 2>&1 || rc=$?
    assert_exit "non-repo exits 11" 11 "$rc"
    rm -rf "$dir"
}

# ---- 14: arg error -------------------------------------------------------
test_arg_error() {
    local rc
    rc=0
    (cd / && bash "$SCRIPT" --bogus) >/dev/null 2>&1 || rc=$?
    # When run outside a repo, guard fires first (exit 11) before arg parse.
    # Run in a real repo to reach arg parse:
    local repo
    repo="$(new_repo)"
    rc=0
    (cd "$repo" && bash "$SCRIPT" --bogus) >/dev/null 2>&1 || rc=$?
    assert_exit "unknown flag exits 10" 10 "$rc"
    rc=0
    (cd "$repo" && bash "$SCRIPT" --imbalance-threshold) >/dev/null 2>&1 || rc=$?
    assert_exit "missing flag value exits 10" 10 "$rc"
    rm -rf "$repo"
}

# ---- 15: TSV format ------------------------------------------------------
test_tsv_format() {
    local repo out
    repo="$(new_repo)"
    stage_unmerged "$repo" Cargo.lock
    cat > "$repo/Cargo.lock" <<'EOF'
<<<<<<< HEAD
a
=======
b
>>>>>>> theirs
EOF
    out="$(cd "$repo" && bash "$SCRIPT")"
    assert_contains "tsv tab-separated path/category/route" \
        $'Cargo.lock\tlockfile\tmechanical\tcategory=lockfile\thigh' "$out"
    rm -rf "$repo"
}

# ---- 16: history search gated when helper exists -------------------------
test_history_search_gated() {
    local repo out
    # Only run if historical-resolution-search.sh is on PATH/SCRIPT_DIR
    [ -x "$SCRIPT_DIR/historical-resolution-search.sh" ] || { echo "SKIP: historical-resolution-search.sh absent"; return; }
    repo="$(new_repo)"
    stage_unmerged "$repo" bal.txt
    cat > "$repo/bal.txt" <<'EOF'
<<<<<<< HEAD
one
two
three
||||||| base
zero
=======
one
two
four
>>>>>>> theirs
EOF
    # Without --history-search, history_top_score is null and route stays sbse-recombine.
    out="$(cd "$repo" && bash "$SCRIPT" --json)"
    assert_contains "without history-search -> sbse-recombine" '"route":"sbse-recombine"' "$out"
    assert_contains "history_top_score null without flag" '"history_top_score":null' "$out"
    # With --history-search and high threshold, history won't fire on this minimal repo.
    out="$(cd "$repo" && bash "$SCRIPT" --history-search --history-threshold 90 --json)"
    assert_contains "high threshold keeps sbse route" '"route":"sbse-recombine"' "$out"
    rm -rf "$repo"
}

test_mechanical_lockfile
test_mechanical_migration
test_mechanical_submodule
test_stacked_auto_head
test_imbalance_5x
test_balanced_sbse
test_balanced_large_halt
test_empty_side
test_no_diff3
test_no_unmerged
test_category_wins
test_worktree_missing
test_non_repo_guard
test_arg_error
test_tsv_format
test_history_search_gated

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]
