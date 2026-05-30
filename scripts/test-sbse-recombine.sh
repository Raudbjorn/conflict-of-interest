#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/sbse-recombine.sh"

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
assert_eq() {
    local description="$1" expected="$2" actual="$3"
    [ "$expected" = "$actual" ] && pass || fail "$description (expected '$expected', got '$actual')"
}

new_repo() {
    local repo
    repo="$(mktemp -d "${TMPDIR:-/tmp}/sbse-recombine.XXXXXX")"
    git -C "$repo" init -q
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config rerere.enabled false
    echo seed > "$repo/seed.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -qm base
    echo "$repo"
}

write_balanced() {
    cat > "$1" <<'EOF'
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
}

# 1: all 7 candidate ids exist
test_all_candidate_ids() {
    local repo out
    repo="$(new_repo)"
    write_balanced "$repo/bal.txt"
    out="$(cd "$repo" && bash "$SCRIPT" --file bal.txt --top 10)"
    for id in ours-only theirs-only left-then-right right-then-left union-dedup intersection base-plus-additive; do
        assert_contains "candidate id '$id' present" "\"id\":\"$id\"" "$out"
    done
    rm -rf "$repo"
}

# 2: total > max_lines -> deferred
test_defer_large() {
    local repo out
    repo="$(new_repo)"
    {
        echo '<<<<<<< HEAD'
        for i in $(seq 1 250); do echo "o$i"; done
        echo '||||||| base'; echo b
        echo '======='
        for i in $(seq 1 250); do echo "t$i"; done
        echo '>>>>>>> theirs'
    } > "$repo/big.txt"
    out="$(cd "$repo" && bash "$SCRIPT" --file big.txt)"
    assert_contains "large -> deferred:true" '"deferred":true' "$out"
    assert_contains "large -> empty candidates" '"candidates":[]' "$out"
    assert_contains "large -> verdict deferred" '"verdict":"deferred"' "$out"
    rm -rf "$repo"
}

# 3: imbalance > 3x -> deferred
test_defer_imbalance() {
    local repo out
    repo="$(new_repo)"
    {
        echo '<<<<<<< HEAD'
        for i in $(seq 1 60); do echo "o$i"; done
        echo '||||||| base'; echo b
        echo '======='
        for i in $(seq 1 10); do echo "t$i"; done
        echo '>>>>>>> theirs'
    } > "$repo/imb.txt"
    out="$(cd "$repo" && bash "$SCRIPT" --file imb.txt)"
    assert_contains "imbalance -> deferred:true" '"deferred":true' "$out"
    assert_contains "imbalance reason" "imbalance=60/10>=3x" "$out"
    rm -rf "$repo"
}

# 4: no conflict blocks -> exit 2
test_no_blocks() {
    local repo rc out
    repo="$(new_repo)"
    echo "plain file no markers" > "$repo/plain.txt"
    rc=0
    out="$(cd "$repo" && bash "$SCRIPT" --file plain.txt)" || rc=$?
    assert_exit "no blocks exits 2" 2 "$rc"
    assert_contains "no blocks empty array" '"blocks":[]' "$out"
    rm -rf "$repo"
}

# 5: determinism (same sha1s twice)
test_determinism() {
    local repo a b
    repo="$(new_repo)"
    write_balanced "$repo/bal.txt"
    a="$(cd "$repo" && bash "$SCRIPT" --file bal.txt --top 10 | grep -oE '"sha1":"[^"]+"' | sort)"
    b="$(cd "$repo" && bash "$SCRIPT" --file bal.txt --top 10 | grep -oE '"sha1":"[^"]+"' | sort)"
    assert_eq "identical sha1 sets across runs" "$a" "$b"
    rm -rf "$repo"
}

# 6: JSON shape
test_json_shape() {
    local repo out
    repo="$(new_repo)"
    write_balanced "$repo/bal.txt"
    out="$(cd "$repo" && bash "$SCRIPT" --file bal.txt)"
    assert_contains "json has file" '"file":"bal.txt"' "$out"
    assert_contains "json has thresholds" '"thresholds":{' "$out"
    assert_contains "json has blocks" '"blocks":[' "$out"
    assert_contains "json has candidates" '"candidates":[' "$out"
    assert_contains "json has verdict" '"verdict":' "$out"
    if command -v python3 >/dev/null 2>&1; then
        if printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1; then pass; else fail "json invalid"; fi
    else
        pass
    fi
    rm -rf "$repo"
}

# 7: identical sides -> ours-only and theirs-only both score 100
test_identical_sides() {
    local repo out
    repo="$(new_repo)"
    cat > "$repo/eq.txt" <<'EOF'
<<<<<<< HEAD
same a
same b
||||||| base
old
=======
same a
same b
>>>>>>> theirs
EOF
    out="$(cd "$repo" && bash "$SCRIPT" --file eq.txt --top 10)"
    # parse top scores via python
    if command -v python3 >/dev/null 2>&1; then
        local scores
        scores="$(printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
cands={c["id"]:c["score"] for c in d["blocks"][0]["candidates"]}
print(cands.get("ours-only",-1), cands.get("theirs-only",-1))
')"
        assert_eq "identical sides: ours-only=100 theirs-only=100" "100 100" "$scores"
    else
        pass
    fi
    rm -rf "$repo"
}

# 8: --block out of range -> exit 10
test_block_out_of_range() {
    local repo rc
    repo="$(new_repo)"
    write_balanced "$repo/bal.txt"
    rc=0
    (cd "$repo" && bash "$SCRIPT" --file bal.txt --block 5) >/dev/null 2>&1 || rc=$?
    assert_exit "block out of range exits 10" 10 "$rc"
    rm -rf "$repo"
}

# 9: arg errors
test_arg_errors() {
    local repo rc
    repo="$(new_repo)"
    rc=0
    (cd "$repo" && bash "$SCRIPT") >/dev/null 2>&1 || rc=$?
    assert_exit "missing --file exits 10" 10 "$rc"
    rc=0
    (cd "$repo" && bash "$SCRIPT" --bogus) >/dev/null 2>&1 || rc=$?
    assert_exit "unknown flag exits 10" 10 "$rc"
    rc=0
    (cd "$repo" && bash "$SCRIPT" --file nonexistent.txt) >/dev/null 2>&1 || rc=$?
    assert_exit "unreadable file exits 10" 10 "$rc"
    rm -rf "$repo"
}

# 10: non-repo guard
test_non_repo_guard() {
    local dir rc
    dir="$(mktemp -d "${TMPDIR:-/tmp}/sbse-norepo.XXXXXX")"
    echo "<<<<<<< HEAD" > "$dir/f.txt"
    rc=0
    (cd "$dir" && bash "$SCRIPT" --file f.txt) >/dev/null 2>&1 || rc=$?
    assert_exit "non-repo exits 11" 11 "$rc"
    rm -rf "$dir"
}

# 11: --include-content includes body
test_include_content() {
    local repo out
    repo="$(new_repo)"
    write_balanced "$repo/bal.txt"
    out="$(cd "$repo" && bash "$SCRIPT" --file bal.txt --include-content)"
    assert_contains "content field present" '"content":"' "$out"
    rm -rf "$repo"
}

# 12: jaccard library unit (sourced)
test_jaccard_lib() {
    # shellcheck source=lib/jaccard.sh
    source "$SCRIPT_DIR/lib/jaccard.sh"
    assert_eq "identical strings -> 100" 100 "$(jaccard_similarity_pct $'a\nb\n' $'a\nb\n')"
    assert_eq "disjoint strings -> 0" 0 "$(jaccard_similarity_pct $'a\nb\n' $'c\nd\n')"
    assert_eq "both empty -> 100" 100 "$(jaccard_similarity_pct '' '')"
    assert_eq "half overlap -> 33" 33 "$(jaccard_similarity_pct $'a\nb\n' $'b\nc\n')"
}

test_all_candidate_ids
test_defer_large
test_defer_imbalance
test_no_blocks
test_determinism
test_json_shape
test_identical_sides
test_block_out_of_range
test_arg_errors
test_non_repo_guard
test_include_content
test_jaccard_lib

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]
